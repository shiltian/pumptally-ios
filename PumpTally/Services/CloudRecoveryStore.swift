import CloudKit
import SwiftData

/// The durable half of recovery. Each method stages one transition in the
/// shared writer; network work never runs inside these transactions.
@MainActor
struct CloudRecoveryStore {
    enum Phase: String, Sendable { case prepared, publishing, verified, completed, superseded }
    struct Receipt: Sendable {
        let id: UUID
        let scope: String
        let accountID: String
        let phase: Phase
        let manifest: CloudRecoveryManifest
        let verifiedRecords: [CKRecord]?
        var generation: String { id.uuidString }
    }
    let persistence: SyncPersistenceStore

    func pending() async throws -> Receipt? {
        try await persistence.transaction { actor in
            let pending = try actor.modelContext.fetch(
                FetchDescriptor<CloudRecoveryReceipt>(
                    predicate: #Predicate { $0.phaseRaw != "completed" && $0.phaseRaw != "superseded" }))
            guard pending.count <= 1 else { throw CloudRecoveryError.invalidReceipt }
            return try pending.first.map(Self.value)
        }
    }

    func prepare(
        accountID: String, scope: String, previousGeneration: String,
        codec: CloudRecordCodec, expectedLocalChanges: [String: String]? = nil
    ) async throws -> Receipt {
        try await persistence.transaction { actor in
            let context = actor.modelContext
            try Self.requireNoPendingRecovery(in: context)
            if let expectedLocalChanges,
                try InitialSyncProposal.localChanges(in: context) != expectedLocalChanges
            {
                throw InitialSyncError.localDataChanged
            }
            let records = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: context)
            let manifest = try CloudRecoveryManifest(
                version: 1, previousGeneration: previousGeneration,
                records: records.map(CloudRecordCodec.archiveFullRecord),
                journal: context.fetch(FetchDescriptor<SyncChange>()).map {
                    .init(
                        key: $0.key, recordName: $0.recordName, recordType: $0.recordTypeRaw,
                        operation: $0.operationRaw, generation: $0.generation, createdAt: $0.createdAt,
                        origin: $0.originRaw)
                },
                inbox: Self.inbox(in: context))
            let receipt = CloudRecoveryReceipt(
                id: UUID(), scope: scope, accountID: accountID,
                payload: try JSONEncoder().encode(manifest))
            context.insert(receipt)
            return try Self.value(receipt)
        }
    }

    func publishing(_ id: UUID, remoteRecords: [CKRecord]) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw == Phase.prepared.rawValue || receipt.phaseRaw == Phase.publishing.rawValue else {
                throw CloudRecoveryError.invalidReceipt
            }
            // Capture the old cloud values before any destructive business batch.
            if receipt.remoteBackup == nil {
                receipt.remoteBackup = try JSONEncoder().encode(remoteRecords.map(CloudRecordCodec.archiveFullRecord))
            }
            receipt.phaseRaw = Phase.publishing.rawValue
        }
    }

    func verified(_ id: UUID, records: [CKRecord]) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw == Phase.publishing.rawValue || receipt.phaseRaw == Phase.verified.rawValue else {
                throw CloudRecoveryError.invalidReceipt
            }
            receipt.verifiedRecords = try JSONEncoder().encode(records.map(CloudRecordCodec.archiveFullRecord))
            receipt.phaseRaw = Phase.verified.rawValue
        }
    }

    func supersede(_ id: UUID) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw != Phase.completed.rawValue else { throw CloudRecoveryError.invalidReceipt }
            receipt.phaseRaw = Phase.superseded.rawValue
        }
    }

    func complete(_ receipt: Receipt, codec: CloudRecordCodec) async throws {
        guard let records = receipt.verifiedRecords else { throw CloudRecoveryError.invalidReceipt }
        try await persistence.activate(accountID: receipt.accountID, generation: receipt.generation) { actor in
            let context = actor.modelContext
            let model = try Self.model(receipt.id, in: context)
            guard model.phaseRaw == Phase.verified.rawValue else { throw CloudRecoveryError.invalidReceipt }
            let database = SyncDatabase(codec: codec)
            try database.clearCloudMetadata(in: context)
            for record in records { try SyncPersistenceStore.stageSystemFields(from: record, in: context) }
            // All old-session callbacks were drained before the receipt was made.
            // Preserve any remaining original bytes before removing replay work.
            model.retainedInbox = try JSONEncoder().encode(Self.inbox(in: context))
            for entry in try context.fetch(FetchDescriptor<PendingRemoteChange>()) { context.delete(entry) }
            for entry in receipt.manifest.journal {
                try SyncChangeJournal.remove(key: entry.key, generation: entry.generation, in: context)
            }
            model.phaseRaw = Phase.completed.rawValue
        }
    }

    nonisolated static func requireNoPendingRecovery(in context: ModelContext) throws {
        guard
            try context.fetchCount(
                FetchDescriptor<CloudRecoveryReceipt>(
                    predicate: #Predicate { $0.phaseRaw != "completed" && $0.phaseRaw != "superseded" })) == 0
        else { throw CloudRecoveryError.pendingReplacement }
    }

    nonisolated private static func inbox(in context: ModelContext) throws -> [CloudRecoveryManifest.InboxEntry] {
        try context.fetch(FetchDescriptor<PendingRemoteChange>()).map { .init(key: $0.key, data: $0.recordData) }
    }

    nonisolated private static func model(_ id: UUID, in context: ModelContext) throws -> CloudRecoveryReceipt {
        guard
            let receipt = try context.fetch(
                FetchDescriptor<CloudRecoveryReceipt>(predicate: #Predicate { $0.id == id })
            ).first
        else {
            throw CloudRecoveryError.invalidReceipt
        }
        return receipt
    }

    nonisolated private static func value(_ model: CloudRecoveryReceipt) throws -> Receipt {
        guard let phase = Phase(rawValue: model.phaseRaw) else { throw CloudRecoveryError.invalidReceipt }
        let manifest = try JSONDecoder().decode(CloudRecoveryManifest.self, from: model.payload)
        guard manifest.version == 1 else { throw CloudRecoveryError.invalidReceipt }
        let records = try model.verifiedRecords.map { data in
            try JSONDecoder().decode([Data].self, from: data).map { archive in
                guard let record = try CloudRecordCodec.unarchiveFullRecord(from: archive) else {
                    throw CloudRecoveryError.invalidReceipt
                }
                return record
            }
        }
        return Receipt(
            id: model.id, scope: model.scope, accountID: model.accountID,
            phase: phase, manifest: manifest, verifiedRecords: records)
    }
}
