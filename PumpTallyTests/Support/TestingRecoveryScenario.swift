import CloudKit
import SwiftData
import os

/// Testing/Benchmark composition only. Persistent synthetic cloud and local
/// stores survive termination; neither uses CloudKit nor a production store.
@MainActor
enum TestingRecoveryScenario {
    enum Cutpoint: String, Sendable { case prepared, publishing, businessAcknowledged, verified, completed, resume }
    private struct CloudArchive: Codable {
        let records: [Data]
        let control: Data?
    }

    static func makeEnvironment(arguments: [String]) throws -> ApplicationEnvironment? {
        guard let raw = argument("--ui-testing-recovery-phase=", in: arguments) else { return nil }
        guard let cutpoint = Cutpoint(rawValue: raw),
            let identifier = argument("--ui-testing-recovery-id=", in: arguments).flatMap(UUID.init(uuidString:)),
            let expected = argument("--ui-testing-recovery-expected=", in: arguments)
        else { throw CocoaError(.fileReadCorruptFile) }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecoveryUITests").appendingPathComponent(identifier.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("local.store")
        let cloudURL = directory.appendingPathComponent("synthetic-cloud.json")
        let marker = directory.appendingPathComponent("reached-cutpoint.txt")
        let existed = FileManager.default.fileExists(atPath: storeURL.path)
        if cutpoint == .resume {
            guard try String(contentsOf: marker, encoding: .utf8) == expected else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let schema = Schema(versionedSchema: SchemaV5.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)])
        let environment = TestingCloudSyncEnvironment()
        guard let defaults = UserDefaults(suiteName: "RecoveryUITest.\(identifier)") else {
            throw CocoaError(.fileReadUnknown)
        }
        let state = SyncStateManager(defaults: defaults)
        if !existed {
            try seed(container: container, environment: environment)
            state.iCloudSyncEnabled = false
            state.initialSyncCompleted = false
            try saveCloud(environment.records, at: cloudURL)
        } else {
            environment.records = try loadCloud(at: cloudURL)
        }
        let gate = Gate(state: state, cutpoint: cutpoint, marker: marker)
        environment.afterBatch = { [weak environment] batch in
            guard let environment else { throw CancellationError() }
            try saveCloud(environment.records, at: cloudURL)
            if cutpoint == .businessAcknowledged,
                batch.recordsToSave.contains(where: { $0.recordType != CloudSyncControl.recordType })
            {
                try await gate.pauseAfterBusinessAcknowledgement()
            }
        }
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(
            writer: writer, stateManager: state, environment: environment,
            makePersistenceStore: { writer in
                SyncPersistenceStore(
                    writer: writer,
                    commit: { actor in
                        try actor.modelContext.save()
                        if let phase = try actor.modelContext.fetch(FetchDescriptor<CloudRecoveryReceipt>()).first?
                            .phaseRaw
                        {
                            try gate.pauseAfterCommit(phase)
                        }
                    })
            })
        return ApplicationEnvironment(
            writer: writer, cloudSyncService: service,
            lifecycle: ApplicationLifecycleCoordinator(writer: writer, syncService: service))
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

    @MainActor
    private final class Gate {
        let state: SyncStateManager
        nonisolated let cutpoint: Cutpoint
        nonisolated let marker: URL
        nonisolated let entered = OSAllocatedUnfairLock(initialState: false)
        private let suspended = AsyncStream<Void>.makeStream()

        init(state: SyncStateManager, cutpoint: Cutpoint, marker: URL) {
            self.state = state
            self.cutpoint = cutpoint
            self.marker = marker
        }

        nonisolated func pauseAfterCommit(_ phase: String) throws {
            guard phase == cutpoint.rawValue else { return }
            let first = entered.withLock { value in
                let first = !value
                value = true
                return first
            }
            guard first else { return }
            try Data(phase.utf8).write(to: marker, options: .atomic)
            Task { @MainActor in self.state.syncStatus = .error("Recovery test checkpoint: \(phase)") }
            // The UI test terminates the process after observing this checkpoint.
            // Only a background model executor waits; the UI remains responsive.
            DispatchSemaphore(value: 0).wait()
        }

        func pauseAfterBusinessAcknowledgement() async throws {
            let first = entered.withLock { value in
                let first = !value
                value = true
                return first
            }
            guard first else { return }
            try Data(cutpoint.rawValue.utf8).write(to: marker, options: .atomic)
            state.syncStatus = .error("Recovery test checkpoint: \(cutpoint.rawValue)")
            for await _ in suspended.stream { break }
        }
    }
}
