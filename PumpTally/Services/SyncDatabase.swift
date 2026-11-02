import CloudKit
import SwiftData
import os

/// Synchronous database staging. The shared writer supplies the context and
/// commits once; SDK scheduling and UI state consume only the returned values.
struct SyncDatabase: Sendable {
    let codec: CloudRecordCodec
    private var zoneID: CKRecordZone.ID { codec.zoneID }
    private var reconciliationService: CloudReconciliationService { CloudReconciliationService(codec: codec) }
    private typealias RecordType = CloudRecordCodec.RecordType
    private typealias CloudFieldKey = CloudRecordCodec.CloudFieldKey
    private static let logger = Logger(subsystem: "me.tianshilei.fuelio", category: "CloudSync")

    struct Effects: Sendable {
        var additions: [CKSyncEngine.PendingRecordZoneChange] = []
        var removals: Set<CKRecord.ID> = []
        var clearedKeys: Set<String> = []
        var acknowledged: [String: String] = [:]
        var errors: [CKError] = []
    }

    struct Status: Sendable {
        let outboxCount: Int
        let inboxCount: Int
        let needsReview: Bool
    }

    func status(in context: ModelContext) throws -> Status {
        try Status(
            outboxCount: context.fetchCount(FetchDescriptor<SyncChange>()),
            inboxCount: context.fetchCount(FetchDescriptor<PendingRemoteChange>()),
            needsReview: hasChangesNeedingReview(in: context))
    }

