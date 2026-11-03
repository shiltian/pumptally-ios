import SwiftData
import SwiftUI
import XCTest
import os

@testable import PumpTally

@MainActor
final class PersistenceObservationTests: XCTestCase {
    func testCoreDataConcurrencyAssertionsAreEnabledInTheTestHost() {
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("-com.apple.CoreData.ConcurrencyDebug"))
    }

    private struct Snapshot: Equatable, Sendable {
        let names: [String]
        let notes: [String]
        let counts: [Int]
    }

    private final class Observer: Sendable {
        private let state = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)
        var snapshot: Snapshot? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    private struct RenderedSnapshot: UIViewRepresentable {
        let snapshot: Snapshot
        let observer: Observer
        func makeUIView(context: Context) -> UILabel { UILabel() }
        func updateUIView(_ label: UILabel, context: Context) {
            label.text = snapshot.names.joined(separator: ",")
            observer.snapshot = snapshot
        }
    }

    private func expect(
        _ snapshot: Snapshot, from observer: Observer, file: StaticString = #filePath, line: UInt = #line
    ) async {
        // Wait for rendered data, without triggering the next mutation from a
        // SwiftUI onChange/task callback inside the same rendering cycle.
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in observer.snapshot == snapshot }, object: nil)
        await fulfillment(of: [rendered], timeout: 5)
        XCTAssertEqual(observer.snapshot, snapshot, file: file, line: line)
    }

    private struct Probe: View {
        @Query(sort: \Vehicle.name) private var vehicles: [Vehicle]
        @Query private var records: [FuelingRecord]
        let observer: Observer

        var body: some View {
            let snapshot = Snapshot(
                names: vehicles.map(\.name),
                notes: records.map { $0.notes ?? "" }.sorted(),
                counts: vehicles.map { $0.cachedRecordCount ?? 0 })
            RenderedSnapshot(snapshot: snapshot, observer: observer)
        }
    }

    private func fixture() throws -> (ModelContainer, UUID, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("store")
        let schema = Schema(versionedSchema: SchemaV5.self)
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Original")
        let record = FuelingRecord(
            odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
            fuelAmount: 10.123456789, totalCost: 35.123456789, notes: "Original", vehicle: vehicle)
        context.insert(vehicle)
        context.insert(record)
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        try context.save()
        return (container, vehicle.id, url)
    }

    func testQueryObservesOwnedContextUpdatesRelationshipsAndDeletionOnDisk() async throws {
        // Optimized unit tests can start before UIKit connects the app scene.
        // Wait for its lifecycle notification before hosting an observation view.
        if !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
            let activated = expectation(forNotification: UIScene.didActivateNotification, object: nil)
            await fulfillment(of: [activated], timeout: 5)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let (container, vehicleID, _) = try fixture()
        let observer = Observer()
        let host = UIHostingController(rootView: Probe(observer: observer).modelContainer(container))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        await expect(Snapshot(names: ["Original"], notes: ["Original"], counts: [1]), from: observer)

        let reader = container.mainContext
        let vehicle = try XCTUnwrap(reader.fetch(FetchDescriptor<Vehicle>()).first)
        let record = try XCTUnwrap(vehicle.fuelingRecords?.first)
        let recordOriginal = FuelingRecordValues(record: record)
        var recordProposed = recordOriginal
        recordProposed.notes = "Updated"
        let writer = OwnedModelStore(container: container)
        let records = FuelingRecordPersistenceService(writer: writer)
        try await records.update(
            recordID: record.id, update: FuelingRecordUpdate(original: recordOriginal, proposed: recordProposed))
        await expect(Snapshot(names: ["Original"], notes: ["Updated"], counts: [1]), from: observer)
        _ = try await records.create(
            values: FuelingRecordValues(
                date: Date().addingTimeInterval(60), odometer: 1300, pricePerFuelUnit: 3,
                fuelAmount: 10, totalCost: 30, fillUpType: .full, notes: "New"), storageUnit: .imperial,
            vehicleID: vehicleID)
        let original = VehicleSettingsValues(vehicle: vehicle)
        var proposed = original
        proposed.name = "Renamed"
        try await VehiclePersistenceService(writer: writer).update(
            vehicleID: vehicleID, update: VehicleSettingsUpdate(original: original, proposed: proposed))
        await expect(Snapshot(names: ["Renamed"], notes: ["New", "Updated"], counts: [2]), from: observer)

        try await VehiclePersistenceService(writer: writer).delete(vehicleID: vehicleID)
        await expect(Snapshot(names: [], notes: [], counts: []), from: observer)
        _ = try await VehiclePersistenceService(writer: writer).create(
            values: VehicleSettingsValues(name: "Replacement"), storageUnit: .imperial)
        await expect(Snapshot(names: ["Replacement"], notes: [], counts: [0]), from: observer)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testRealReadOnlyStoreSaveFailureLeavesTheSavedGraphIntact() throws {
        let (_, _, url) = try fixture()
        let schema = Schema(versionedSchema: SchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
        do {
            let context = ModelContext(container)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>()).first)
            record.notes = "Must not persist"
            record.odometer = 0
            context.delete(record.vehicle)
            context.processPendingChanges()
            XCTAssertThrowsError(try context.save())
            context.rollback()
        }
        let fresh = ModelContext(container)
        let record = try XCTUnwrap(fresh.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.notes, "Original")
        XCTAssertEqual(record.odometer.bitPattern, Double(1000.123456789).bitPattern)
        XCTAssertEqual(record.vehicle.name, "Original")
        XCTAssertEqual(record.vehicle.cachedRecordCount, 1)
    }

    func testNativeBackgroundModelActorUpdatesTheRenderedQuery() async throws {
        if !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
            let activated = expectation(forNotification: UIScene.didActivateNotification, object: nil)
            await fulfillment(of: [activated], timeout: 5)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let (container, _, _) = try fixture()
        let observer = Observer()
        let host = UIHostingController(rootView: Probe(observer: observer).modelContainer(container))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await expect(Snapshot(names: ["Original"], notes: ["Original"], counts: [1]), from: observer)
        let writer = OwnedModelStore(container: container)
        let stageOnMain = try await writer.transaction { actor in
            let context = actor.modelContext
            let vehicle = try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>()).first)
            vehicle.name = "Background"
            let record = try XCTUnwrap(vehicle.fuelingRecords?.first)
            record.notes = "Background edit"
            return Thread.isMainThread
        }
        XCTAssertFalse(stageOnMain)
        await expect(Snapshot(names: ["Background"], notes: ["Background edit"], counts: [1]), from: observer)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testNativeBackgroundModelActorRollsBackCascadeFailureAndCanRetry() async throws {
        let (container, _, _) = try fixture()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let writer = OwnedModelStore(
            container: container,
            commit: { actor in
                let attempt = attempts.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 1 { throw CocoaError(.fileWriteOutOfSpace) }
                try actor.modelContext.save()
            })
        do {
            try await writer.transaction { actor in
                let context = actor.modelContext
                let vehicle = try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>()).first)
                context.delete(vehicle)
                context.processPendingChanges()
            }
            XCTFail("Expected save failure")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        try await writer.transaction { actor in
            let context = actor.modelContext
            XCTAssertFalse(Thread.isMainThread)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>()).first)
            XCTAssertEqual(record.notes, "Original")
            XCTAssertEqual(record.odometer.bitPattern, Double(1000.123456789).bitPattern)
            XCTAssertEqual(record.vehicle.name, "Original")
            record.notes = "Retry"
        }
        let reader = ModelContext(container)
        let record = try XCTUnwrap(reader.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.notes, "Retry")
        XCTAssertEqual(record.odometer.bitPattern, Double(1000.123456789).bitPattern)
    }

    func testNativeBackgroundWriterUsesTheModelExecutor() async throws {
        let (container, _, _) = try fixture()
        let writer = OwnedModelStore(container: container)
        let mainActorResponded = OSAllocatedUnfairLock(initialState: false)
        let isMain = try await writer.transaction { actor in
            try observeOnMainActor { mainActorResponded.withLock { $0 = true } }
            let record = try XCTUnwrap(actor.modelContext.fetch(FetchDescriptor<FuelingRecord>()).first)
            record.notes = "Background"
            return Thread.isMainThread
        }
        XCTAssertFalse(isMain)
        XCTAssertTrue(mainActorResponded.withLock { $0 })
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<FuelingRecord>()).first?.notes, "Background")
    }

    func testConcurrentRequestsSerializeReadModifySaveWithFreshContexts() async throws {
        let (container, _, _) = try fixture()
        let writer = OwnedModelStore(container: container)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await writer.transaction { actor in
                        XCTAssertFalse(Thread.isMainThread)
                        XCTAssertFalse(actor.modelContext.hasChanges)
                        let vehicle = try XCTUnwrap(actor.modelContext.fetch(FetchDescriptor<Vehicle>()).first)
                        vehicle.year = (vehicle.year ?? 0) + 1
                        try SyncChangeJournal.enqueue(vehicle, in: actor.modelContext)
                    }
                }
            }
            try await group.waitForAll()
        }
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<Vehicle>()).first?.year, 50)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<SyncChange>()), 1)
        let record = try XCTUnwrap(reader.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.odometer.bitPattern, Double(1000.123456789).bitPattern)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testCancelledSessionCloseDrainsAcceptedSaveAndRejectsQueuedCheckpoint() async throws {
        let (container, _, _) = try fixture()
        let writer = OwnedModelStore(container: container)
        let entered = expectation(description: "First save reached commit")
        let release = DispatchSemaphore(value: 0)
        let store = SyncPersistenceStore(
            writer: writer,
            commit: { actor in
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                try actor.modelContext.save()
            })
        let first = Task { try await store.saveEncodedState(Data("accepted".utf8)) }
        await fulfillment(of: [entered], timeout: 5)
        let queued = expectation(description: "Obsolete callback submitted")
        let obsolete = Task {
            queued.fulfill()
            try await store.saveEncodedState(Data("obsolete".utf8))
        }
        await fulfillment(of: [queued], timeout: 5)
        let closingStarted = expectation(description: "Session closing")
        let closed = OSAllocatedUnfairLock(initialState: false)
        let closing = Task {
            closingStarted.fulfill()
            await store.close()
            closed.withLock { $0 = true }
        }
        closing.cancel()
        await fulfillment(of: [closingStarted], timeout: 5)
        XCTAssertEqual(store.health, .closed)
        XCTAssertFalse(closed.withLock { $0 })
        release.signal()
        try await first.value
        await closing.value
        XCTAssertTrue(closed.withLock { $0 })
        do {
            try await obsolete.value
            XCTFail("A closed session must reject its queued checkpoint")
        } catch { XCTAssertEqual(error as? SyncPersistenceError, .recoveryRequired) }
        let reader = ModelContext(container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<SyncCheckpoint>()).first?.engineState, Data("accepted".utf8))
    }
}
