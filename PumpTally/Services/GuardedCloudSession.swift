import CloudKit

/// One explicit guarded publication through the same native SDK adapter as
/// ordinary sync. Its source is immutable; restart recomputes work from server
/// state. Failed guards are never refreshed here to retry obsolete deletions.
@MainActor
final class GuardedCloudSession: SyncEngineReceiver {
    private let environment: any CloudSyncEnvironment
    private let accountID: String
    private var control: CloudSyncControl
    private let records: [CKRecord.ID: CKRecord]
    private var remaining: [CKSyncEngine.PendingRecordZoneChange]
    private var controlAcknowledged = false
    private var failure: Error?
    private var closed = false

    init(
        environment: any CloudSyncEnvironment, accountID: String, control: CloudSyncControl,
        saving: [CKRecord] = [], deleting: [CKRecord.ID] = []
    ) throws {
        self.environment = environment
        self.accountID = accountID
        self.control = control
        guard Set(saving.map(\.recordID)).count == saving.count else { throw CloudRecoveryError.invalidReceipt }
        records = Dictionary(uniqueKeysWithValues: saving.map { ($0.recordID, $0) })
        remaining = saving.map { .saveRecord($0.recordID) } + deleting.map { .deleteRecord($0) }
    }

    func send() async throws -> CloudSyncControl {
        let driver = try environment.makeDriver(state: nil, receiver: self, automaticallySync: false)
        driver.add(pendingRecordZoneChanges: [.saveRecord(control.record.recordID)] + remaining)
        driver.start()
        do {
            try await driver.sendChanges()
            if let failure { throw failure }
            guard controlAcknowledged, remaining.isEmpty else { throw CloudRecoveryError.incompleteBatch }
            closed = true
            await driver.cancelOperations()
            return control
        } catch {
            closed = true
            await driver.cancelOperations()
            throw error
        }
    }

    func nextBatch(scope: CKSyncEngine.SendChangesOptions.Scope, from driver: any SyncEngineDriver) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        guard !closed, failure == nil, !controlAcknowledged || !remaining.isEmpty else { return nil }
        do {
            guard try await environment.accountID() == accountID else { throw SyncPersistenceError.accountChanged }
            try Task.checkCancellation()
            guard !closed, failure == nil else { return nil }
            let guardRecord = control.batchRecord()
            let records = records
            guard
                var batch = await CKSyncEngine.RecordZoneChangeBatch(
                    pendingChanges: [.saveRecord(guardRecord.recordID)] + remaining,
                    recordProvider: { id in id == guardRecord.recordID ? guardRecord : records[id] })
            else { throw CloudRecoveryError.incompleteBatch }
            guard batch.recordsToSave.contains(where: { $0.recordID == guardRecord.recordID }) else {
                throw CloudRecoveryError.incompleteBatch
            }
            batch.atomicByZone = true
            return batch
        } catch {
            failure = error
            return nil
        }
    }

    func receive(_ event: SyncEngineEvent, from driver: any SyncEngineDriver) async {
        guard !closed else { return }
        do {
            switch event {
            case .sentRecords(let result):
                if let error = result.failedSaves.first?.error ?? result.failedDeletes.values.first { throw error }
                guard let saved = result.savedRecords.first(where: { $0.recordID == control.record.recordID }) else {
                    throw CloudRecoveryError.incompleteBatch
                }
                let next = try CloudSyncControl(record: saved, zone: control.record.recordID.zoneID)
                guard next.generation == control.generation, next.phase == control.phase else {
                    throw CloudRecoveryError.generationChanged
                }
                control = next
                controlAcknowledged = true
                let acknowledged = Set(result.savedRecords.map(\.recordID) + result.deletedRecordIDs)
                remaining.removeAll { change in
                    switch change {
                    case .saveRecord(let id), .deleteRecord(let id): return acknowledged.contains(id)
                    @unknown default: return false
                    }
                }
            case .accountChanged(let change):
                guard case .signIn(let user) = change, user.recordName == accountID else {
                    throw SyncPersistenceError.accountChanged
                }
            case .deletedZones(let ids):
                if ids.contains(control.record.recordID.zoneID) { throw CloudRecoveryError.generationChanged }
            case .adapterFailure(let error): throw error
            default: break
            }
        } catch { failure = error }
    }
}
