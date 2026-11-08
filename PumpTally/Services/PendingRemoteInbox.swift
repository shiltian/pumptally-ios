import CloudKit
import SwiftData

/// A decoded view of one context's inbox, never retained across transactions.
/// Bad entries remain available to diagnosis; application fails before writes.
struct PendingRemoteInbox {
    struct Metrics: Sendable {
        var loads = 0
        var payloadsDecoded = 0
        var recordsUnarchived = 0
    }

    enum Change {
        case modification(CKRecord)
        case deletion(recordName: String, recordType: String)
    }

    struct Entry {
        let key: String
        let archivedPayload: Data
        let decoded: Result<Change, Error>
    }

    let entries: [Entry]
    let metrics: Metrics
    private let childrenByOwner: [String: [Int]]
    private let blockedOwners: Set<String>

    init(in context: ModelContext) throws {
        var entries: [Entry] = []
        var children: [String: [Int]] = [:]
        var blocked: Set<String> = []
        var metrics = Metrics(loads: 1)
        try context.enumerate(
            FetchDescriptor<PendingRemoteChange>(sortBy: [SortDescriptor(\.key)]), batchSize: 256
        ) { pending in
            try Task.checkCancellation()
            metrics.payloadsDecoded += 1
            let decoded = Result<Change, Error> {
                // Legacy rows contain a bare keyed archive. Decode it once;
                // modern rows have the existing JSON envelope around it.
                let payload = try? JSONDecoder().decode(
                    SyncPersistenceStore.PendingPayload.self, from: pending.recordData)
                if let payload, payload.kind == .deletion {
                    return .deletion(recordName: payload.recordName, recordType: payload.recordType)
                }
                let archive = payload?.archivedRecord ?? pending.recordData
                metrics.recordsUnarchived += 1
                guard let record = try CloudRecordCodec.unarchiveFullRecord(from: archive) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if let payload {
                    guard record.recordID.recordName == payload.recordName, record.recordType == payload.recordType
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                return .modification(record)
            }
            if case .success(.modification(let record)) = decoded {
                if record.recordType == CloudRecordCodec.RecordType.vehicle {
                    blocked.insert(record.recordID.recordName)
                } else if let owner = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String {
                    blocked.insert(owner)
                    if record.recordType == CloudRecordCodec.RecordType.fuelingRecord {
                        children[owner, default: []].append(entries.count)
                    }
                }
            }
            entries.append(Entry(key: pending.key, archivedPayload: pending.recordData, decoded: decoded))
        }
        self.entries = entries
        self.metrics = metrics
        childrenByOwner = children
        blockedOwners = blocked
    }

    func requireReadable() throws {
        for entry in entries { _ = try entry.decoded.get() }
    }

    func blockedVehicleNames() throws -> Set<String> {
        try requireReadable()
        return blockedOwners
    }

    func children(of owner: String) -> [Entry] {
        (childrenByOwner[owner] ?? []).map { entries[$0] }
    }
}
