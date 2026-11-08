import SwiftData
import XCTest

@testable import PumpTally

@MainActor
final class ApplicationEnvironmentLoaderTests: XCTestCase {
    private struct RecordSnapshot: Equatable {
        let id: UUID
        let vehicleID: UUID
        let date: Date
        let odometer: UInt64
        let price: UInt64
        let fuel: UInt64
        let cost: UInt64
        let notes: String?
        let createdAt: Date
        let modifiedAt: Date?

        init(_ record: FuelingRecord) {
            id = record.id
            vehicleID = record.vehicle.id
            date = record.date
            odometer = record.odometer.bitPattern
            price = record.pricePerFuelUnit.bitPattern
            fuel = record.fuelAmount.bitPattern
            cost = record.totalCost.bitPattern
            notes = record.notes
            createdAt = record.createdAt
            modifiedAt = record.modifiedAt
        }
    }

    private func openStore(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let configuration =
            url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
    }

    private func environment(
        container: ModelContainer, cloud: TestingCloudSyncEnvironment,
        initializeStore: (@MainActor (ModelContainer) async throws -> Void)? = nil
    ) throws -> ApplicationEnvironment {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StoreOpening.\(UUID())"))
        let state = SyncStateManager(defaults: defaults)
        state.iCloudSyncEnabled = false
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(writer: writer, stateManager: state, environment: cloud)
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: service,
            lifecycle: ApplicationLifecycleCoordinator(
                writer: writer, syncService: service, initializeStore: initializeStore))
    }

    private func snapshots(in container: ModelContainer) throws -> [RecordSnapshot] {
        try ModelContext(container).fetch(FetchDescriptor<FuelingRecord>())
            .map(RecordSnapshot.init).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func files(in directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(
            uniqueKeysWithValues: urls.filter { !$0.hasDirectoryPath }.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
    }

    func testActualOpenFailurePreserves800SavedRecordsAndRetryOpensTheSameStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Store", isDirectory: false)
        let unavailable = root.appendingPathComponent("Unavailable", isDirectory: true)
        let url = directory.appendingPathComponent("records.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original: [RecordSnapshot]
        let journalGeneration: String
        do {
            let container = try openStore(at: url)
            let context = ModelContext(container)
            let vehicle = Vehicle(name: "Existing five-year history")
            context.insert(vehicle)
            for index in 0..<800 {
                let record = FuelingRecord(
                    date: Date(timeIntervalSince1970: 1_500_000_000 + Double(index) * 200_000),
                    odometer: 1000.123456789 + Double(index) * 300,
                    pricePerFuelUnit: 3.459876543 + Double(index % 5),
                    fuelAmount: 10.123456789, totalCost: 35.123456789,
                    notes: "Original record \(index) · 保留\n  exact text  ", vehicle: vehicle)
                record.modifiedAt = record.date
                context.insert(record)
                if index == 799 { try SyncChangeJournal.enqueue(record, in: context) }
            }
            try context.save()
            original = try snapshots(in: container)
            journalGeneration = try XCTUnwrap(context.fetch(FetchDescriptor<SyncChange>()).first?.generation)
        }

        // Retain every database file together. A file at its original parent
        // path then causes a real native open failure without touching it.
        try FileManager.default.moveItem(at: directory, to: unavailable)
        let blocker = Data("Unavailable store directory".utf8)
        try blocker.write(to: directory)
        let retainedFiles = try files(in: unavailable)
        let cloud = TestingCloudSyncEnvironment()
        var attempts = 0
        var constructedEnvironments = 0
        let loader = ApplicationEnvironmentLoader {
            attempts += 1
            let container = try self.openStore(at: url)
            constructedEnvironments += 1
            return try self.environment(container: container, cloud: cloud)
        }
        guard case .notStarted = loader.state else { return XCTFail("Store opened during construction") }
        XCTAssertEqual(attempts, 0)
        for _ in 0..<2 {
            loader.open()
            guard case .failed(let message) = loader.state else { return XCTFail("Failed open was hidden") }
            XCTAssertEqual(message, String(localized: "Your saved data could not be opened. Please try again."))
            XCTAssertEqual(try files(in: unavailable), retainedFiles)
            XCTAssertEqual(try Data(contentsOf: directory), blocker)
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(constructedEnvironments, 0)
        XCTAssertEqual(cloud.accountReads, 0)
        XCTAssertTrue(cloud.drivers.isEmpty)

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: unavailable, to: directory)
        loader.open()
        guard case .ready(let ready) = loader.state else { return XCTFail("Repaired store did not reopen") }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(constructedEnvironments, 1)
        XCTAssertEqual(ready.modelContainer.configurations.first?.url, url)
        XCTAssertEqual(try snapshots(in: ready.modelContainer), original)
        let reader = ModelContext(ready.modelContainer)
        let changes = try reader.fetch(FetchDescriptor<SyncChange>())
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.generation, journalGeneration)
        XCTAssertEqual(ready.lifecycle.startup, .notStarted)
        XCTAssertFalse(ready.modelContainer.mainContext.hasChanges)
        XCTAssertEqual(cloud.accountReads, 0)
        XCTAssertTrue(cloud.drivers.isEmpty)
    }

    func testRepeatedWindowOpeningReusesTheReadyEnvironmentWithoutStartingSync() throws {
        let cloud = TestingCloudSyncEnvironment()
        let container = try openStore()
        var attempts = 0
        let loader = ApplicationEnvironmentLoader {
            attempts += 1
            return try self.environment(container: container, cloud: cloud)
        }
        loader.open()
        guard case .ready(let first) = loader.state else { return XCTFail("Missing ready environment") }
        loader.open()
        guard case .ready(let second) = loader.state else { return XCTFail("Ready environment was lost") }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(first.modelContainer === second.modelContainer)
        XCTAssertTrue(first.writer === second.writer)
        XCTAssertTrue(first.cloudSyncService === second.cloudSyncService)
        XCTAssertEqual(first.lifecycle.startup, .notStarted)
        XCTAssertEqual(cloud.accountReads, 0)
        XCTAssertTrue(cloud.drivers.isEmpty)
    }

    func testCachePreparationRetryKeepsTheSuccessfullyOpenedEnvironment() async throws {
        let cloud = TestingCloudSyncEnvironment()
        let container = try openStore()
        var opens = 0
        var preparations = 0
        let loader = ApplicationEnvironmentLoader {
            opens += 1
            return try self.environment(container: container, cloud: cloud) { _ in
                preparations += 1
                if preparations == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            }
        }
        loader.open()
        guard case .ready(let opened) = loader.state else { return XCTFail("Store failed to open") }
        await opened.lifecycle.start()
        guard case .failed = opened.lifecycle.startup else { return XCTFail("Preparation error was hidden") }
        await opened.lifecycle.didBecomeActive()
        loader.open()
        XCTAssertEqual(opens, 1)
        await opened.lifecycle.start()
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(opened.lifecycle.startup, .ready)
        XCTAssertEqual(cloud.accountReads, 0)
        XCTAssertTrue(cloud.drivers.isEmpty)
    }
}
