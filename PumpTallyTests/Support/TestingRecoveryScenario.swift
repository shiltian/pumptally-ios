import CloudKit
import SwiftData

/// Testing/Benchmark composition only. Existing synthetic receipts survive
/// relaunch while the real application service refuses further publication.
@MainActor
enum TestingRecoveryScenario {
    private struct CloudArchive: Codable {
        let records: [Data]
        let control: Data?
    }

    static func makeEnvironment(arguments: [String]) throws -> ApplicationEnvironment? {
        guard let phase = argument("--ui-testing-recovery-phase=", in: arguments) else { return nil }
        guard ["prepared", "publishing", "verified", "resume"].contains(phase),
            let identifier = argument("--ui-testing-recovery-id=", in: arguments).flatMap(UUID.init(uuidString:))
        else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecoveryUITests").appendingPathComponent(identifier.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("local.store")
        let cloudURL = directory.appendingPathComponent("synthetic-cloud.json")
        let existed = FileManager.default.fileExists(atPath: storeURL.path)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)])
        let environment = TestingCloudSyncEnvironment()
        guard let defaults = UserDefaults(suiteName: "RecoveryUITest.\(identifier)") else {
            throw CocoaError(.fileReadUnknown)
        }
        let state = SyncStateManager(defaults: defaults)
        if !existed {
            guard phase != "resume" else { throw CocoaError(.fileReadNoSuchFile) }
            try seed(container: container, environment: environment)
            try seedReceipt(phase: phase, container: container, environment: environment)
            state.iCloudSyncEnabled = true
            state.initialSyncCompleted = true
            try saveCloud(environment.records, at: cloudURL)
        } else {
            environment.records = try loadCloud(at: cloudURL)
        }
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(writer: writer, stateManager: state, environment: environment)
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: service,
            lifecycle: ApplicationLifecycleCoordinator(writer: writer, syncService: service))
    }

    private static func seedReceipt(
        phase: String, container: ModelContainer, environment: TestingCloudSyncEnvironment
    ) throws {
        let context = ModelContext(container)
        let codec = CloudRecordCodec(zoneID: environment.recordZoneID)
        let chosen = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: context)
        let manifest = try CloudRecoveryManifest(
            version: 1, previousGeneration: CloudSyncControl.baselineGeneration,
            records: chosen.map(CloudRecordCodec.archiveFullRecord),
            journal: context.fetch(FetchDescriptor<SyncChange>()).map {
                .init(
                    key: $0.key, recordName: $0.recordName, recordType: $0.recordTypeRaw,
                    operation: $0.operationRaw, generation: $0.generation, createdAt: $0.createdAt,
                    origin: $0.originRaw)
            },
            inbox: context.fetch(FetchDescriptor<PendingRemoteChange>()).map {
                .init(key: $0.key, data: $0.recordData)
            })
        let receipt = CloudRecoveryReceipt(
            id: UUID(), scope: environment.scopeIdentifier, accountID: environment.userID,
            payload: try JSONEncoder().encode(manifest))
        receipt.phaseRaw = phase
        receipt.remoteBackup = try JSONEncoder().encode(
            environment.records.businessRecords.map(CloudRecordCodec.archiveFullRecord))
        if phase == "verified" {
            receipt.verifiedRecords = try JSONEncoder().encode(chosen.map(CloudRecordCodec.archiveFullRecord))
        }
        context.insert(receipt)
        try context.save()
    }

    private static func argument(_ prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    private static func seed(container: ModelContainer, environment: TestingCloudSyncEnvironment) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let codec = CloudRecordCodec(zoneID: environment.recordZoneID)
        let vehicle = Vehicle(name: "Recovery UI Fixture", createdAt: Date(timeIntervalSince1970: 1_000_000))
        context.insert(vehicle)
        for index in 0..<800 {
            let record = FuelingRecord(
                date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                odometer: 1000.123456789 + Double(index) * 300, pricePerFuelUnit: 3.459876543,
                fuelAmount: 10.123456789, totalCost: 35.123456789, notes: "Trusted recovery record \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
            context.insert(record)
            try SyncChangeJournal.enqueue(record, in: context)
        }
        context.processPendingChanges()
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        let checkpoint = SyncCheckpoint(key: "FuelioZone.private")
        checkpoint.accountID = environment.userID
        checkpoint.bootstrapCompleted = true
        checkpoint.detached = true
        context.insert(checkpoint)
        context.insert(PendingRemoteChange(key: "old-unreadable-delivery", recordData: Data([0, 255])))
        try context.save()
        environment.records.vehicles = [codec.vehicleToCKRecord(vehicle)]
        environment.records.fuelingRecords = (vehicle.fuelingRecords ?? []).map { record in
            let cloud = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.totalCost] = 0.0
            cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 9_000_000)
            return cloud
        }
    }

    private static func saveCloud(_ snapshot: CloudSyncSnapshot, at url: URL) throws {
        let archive = try CloudArchive(
            records: snapshot.businessRecords.map(CloudRecordCodec.archiveFullRecord),
            control: snapshot.control.map(CloudRecordCodec.archiveFullRecord))
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }

    private static func loadCloud(at url: URL) throws -> CloudSyncSnapshot {
        let archive = try JSONDecoder().decode(CloudArchive.self, from: Data(contentsOf: url))
        let records = try archive.records.map { data in
            guard let record = try CloudRecordCodec.unarchiveFullRecord(from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return record
        }
        return try CloudSyncSnapshot(
            vehicles: records.filter { $0.recordType == CloudRecordType.vehicle },
            fuelingRecords: records.filter { $0.recordType == CloudRecordType.fuelingRecord },
            control: archive.control.flatMap(CloudRecordCodec.unarchiveFullRecord))
    }

}
