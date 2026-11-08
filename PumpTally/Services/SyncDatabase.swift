import CloudKit
import SwiftData
import os

/// Synchronous database staging. The shared writer supplies the context and
/// commits once; SDK scheduling and UI state consume only the returned values.
struct SyncDatabase: Sendable {
    let codec: CloudRecordCodec
    var generation: String = CloudSyncControl.baselineGeneration
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
        var inboxMetrics = PendingRemoteInbox.Metrics()
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
        for record in sent.savedRecords {
            try CloudSyncControl.validateBusinessRecord(record, generation: generation)
            try storeSystemFields(from: record, in: context)
        }
        for id in sent.deletedRecordIDs { try deleteSystemFields(for: id, in: context) }
        for id in sent.savedRecords.map(\.recordID) + sent.deletedRecordIDs {
            try acknowledge(id, generations: generations, effects: &effects, in: context)
        }
        for failure in sent.failedSaves {
            if failure.error.code == .serverRecordChanged,
                let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            {
                try CloudSyncControl.validateBusinessRecord(server, generation: generation)
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
        let inbox = try PendingRemoteInbox(in: context)
        effects.inboxMetrics = inbox.metrics
        let entries = try inbox.entries.map { entry -> PendingRemoteChangeEntry in
            let change: DecodedRemoteChange
            switch try entry.decoded.get() {
            case .modification(let record): change = .modification(record)
            case .deletion(let name, let type):
                change = .deletion(recordID: CKRecord.ID(recordName: name, zoneID: zoneID), recordType: type)
            }
            return PendingRemoteChangeEntry(key: entry.key, change: change)
        }.filter { $0.change.recordID.zoneID == zoneID }
        guard !entries.isEmpty else { return effects }

        for entry in entries {
            switch entry.change {
            case .modification(let record) where record.recordType == CloudSyncControl.recordType:
                try CloudSyncControl(record: record, zone: zoneID).requireReady(generation: generation)
            case .modification(let record)
            where record.recordType == RecordType.vehicle || record.recordType == RecordType.fuelingRecord:
                try CloudSyncControl.validateBusinessRecord(record, generation: generation)
            case .deletion(let id, _) where id == CloudSyncControl.recordID(in: zoneID):
                throw CloudRecoveryError.generationChanged
            default: break
            }
        }

        var modificationsByID: [CKRecord.ID: CKRecord] = [:]
        var deletionsByID: [CKRecord.ID: String] = [:]
        for entry in entries {
            switch entry.change {
            case .modification(let record):
                if record.recordType != CloudSyncControl.recordType { modificationsByID[record.recordID] = record }
            case .deletion(let recordID, let recordType):
                deletionsByID[recordID] = recordType
            }
        }

        let deletedKeys = Set(
            deletionsByID.map { entry in
                metadataKey(type: entry.value, recordName: entry.key.recordName)
            })
        let localDeleteKeys = Set(
            try context.fetch(
                FetchDescriptor<SyncChange>(
                    predicate: #Predicate { $0.operationRaw == "delete" && $0.originRaw != nil }
                )
            ).map(\.key))
        let changedRecords = modificationsByID.values.filter { record in
            let key = metadataKey(type: record.recordType, recordName: record.recordID.recordName)
            return !deletedKeys.contains(key) && !localDeleteKeys.contains(key)
        }
        // An echo of the acknowledged server base cannot overwrite a newer
        // pending local edit, even when device clocks disagree. Compare before
        // replacing the metadata with the incoming system fields.
        var echoedBases = Set<CKRecord.ID>()
        for record in changedRecords {
            guard let incomingTag = record.recordChangeTag,
                let entry = try journalEntry(for: record.recordID, context: context), entry.operationRaw == "save"
            else { continue }
            let key = metadataKey(type: record.recordType, recordName: record.recordID.recordName)
            if let data = try context.fetch(
                FetchDescriptor<CloudRecordMetadata>(predicate: #Predicate { $0.key == key })
            ).first?.systemFieldsData {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
                decoder.requiresSecureCoding = true
                let known = CKRecord(coder: decoder)
                decoder.finishDecoding()
                if known?.recordID == record.recordID, known?.recordChangeTag == incomingTag {
                    echoedBases.insert(record.recordID)
                }
            }
        }
        let deletedRecordIDs = Array(deletionsByID.keys)
        var discardedInboxKeys = Set<String>()
        var discardedRecordIDs = Set<CKRecord.ID>()

        for (recordID, recordType) in deletionsByID where recordType == RecordType.vehicle {
            guard let vehicleID = UUID(uuidString: recordID.recordName) else { continue }
            var descriptor = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })
            descriptor.fetchLimit = 1
            if let vehicle = try context.fetch(descriptor).first {
                for child in vehicle.fuelingRecords ?? [] {
                    try SyncChangeJournal.enqueue(child, operation: .delete, in: context)
                }
            }
            let removed = try removePendingRemoteChildren(of: vehicleID, inbox: inbox, in: context)
            discardedInboxKeys.formUnion(removed.keys)
            discardedRecordIDs.formUnion(removed.recordIDs)
        }

        // These children already have deletion intent. Reconciliation must not
        // defer them back into the inbox after their parent has been removed.
        let applicableRecords = changedRecords.filter { !discardedRecordIDs.contains($0.recordID) }
        for record in applicableRecords {
            try storeSystemFields(from: record, in: context)
        }
        for recordID in deletedRecordIDs {
            try deleteSystemFields(for: recordID, in: context)
        }

        let result = try reconciliationService.stageRemoteChanges(
            changedRecords: applicableRecords.filter { !echoedBases.contains($0.recordID) },
            deletedRecordIDs: deletedRecordIDs,
            context: context, retainedInboxIDs: Set(applicableRecords.map(\.recordID))
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
        try PendingRemoteInbox(in: context).blockedVehicleNames()
    }

    /// Removes unresolved remote children after their parent is deleted and
    /// returns the inbox keys removed so callers don't delete them twice.
    private func removePendingRemoteChildren(
        of vehicleID: UUID, inbox: PendingRemoteInbox, in context: ModelContext
    ) throws -> (keys: Set<String>, recordIDs: Set<CKRecord.ID>) {
        var removedKeys = Set<String>()
        var removedIDs = Set<CKRecord.ID>()
        for pending in inbox.children(of: vehicleID.uuidString) {
            guard case .modification(let record) = try pending.decoded.get(),
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
            removedIDs.insert(record.recordID)
        }
        return (removedKeys, removedIDs)
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
