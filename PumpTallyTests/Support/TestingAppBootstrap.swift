import CloudKit
import SwiftData

/// Compiled into the app only by the Testing build configuration. Neither this
/// factory nor its launch arguments are present in Debug or Release builds.
@MainActor
enum AppBootstrap {
    private static var storeOpenAttempts = 0

    static func makeEnvironment() throws -> ApplicationEnvironment {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-store-open-failure") {
            storeOpenAttempts += 1
            if !arguments.contains("--ui-testing-store-open-retry") || storeOpenAttempts == 1 {
                try openUnavailableStore()
            }
        }
        if let recovery = try TestingRecoveryScenario.makeEnvironment(arguments: arguments) { return recovery }
        let container = try makeContainer(arguments: arguments)
        let suite = "PumpTally.Testing"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        defaults.removePersistentDomain(forName: suite)
        let state = SyncStateManager(defaults: defaults)
        state.iCloudSyncEnabled =
            !arguments.contains("--ui-testing-initial-sync") && !arguments.contains("--ui-testing-read-only-store")
        state.initialSyncCompleted = state.iCloudSyncEnabled
        let environment = TestingCloudSyncEnvironment()
        let context = container.mainContext
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        environment.records.vehicles = try context.fetch(FetchDescriptor<Vehicle>()).map { codec.vehicleToCKRecord($0) }
        environment.records.fuelingRecords = try context.fetch(FetchDescriptor<FuelingRecord>()).map {
            codec.fuelingRecordToCKRecord($0, vehicleRecordID: codec.vehicleToCKRecord($0.vehicle).recordID)
        }
        for pending in try context.fetch(FetchDescriptor<PendingRemoteChange>()) {
            if let record = try SyncPersistenceStore.PendingPayload.decode(pending.recordData).record() {
                environment.records.fuelingRecords.removeAll { $0.recordID == record.recordID }
                environment.records.fuelingRecords.append(record)
            }
        }
        if arguments.contains("--ui-testing-empty-cloud") { environment.records = CloudSyncSnapshot() }
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(writer: writer, stateManager: state, environment: environment)
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: service,
            lifecycle: ApplicationLifecycleCoordinator(writer: writer, syncService: service))
    }

    /// A file in place of the parent directory makes native container opening
    /// fail. This fixture never points at an application or user store.
    private static func openUnavailableStore() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Unavailable store directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let schema = Schema(versionedSchema: SchemaV5.self)
        _ = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [
                ModelConfiguration(
                    schema: schema, url: blocker.appendingPathComponent("records.store"), cloudKitDatabase: .none)
            ])
    }

    private static func makeContainer(arguments: [String]) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let readOnly = arguments.contains("--ui-testing-read-only-store")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UIFixture-\(UUID()).store")
        let configuration =
            readOnly
            ? ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let writable = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
        if arguments.contains("--ui-testing") { try seedFixture(in: writable.mainContext, arguments: arguments) }
        guard readOnly else { return writable }
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)])
    }

    private static func seedFixture(in context: ModelContext, arguments: [String]) throws {
        let vehicle = Vehicle(name: "UI Test Vehicle")
        let record = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
            fuelAmount: 10.123456789, totalCost: 35.123456789,
            notes: "Original UI note", vehicle: vehicle)
        context.insert(vehicle)
        context.insert(record)
        if arguments.contains("--ui-testing-zero-fuel") { record.fuelAmount = 0 }
        if arguments.contains("--ui-testing-two-records") {
            context.insert(
                FuelingRecord(
                    date: Date(timeIntervalSince1970: 1_700_086_400), odometer: 1300,
                    pricePerFuelUnit: 3, fuelAmount: 10, totalCost: 30,
                    fillUpType: arguments.contains("--ui-testing-partial-predecessor") ? .partial : .full,
                    notes: "Second UI note", vehicle: vehicle))
        }
        if arguments.contains("--ui-testing-legacy-record") || arguments.contains("--ui-testing-malformed-record") {
            let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "FuelioZone"))
            let incoming = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date()
            if arguments.contains("--ui-testing-malformed-record") {
                incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] = nil
            }
            try SyncPersistenceStore.stageInbound(
                .init(
                    kind: .modification, recordName: record.id.uuidString,
                    recordType: incoming.recordType, archivedRecord: CloudRecordCodec.archiveFullRecord(incoming)),
                in: context)
        }
        if arguments.contains("--ui-testing-legacy-deletion") {
            let deletion = SyncChange(
                recordName: record.id.uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
            deletion.originRaw = nil
            context.insert(deletion)
        }
        context.processPendingChanges()
        if !arguments.contains("--ui-testing-uncached-store") {
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        }
        try context.save()
    }
}