    func pendingChanges(in context: ModelContext) throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try context.fetch(FetchDescriptor<SyncChange>()).compactMap { entry in
            guard let operation = SyncChangeJournal.Operation(rawValue: entry.operationRaw),
                operation != .delete || entry.originRaw != nil
            else { return nil }
            let id = CKRecord.ID(recordName: entry.recordName, zoneID: zoneID)
            switch operation {
            case .save: return .saveRecord(id)
            case .delete: return .deleteRecord(id)
            }
        }
    }

    func stageSent(_ sent: SyncEngineSentChanges, generations: [String: String], in context: ModelContext) throws
        -> Effects
    {
        var effects = Effects()
        for record in sent.savedRecords { try storeSystemFields(from: record, in: context) }
        for id in sent.deletedRecordIDs { try deleteSystemFields(for: id, in: context) }
        for id in sent.savedRecords.map(\.recordID) + sent.deletedRecordIDs {
            try acknowledge(id, generations: generations, effects: &effects, in: context)
        }
        for failure in sent.failedSaves {
            if failure.error.code == .serverRecordChanged,
                let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            {
                try storeSystemFields(from: server, in: context)
                let result = try reconciliationService.stageRemoteChanges(
                    changedRecords: [server], deletedRecordIDs: [], context: context)
                if result.recordsToUpload.contains(where: { $0.recordID == failure.record.recordID }) {
                    effects.additions.append(.saveRecord(failure.record.recordID))
                } else if result.deferredRecordNames.contains(failure.record.recordID.recordName)
                    || result.unresolvedChildIDs.contains(where: { $0.uuidString == failure.record.recordID.recordName }
                    )
                {
                    effects.errors.append(failure.error)
                } else {
                    try acknowledge(failure.record.recordID, generations: generations, effects: &effects, in: context)
                }
            } else {
                effects.errors.append(failure.error)
            }
        }
        for (id, error) in sent.failedDeletes {
            if error.code == .unknownItem {
                try acknowledge(id, generations: generations, effects: &effects, in: context)
            } else {
                effects.errors.append(error)
            }
        }
        return effects
    }

    func stageDeletedZone(in context: ModelContext) throws {
        try clearCloudMetadata(in: context)
        for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) {
            try SyncChangeJournal.enqueue(vehicle, in: context)
        }
        for record in try context.fetch(FetchDescriptor<FuelingRecord>()) {
            try SyncChangeJournal.enqueue(record, in: context)
        }
    }

    private func acknowledge(
        _ id: CKRecord.ID, generations: [String: String], effects: inout Effects, in context: ModelContext
    ) throws {
        guard let entry = try journalEntry(for: id, context: context), let generation = generations[entry.key] else {
            return
        }
        effects.acknowledged[entry.key] = generation
        try SyncChangeJournal.remove(key: entry.key, generation: generation, in: context)
        if let current = try journalEntry(for: id, context: context), current.generation != generation {
            effects.additions.append(current.operationRaw == "delete" ? .deleteRecord(id) : .saveRecord(id))
        }
    }

    private typealias PendingRemoteChangePayload = SyncPersistenceStore.PendingPayload

    private enum DecodedRemoteChange {
        case modification(CKRecord)
        case deletion(recordID: CKRecord.ID, recordType: String)

        var recordID: CKRecord.ID {
            switch self {
            case .modification(let record): return record.recordID
            case .deletion(let recordID, _): return recordID
            }
        }
    }

    private struct PendingRemoteChangeEntry {
        let key: String
        let change: DecodedRemoteChange
    }

    private func journalEntry(for recordID: CKRecord.ID, context: ModelContext) throws -> SyncChange? {
        let vehicleKey = "\(RecordType.vehicle):\(recordID.recordName)"
        var descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == vehicleKey })
        descriptor.fetchLimit = 1
        if let entry = try context.fetch(descriptor).first { return entry }

        let recordKey = "\(RecordType.fuelingRecord):\(recordID.recordName)"
        descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == recordKey })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func metadataKey(type: String, recordName: String) -> String {
        "\(type):\(recordName)"
    }

    private func storeSystemFields(from record: CKRecord, in context: ModelContext) throws {
        try SyncPersistenceStore.stageSystemFields(from: record, in: context)
    }

    private func deleteSystemFields(for recordID: CKRecord.ID, in context: ModelContext) throws {
        for type in [RecordType.vehicle, RecordType.fuelingRecord] {
            let key = metadataKey(type: type, recordName: recordID.recordName)
            var descriptor = FetchDescriptor<CloudRecordMetadata>(predicate: #Predicate { $0.key == key })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
            }
        }
    }

    func clearCloudMetadata(in context: ModelContext) throws {
        for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) {
            context.delete(metadata)
        }
    }

    func applyInbox(in context: ModelContext) throws -> Effects {
        var effects = Effects()
        let entries = try loadPendingRemoteChanges(in: context)
            .filter { $0.change.recordID.zoneID == zoneID }
        guard !entries.isEmpty else { return effects }

        var modificationsByID: [CKRecord.ID: CKRecord] = [:]
        var deletionsByID: [CKRecord.ID: String] = [:]
        for entry in entries {
            switch entry.change {
            case .modification(let record):
                modificationsByID[record.recordID] = record
            case .deletion(let recordID, let recordType):
                deletionsByID[recordID] = recordType
            }
        }

        let deletedKeys = Set(
            deletionsByID.map { entry in
                metadataKey(type: entry.value, recordName: entry.key.recordName)
            })
        let localDeleteKeys = Set(
            try context.fetch(FetchDescriptor<SyncChange>())
                .filter { $0.operationRaw == SyncChangeJournal.Operation.delete.rawValue && $0.originRaw != nil }
                .map(\.key))
        let changedRecords = modificationsByID.values.filter { record in
            let key = metadataKey(type: record.recordType, recordName: record.recordID.recordName)
            return !deletedKeys.contains(key) && !localDeleteKeys.contains(key)
        }
        let deletedRecordIDs = Array(deletionsByID.keys)
        var discardedInboxKeys = Set<String>()

        for (recordID, recordType) in deletionsByID where recordType == RecordType.vehicle {
            guard let vehicleID = UUID(uuidString: recordID.recordName) else { continue }
            var descriptor = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })
            descriptor.fetchLimit = 1
            if let vehicle = try context.fetch(descriptor).first {
                for child in vehicle.fuelingRecords ?? [] {
                    try SyncChangeJournal.enqueue(child, operation: .delete, in: context)
                }
            }
            discardedInboxKeys.formUnion(try removePendingRemoteChildren(of: vehicleID, in: context))
        }

        for record in changedRecords {
            try storeSystemFields(from: record, in: context)
        }
        for recordID in deletedRecordIDs {
            try deleteSystemFields(for: recordID, in: context)
        }

        let result = try reconciliationService.stageRemoteChanges(
            changedRecords: changedRecords,
            deletedRecordIDs: deletedRecordIDs,
            context: context
        )
        for record in result.recordsToUpload {
            effects.additions.append(.saveRecord(record.recordID))
        }
        if !result.unresolvedChildIDs.isEmpty {
            Self.logger.error(
                "Fetched \(result.unresolvedChildIDs.count) fueling records without a local parent vehicle")
        }

        let unresolvedNames = Set(result.unresolvedChildIDs.map(\.uuidString)).union(result.deferredRecordNames)
        for entry in entries where !discardedInboxKeys.contains(entry.key) {
            switch entry.change {
            case .modification(let record) where unresolvedNames.contains(record.recordID.recordName):
                continue
            case .modification:
                try deleteInboxEntry(key: entry.key, in: context)
            case .deletion(let recordID, _):
                try deleteInboxEntry(key: entry.key, in: context)
                effects.clearedKeys.formUnion(try removeJournalEntries(for: recordID, in: context))
                effects.removals.insert(recordID)
            }
        }

        return effects
    }

    func hasChangesNeedingReview(in context: ModelContext) throws -> Bool {
        if try context.fetchCount(FetchDescriptor<PendingRemoteChange>()) > 0 { return true }
        return try context.fetchCount(
            FetchDescriptor<SyncChange>(
                predicate: #Predicate {
                    $0.operationRaw == "delete" && $0.originRaw == nil
                })) > 0
    }

    private func deleteInboxEntry(key: String, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<PendingRemoteChange>(predicate: #Predicate { $0.key == key })
        for entry in try context.fetch(descriptor) { context.delete(entry) }
    }

    func blockedVehicleNames(in context: ModelContext) throws -> Set<String> {
        Set(
            try loadPendingRemoteChanges(in: context).compactMap { entry in
                guard case .modification(let record) = entry.change else { return nil }
                if record.recordType == RecordType.vehicle { return record.recordID.recordName }
                return record[CloudFieldKey.FuelingRecord.vehicleRef] as? String
            })
    }

    private func loadPendingRemoteChanges(in context: ModelContext) throws -> [PendingRemoteChangeEntry] {
        return try context.fetch(FetchDescriptor<PendingRemoteChange>()).map { pending in
            let payload = try PendingRemoteChangePayload.decode(pending.recordData)
            switch payload.kind {
            case .modification:
                guard let record = try payload.record() else { throw CocoaError(.fileReadCorruptFile) }
                return PendingRemoteChangeEntry(key: pending.key, change: .modification(record))
            case .deletion:
                let recordID = CKRecord.ID(recordName: payload.recordName, zoneID: zoneID)
                return PendingRemoteChangeEntry(
                    key: pending.key, change: .deletion(recordID: recordID, recordType: payload.recordType))
            }
        }
    }

    /// Removes unresolved remote children after their parent is deleted and
    /// returns the inbox keys removed so callers don't delete them twice.
    private func removePendingRemoteChildren(of vehicleID: UUID, in context: ModelContext) throws -> Set<String> {
        var removedKeys = Set<String>()
        for pending in try loadPendingRemoteChanges(in: context) {
            guard case .modification(let record) = pending.change,
                record.recordType == RecordType.fuelingRecord,
                record[CloudFieldKey.FuelingRecord.vehicleRef] as? String == vehicleID.uuidString
            else { continue }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName,
                recordType: .fuelingRecord,
                operation: .delete,
                in: context
            )
            try deleteInboxEntry(key: pending.key, in: context)
            removedKeys.insert(pending.key)
        }
        return removedKeys
    }

    private func removeJournalEntries(for recordID: CKRecord.ID, in context: ModelContext) throws -> Set<String> {
        var keys: Set<String> = []
        for type in [RecordType.vehicle, RecordType.fuelingRecord] {
            let key = metadataKey(type: type, recordName: recordID.recordName)
            var descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == key })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                keys.insert(key)
                context.delete(existing)
            }
        }
        return keys
    }

}
