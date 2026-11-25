import CloudKit
import SwiftData

/// One preparation owns its read context. Only values selected for this
/// CloudKit batch leave the actor.
actor CloudChangeBatchBuilder: ModelActor {
    // CloudKit accepts 250 saves and deletes combined. The control record
    // occupies one slot in every request.
    private static let businessBatchLimit = 249

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

    private struct Request {
        let id: CKRecord.ID
        let operation: SyncChangeJournal.Operation

        init?(_ change: CKSyncEngine.PendingRecordZoneChange) {
            switch change {
            case .saveRecord(let id): self.id = id; operation = .save
            case .deleteRecord(let id): self.id = id; operation = .delete
            @unknown default: return nil
            }
        }
    }

    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    private var context: ModelContext { modelContext }
    private let codec: CloudRecordCodec
    private let blockedParents: Set<String>
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

    func build(pendingChanges: [CKSyncEngine.PendingRecordZoneChange], control: CloudSyncControl) throws
        -> PreparedBatch?
    {
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        var generations: [String: String] = [:]
        let limit = Self.businessBatchLimit
        windows: for offset in stride(from: 0, to: pendingChanges.count, by: limit) {
            try Task.checkCancellation()
            let requests = pendingChanges.dropFirst(offset).prefix(limit).compactMap(Request.init)
            let intents = try loadIntents(for: requests)
            for request in requests {
                guard let intent = intent(for: request.id, in: intents), intent.operation == request.operation else {
                    continue
                }
                switch intent.operation {
                case .save:
                    guard let record = try record(for: request.id, intent: intent) else { continue }
                    record[CloudSyncControl.businessGenerationField] = control.generation
                    saves.append(record)
                case .delete:
                    deletes.append(request.id)
                }
                generations[intent.key] = intent.generation
                if saves.count + deletes.count == limit { break windows }
            }
        }
        guard !generations.isEmpty else { return nil }
        let batch = CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: [control.batchRecord()] + saves, recordIDsToDelete: deletes, atomicByZone: true)
        return PreparedBatch(batch: batch, generations: generations)
    }

    private func loadIntents(for requests: [Request]) throws -> [String: Intent] {
        let keys = requests.flatMap { request in
            [SyncChangeJournal.RecordType.vehicle, .fuelingRecord].map { "\($0.rawValue):\(request.id.recordName)" }
        }
        guard !keys.isEmpty else { return [:] }
        let entries = try context.fetch(FetchDescriptor<SyncChange>(predicate: #Predicate { keys.contains($0.key) }))
        metrics.journalEntriesRead += entries.count
        var intents: [String: Intent] = [:]
        for entry in entries {
            guard let type = SyncChangeJournal.RecordType(rawValue: entry.recordTypeRaw),
                let operation = SyncChangeJournal.Operation(rawValue: entry.operationRaw),
                operation != .delete || entry.originRaw != nil
            else { continue }
            intents[entry.key] = Intent(key: entry.key, type: type, operation: operation, generation: entry.generation)
        }
        return intents
    }

    private func intent(for id: CKRecord.ID, in intents: [String: Intent]) -> Intent? {
        intents["\(SyncChangeJournal.RecordType.vehicle.rawValue):\(id.recordName)"]
            ?? intents["\(SyncChangeJournal.RecordType.fuelingRecord.rawValue):\(id.recordName)"]
    }

    private func record(for id: CKRecord.ID, intent: Intent) throws -> CKRecord? {
        guard let uuid = UUID(uuidString: id.recordName) else { return nil }
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
        return record
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
