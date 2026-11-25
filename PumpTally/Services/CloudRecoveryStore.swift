import CloudKit
import SwiftData

/// Reads persisted receipts so previous replacement work stays paused.
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

    nonisolated static func requireNoPendingRecovery(in context: ModelContext) throws {
        guard
            try context.fetchCount(
                FetchDescriptor<CloudRecoveryReceipt>(
                    predicate: #Predicate { $0.phaseRaw != "completed" && $0.phaseRaw != "superseded" })) == 0
        else { throw CloudRecoveryError.pendingReplacement }
    }

    nonisolated static func value(_ model: CloudRecoveryReceipt) throws -> Receipt {
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
