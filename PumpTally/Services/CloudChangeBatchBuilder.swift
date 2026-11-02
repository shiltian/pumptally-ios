import CloudKit
import SwiftData

/// One preparation owns its read context. CKSyncEngine chooses the batch size
/// and requests record values lazily; no SwiftData model leaves this actor.
actor CloudChangeBatchBuilder: ModelActor {
    struct Metrics: Sendable {
        var journalEntriesRead = 0
        var vehiclesRead = 0
        var fuelingRecordsRead = 0
        var metadataRead = 0
        var recordsEncoded = 0
    }

    struct PreparedBatch: Sendable {
        let batch: CKSyncEngine.RecordZoneChangeBatch
        let generations: [String: String]
    }

    private struct Intent {
        let key: String
        let type: SyncChangeJournal.RecordType
        let operation: SyncChangeJournal.Operation
        let generation: String
    }

    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    private var context: ModelContext { modelContext }
    private let codec: CloudRecordCodec
    private let blockedParents: Set<String>
    private var intents: [String: Intent] = [:]
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var failure: Error?
    private(set) var metrics = Metrics()

    private init(container: ModelContainer, codec: CloudRecordCodec, blockedParents: Set<String>) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.codec = codec
        self.blockedParents = blockedParents
    }

    static func make(container: ModelContainer, codec: CloudRecordCodec, blockedParents: Set<String>) async
        -> CloudChangeBatchBuilder
    {
        await Task.detached(priority: .utility) {
            CloudChangeBatchBuilder(container: container, codec: codec, blockedParents: blockedParents)
        }.value
    }

    func build(pendingChanges: [CKSyncEngine.PendingRecordZoneChange]) async throws -> PreparedBatch? {
        let keys = pendingChanges.flatMap { change -> [String] in
            let id: CKRecord.ID
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID): id = recordID
            @unknown default: return []
            }
            return [SyncChangeJournal.RecordType.vehicle, .fuelingRecord].map { "\($0.rawValue):\(id.recordName)" }
        }
        guard !keys.isEmpty else { return nil }
        let entries = try context.fetch(FetchDescriptor<SyncChange>(predicate: #Predicate { keys.contains($0.key) }))
        metrics.journalEntriesRead = entries.count
        for entry in entries {
            guard let type = SyncChangeJournal.RecordType(rawValue: entry.recordTypeRaw),
                let operation = SyncChangeJournal.Operation(rawValue: entry.operationRaw),
                operation != .delete || entry.originRaw != nil
            else { continue }
            intents[entry.key] = Intent(key: entry.key, type: type, operation: operation, generation: entry.generation)
        }
        let eligible = pendingChanges.filter { change in
            switch change {
            case .saveRecord(let id): return intent(for: id)?.operation == .save
            case .deleteRecord(let id): return intent(for: id)?.operation == .delete
            @unknown default: return false
            }
        }
        guard !eligible.isEmpty else { return nil }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: eligible) { id in
            await self.record(for: id)
        }
        // The provider cannot throw. Fail the whole preparation if any requested
        // record is invalid, rather than sending a partially validated batch.
        if let failure { throw failure }
        guard let batch else { return nil }
        var generations: [String: String] = [:]
        for id in batch.recordsToSave.map(\.recordID) + batch.recordIDsToDelete {
            if let intent = intent(for: id) { generations[intent.key] = intent.generation }
        }
        return PreparedBatch(batch: batch, generations: generations)
    }

    private func intent(for id: CKRecord.ID) -> Intent? {
        intents["\(SyncChangeJournal.RecordType.vehicle.rawValue):\(id.recordName)"]
            ?? intents["\(SyncChangeJournal.RecordType.fuelingRecord.rawValue):\(id.recordName)"]
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        if let record = records[id] { return record }
        guard failure == nil, let intent = intent(for: id), intent.operation == .save,
            let uuid = UUID(uuidString: id.recordName)
        else { return nil }
        do {
            let record: CKRecord
            switch intent.type {
            case .vehicle:
                guard !blockedParents.contains(id.recordName) else { return nil }
                var query = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == uuid })
                query.fetchLimit = 1
                let vehicles = try context.fetch(query)
                metrics.vehiclesRead += vehicles.count
                guard let vehicle = vehicles.first else { return nil }
                record = codec.vehicleToCKRecord(vehicle, existingRecord: try systemFields(for: intent, id: id))
            case .fuelingRecord:
                var query = FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == uuid })
                query.fetchLimit = 1
                let records = try context.fetch(query)
                metrics.fuelingRecordsRead += records.count
                guard let model = records.first else { return nil }
                let owner = model.vehicle.id.uuidString
                guard !blockedParents.contains(owner) else { return nil }
                record = codec.fuelingRecordToCKRecord(
                    model, vehicleRecordID: CKRecord.ID(recordName: owner, zoneID: codec.zoneID),
                    existingRecord: try systemFields(for: intent, id: id))
            }
            try codec.validateOutgoing(record)
            metrics.recordsEncoded += 1
            records[id] = record
            return record
        } catch {
            failure = error
            return nil
        }
    }

    private func systemFields(for intent: Intent, id: CKRecord.ID) throws -> CKRecord? {
        let key = intent.key
        var query = FetchDescriptor<CloudRecordMetadata>(predicate: #Predicate { $0.key == key })
        query.fetchLimit = 1
        let rows = try context.fetch(query)
        metrics.metadataRead += rows.count
        guard let data = rows.first?.systemFieldsData else { return nil }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        guard let record = CKRecord(coder: unarchiver), record.recordID == id,
            record.recordType == intent.type.rawValue
        else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }
}
