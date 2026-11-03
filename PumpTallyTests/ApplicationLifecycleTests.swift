import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private enum Failure: Error { case unavailableStore }

    private final class Sync: ApplicationSync {
        let stateManager: SyncStateManager
        var availability: () async -> Bool = { true }
        var starts = 0
        var synchronizations = 0
        var availabilityChecks = 0

        init() throws {
            stateManager = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "Lifecycle.\(UUID())")))
            stateManager.iCloudSyncEnabled = true
            stateManager.initialSyncCompleted = true
        }

        func checkiCloudAvailability() async -> Bool {
            availabilityChecks += 1
            return await availability()
        }

        func resumeRecoveryIfNeeded() async throws {}
        func startMonitoring() async { starts += 1 }
        func synchronizeNow() async { synchronizations += 1 }
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    func testActualCacheSaveFailureStopsStartupAndForegroundSync() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("read-only.store")
        let schema = Schema(versionedSchema: SchemaV5.self)
        do {
            let writable = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(writable)
            let vehicle = Vehicle(name: "Uncached")
            context.insert(vehicle)
            context.insert(
                FuelingRecord(
                    odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
                    fuelAmount: 10.123456789, totalCost: 35.123456789, vehicle: vehicle))
            try context.save()
        }
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
        let sync = try Sync()
        let lifecycle = ApplicationLifecycleCoordinator(container: readOnly, syncService: sync)
        await lifecycle.start()
        await lifecycle.didBecomeActive()
        XCTAssertEqual(sync.availabilityChecks, 0)
        XCTAssertEqual(sync.starts, 0)
        XCTAssertEqual(sync.synchronizations, 0)
        guard case .failed = lifecycle.startup else { return XCTFail("Startup must expose the save failure") }
        guard case .error = sync.stateManager.syncStatus else { return XCTFail("Actual save failure was hidden") }
    }

    func testOwnedCacheSaveCanBeRetriedBeforeSyncStarts() async throws {
        let container = try container()
        let context = ModelContext(container)
        let vehicle = Vehicle(name: "Uncached")
        context.insert(vehicle)
        try context.save()
        let fail = OSAllocatedUnfairLock(initialState: true)
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let service = StatisticsCachePersistenceService(container: container) {
            saves.withLock { $0 += 1 }
            if fail.withLock({ $0 }) { throw Failure.unavailableStore }
            try $0.modelContext.save()
        }
        let sync = try Sync()
        let lifecycle = ApplicationLifecycleCoordinator(
            container: container, syncService: sync,
            initializeStore: { _ in _ = try await service.rebuildIfNeeded() })
        await lifecycle.start()
        guard case .failed = lifecycle.startup else { return XCTFail("Missing startup failure") }
        await lifecycle.didBecomeActive()
        XCTAssertEqual(sync.starts, 0)
        XCTAssertEqual(sync.availabilityChecks, 0)
        fail.withLock { $0 = false }
        await lifecycle.start()
        XCTAssertEqual(lifecycle.startup, .ready)
        XCTAssertEqual(saves.withLock({ $0 }), 2)
        XCTAssertEqual(sync.starts, 1)
        XCTAssertEqual(sync.stateManager.syncStatus, .idle)
        let saved = ModelContext(container)
        XCTAssertNotNil(try saved.fetch(FetchDescriptor<Vehicle>()).first?.cacheLastUpdated)
    }

    func testCancelledPreparationCanRestartWithoutStartingSyncEarly() async throws {
        let sync = try Sync()
        let lifecycle = ApplicationLifecycleCoordinator(container: try container(), syncService: sync)
        let task = Task { await lifecycle.start() }
        task.cancel()
        await task.value
        XCTAssertEqual(lifecycle.startup, .notStarted)
        XCTAssertEqual(sync.starts, 0)
        await lifecycle.start()
        XCTAssertEqual(lifecycle.startup, .ready)
        XCTAssertEqual(sync.starts, 1)
    }

    func testRepeatedStartupInitializesStoreOnceAndForegroundUsesSameFlow() async throws {
        let sync = try Sync()
        var initializations = 0
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync,
            initializeStore: { _ in initializations += 1 })
        await lifecycle.didBecomeActive()
        XCTAssertEqual(sync.availabilityChecks, 0)
        await lifecycle.start()
        await lifecycle.start()
        await lifecycle.didBecomeActive()
        XCTAssertEqual(initializations, 1)
        XCTAssertEqual(sync.starts, 2)
        XCTAssertEqual(sync.synchronizations, 2)
    }

    func testForegroundAndSecondStartCannotRaceStoreInitialization() async throws {
        let sync = try Sync()
        let entered = expectation(description: "Store initialization suspended")
        var release: CheckedContinuation<Void, Never>?
        var initializations = 0
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync,
            initializeStore: { _ in
                initializations += 1
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered.fulfill()
                }
            })
        let startup = Task { await lifecycle.start() }
        await fulfillment(of: [entered], timeout: 5)
        await lifecycle.didBecomeActive()
        await lifecycle.start()
        XCTAssertEqual(initializations, 1)
        XCTAssertEqual(sync.starts, 0)
        release?.resume()
        await startup.value
        XCTAssertEqual(sync.starts, 1)
    }

    func testInterruptedInitialSyncDoesNotStartCloudWork() async throws {
        let sync = try Sync()
        sync.stateManager.initialSyncCompleted = false
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync, initializeStore: { _ in })
        await lifecycle.start()
        await lifecycle.didBecomeActive()
        XCTAssertFalse(sync.stateManager.iCloudSyncEnabled)
        XCTAssertEqual(sync.stateManager.syncStatus, .idle)
        XCTAssertEqual(sync.availabilityChecks, 0)
        XCTAssertEqual(sync.starts, 0)
    }

    func testDisabledSyncDoesNotCheckCloudAccount() async throws {
        let sync = try Sync()
        sync.stateManager.iCloudSyncEnabled = false
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync, initializeStore: { _ in })
        await lifecycle.start()
        await lifecycle.didBecomeActive()
        XCTAssertEqual(sync.availabilityChecks, 0)
    }

    func testDisablingSyncDuringAccountCheckPreventsSessionStartup() async throws {
        let sync = try Sync()
        let entered = expectation(description: "Account check suspended")
        var release: CheckedContinuation<Bool, Never>?
        sync.availability = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync, initializeStore: { _ in })
        let startup = Task { await lifecycle.start() }
        await fulfillment(of: [entered], timeout: 5)
        sync.stateManager.iCloudSyncEnabled = false
        release?.resume(returning: true)
        await startup.value
        XCTAssertEqual(sync.starts, 0)
        XCTAssertEqual(sync.synchronizations, 0)
    }

    func testUnavailableAccountDoesNotStartEngine() async throws {
        let sync = try Sync()
        sync.availability = { false }
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync, initializeStore: { _ in })
        await lifecycle.start()
        XCTAssertEqual(sync.starts, 0)
        XCTAssertEqual(sync.synchronizations, 0)
    }

    func testInitializationFailureIsVisibleAndCanBeRetried() async throws {
        let sync = try Sync()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let lifecycle = ApplicationLifecycleCoordinator(
            container: try container(), syncService: sync,
            initializeStore: { _ in
                attempts.withLock { $0 += 1 }
                if attempts.withLock({ $0 }) == 1 { throw Failure.unavailableStore }
            })
        await lifecycle.start()
        guard case .error = sync.stateManager.syncStatus else { return XCTFail("Store failure hidden") }
        await lifecycle.didBecomeActive()
        XCTAssertEqual(sync.starts, 0)
        await lifecycle.start()
        XCTAssertEqual(attempts.withLock({ $0 }), 2)
        XCTAssertEqual(sync.starts, 1)
    }
}
