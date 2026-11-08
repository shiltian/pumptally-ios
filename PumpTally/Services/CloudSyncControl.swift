import CloudKit
import Foundation

enum CloudRecoveryError: LocalizedError, Equatable, Sendable {
    case invalidControl, replacementInProgress, generationChanged
    case pendingReplacement, invalidReceipt, verificationFailed, incompleteBatch
    case replacementUnavailable

    var errorDescription: String? {
        switch self {
        case .replacementUnavailable:
            return String(
                localized: "Replacing iCloud data is unavailable while older app versions may still be using it.")
        case .invalidControl:
            return String(localized: "The iCloud sync format is not supported. Update PumpTally before syncing.")
        case .replacementInProgress:
            return String(localized: "iCloud data is being replaced. Try syncing again after replacement finishes.")
        case .generationChanged:
            return String(
                localized: "iCloud data was replaced on another device. Enable sync again to choose which data to use.")
        case .pendingReplacement:
            return String(localized: "Finish the pending iCloud replacement before changing sync settings.")
        case .invalidReceipt:
            return String(
                localized: "The saved iCloud replacement could not be read. Your original data has been kept.")
        case .verificationFailed:
            return String(
                localized: "The iCloud replacement could not be verified. Your saved snapshot is available to resume.")
        case .incompleteBatch:
            return String(
                localized:
                    "The iCloud changes could not be confirmed. Try syncing again. Your saved data has been kept.")
        }
    }
}

/// A server-side generation fence. Every business batch writes a fresh nonce
/// on this record with its observed change tag, atomically with its mutations.
struct CloudSyncControl: Sendable {
    enum Phase: String { case ready, replacing }
    static let recordType = CloudRecordType.control
    static let recordName = "PumpTallySyncControl"
    static let baselineGeneration = "baseline"
    static let businessGenerationField = "syncGenerationV1"

    let record: CKRecord
    let generation: String
    let phase: Phase

    static func recordID(in zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zone)
    }

    init(record: CKRecord, zone: CKRecordZone.ID) throws {
        guard record.recordType == Self.recordType, record.recordID == Self.recordID(in: zone),
            (record["version"] as? Int) == 1,
            let generation = record["generation"] as? String, !generation.isEmpty,
            let raw = record["phase"] as? String, let phase = Phase(rawValue: raw)
        else { throw CloudRecoveryError.invalidControl }
        self.record = record
        self.generation = generation
        self.phase = phase
    }

    static func baseline(in zone: CKRecordZone.ID) throws -> Self {
        let record = CKRecord(recordType: recordType, recordID: recordID(in: zone))
        record["version"] = 1
        record["generation"] = baselineGeneration
        record["phase"] = Phase.ready.rawValue
        return try Self(record: record, zone: zone)
    }

    func changing(generation: String, phase: Phase) throws -> Self {
        let copy = record.copy() as! CKRecord
        copy["generation"] = generation
        copy["phase"] = phase.rawValue
        copy["transaction"] = UUID().uuidString
        return try Self(record: copy, zone: record.recordID.zoneID)
    }

    func batchRecord() -> CKRecord {
        let copy = record.copy() as! CKRecord
        copy["transaction"] = UUID().uuidString
        return copy
    }

    func requireReady(generation expected: String) throws {
        guard phase == .ready else { throw CloudRecoveryError.replacementInProgress }
        guard generation == expected else { throw CloudRecoveryError.generationChanged }
    }

    static func validateBusinessRecord(_ record: CKRecord, generation: String) throws {
        if let value = record[businessGenerationField] {
            guard value as? String == generation else { throw CloudRecoveryError.generationChanged }
        } else if generation != baselineGeneration {
            throw CloudRecoveryError.generationChanged
        }
    }

    struct SendOutcome: Sendable {
        let control: CloudSyncControl
        let business: SyncEngineSentChanges
        let retryIDs: Set<CKRecord.ID>
    }

    /// Distinguish a same-generation optimistic conflict from a replacement.
    /// Only the former permits requeuing the existing business intentions.
    func outcome(of sent: SyncEngineSentChanges) throws -> SendOutcome {
        let id = record.recordID
        let savedControl = sent.savedRecords.first { $0.recordID == id }
        let failedControl = sent.failedSaves.first { $0.record.recordID == id }
        let businessSaves = sent.failedSaves.filter { $0.record.recordID != id }
        let hasSuccess = sent.savedRecords.contains { $0.recordID != id } || !sent.deletedRecordIDs.isEmpty
        // A business success without its atomic guard cannot acknowledge local
        // intent. Treat an incomplete adapter envelope as a failed session.
        guard !hasSuccess || (savedControl != nil && failedControl == nil) else {
            throw CloudRecoveryError.incompleteBatch
        }
        var next = self
        if let saved = savedControl {
            next = try Self(record: saved, zone: id.zoneID)
            try next.requireReady(generation: generation)
        }
        if sent.deletedRecordIDs.contains(id) || sent.failedDeletes[id] != nil {
            throw CloudRecoveryError.generationChanged
        }
        if let failure = failedControl {
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                    throw CloudRecoveryError.invalidControl
                }
                next = try Self(record: server, zone: id.zoneID)
                try next.requireReady(generation: generation)
            case .batchRequestFailed:
                // A business conflict rejects the guard along with its peers.
                // Resolve the root error below; retain the observed guard.
                guard !businessSaves.isEmpty || !sent.failedDeletes.isEmpty else { throw failure.error }
            default: throw failure.error
            }
        }
        let conflicted = sent.failedSaves.contains { $0.error.code == .serverRecordChanged }
        let retrySaves = sent.failedSaves.filter {
            $0.record.recordID != id && conflicted && $0.error.code == .batchRequestFailed
        }
        let retryDeletes = sent.failedDeletes.filter { conflicted && $0.value.code == .batchRequestFailed }
        return SendOutcome(
            control: next,
            business: SyncEngineSentChanges(
                savedRecords: sent.savedRecords.filter { $0.recordID != id },
                deletedRecordIDs: sent.deletedRecordIDs,
                failedSaves: sent.failedSaves.filter {
                    $0.record.recordID != id && !(conflicted && $0.error.code == .batchRequestFailed)
                },
                failedDeletes: sent.failedDeletes.filter { !(conflicted && $0.value.code == .batchRequestFailed) }),
            retryIDs: Set(retrySaves.map { $0.record.recordID }).union(retryDeletes.keys))
    }
}
