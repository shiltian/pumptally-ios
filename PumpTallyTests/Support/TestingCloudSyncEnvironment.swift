import CloudKit
import os

/// Compiled into the isolated Testing app only. It supplies SDK boundary values
/// while the application runs its real startup, persistence and event handling.
@MainActor
final class TestingCloudSyncEnvironment: CloudSyncEnvironment {
    var recordZoneID = NativeCloudSyncEnvironment.zoneID
    var scopeIdentifier = "isolated-test-container/FuelioZone/private"
    var records = CloudSyncSnapshot()
    var status = CKAccountStatus.available
    private struct Observation: Sendable {
        var userID = "isolated-test-account"
        var driverCreations = 0
    }
    private nonisolated let observation = OSAllocatedUnfairLock(initialState: Observation())
    nonisolated var userID: String {
        get { observation.withLock { $0.userID } }
        set { observation.withLock { $0.userID = newValue } }
    }
    nonisolated var driverCreationCount: Int { observation.withLock { $0.driverCreations } }
    var accountError: Error?
    var snapshotError: Error?
    var zoneError: Error?
    var driverError: Error?
    var snapshotHandler: (() async throws -> CloudSyncSnapshot)?
    var zoneHandler: (() async throws -> Void)?
    var automaticDelivery = true
    private(set) var snapshotReads = 0
    private(set) var accountReads = 0
    private(set) var zonePreparations = 0
    private(set) var restoredStates: [Data?] = []
    private(set) var drivers: [TestingSyncEngineDriver] = []

    func accountStatus() async throws -> CKAccountStatus {
        if let accountError { throw accountError }
        return status
    }

    func accountID() async throws -> String {
        accountReads += 1
        if let accountError { throw accountError }
        return userID
    }

    func ensureZone() async throws {
        zonePreparations += 1
        if let zoneError { throw zoneError }
        try await zoneHandler?()
    }

    func snapshot() async throws -> CloudSyncSnapshot {
        snapshotReads += 1
        if let snapshotError { throw snapshotError }
        if let snapshotHandler { return try await snapshotHandler() }
        return records
    }

    func controlRecord() async throws -> CKRecord? { records.control }

    func makeDriver(state: Data?, receiver: any SyncEngineReceiver, automaticallySync: Bool) throws
        -> any SyncEngineDriver
    {
        if let driverError { throw driverError }
        restoredStates.append(state)
        let driver = TestingSyncEngineDriver(receiver: receiver)
        driver.automaticDelivery = automaticDelivery
        driver.snapshot = records
        driver.commitBatch = { [weak self, weak driver] batch in
            guard let self else { throw CancellationError() }
            let result = try await self.apply(batch)
            driver?.snapshot = self.records
            return result
        }
        drivers.append(driver)
        observation.withLock { $0.driverCreations += 1 }
        return driver
    }

    var batchHandler: ((CKSyncEngine.RecordZoneChangeBatch) async throws -> Void)?
    var afterBatch: ((CKSyncEngine.RecordZoneChangeBatch) async throws -> Void)?
    private func apply(_ batch: CKSyncEngine.RecordZoneChangeBatch) async throws -> SyncEngineSentChanges {
        try await batchHandler?(batch)
        let guardID = CloudSyncControl.recordID(in: NativeCloudSyncEnvironment.zoneID)
        if let guardRecord = batch.recordsToSave.first(where: { $0.recordID == guardID }),
            let current = records.control,
            guardRecord["testServerTag"] as? String != current["testServerTag"] as? String
        {
            let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: current])
            return SyncEngineSentChanges(
                failedSaves: batch.recordsToSave.map {
                    ($0, $0.recordID == guardID ? conflict : CKError(.batchRequestFailed))
                },
                failedDeletes: Dictionary(
                    uniqueKeysWithValues: batch.recordIDsToDelete.map { ($0, CKError(.batchRequestFailed)) }))
        }
        var business = Dictionary(uniqueKeysWithValues: records.businessRecords.map { ($0.recordID, $0) })
        var saved: [CKRecord] = []
        for record in batch.recordsToSave {
            let copy = record.copy() as! CKRecord
            if copy.recordID == guardID {
                copy["testServerTag"] = UUID().uuidString
                records.control = copy
            } else {
                business[copy.recordID] = copy
            }
            saved.append(copy)
        }
        for id in batch.recordIDsToDelete { business.removeValue(forKey: id) }
        records.vehicles = business.values.filter { $0.recordType == CloudRecordCodec.RecordType.vehicle }
        records.fuelingRecords = business.values.filter { $0.recordType == CloudRecordCodec.RecordType.fuelingRecord }
        records.otherRecords = business.values.filter {
            $0.recordType != CloudRecordCodec.RecordType.vehicle
                && $0.recordType != CloudRecordCodec.RecordType.fuelingRecord
        }
        try await afterBatch?(batch)
        return SyncEngineSentChanges(savedRecords: saved, deletedRecordIDs: batch.recordIDsToDelete)
    }
}

@MainActor
final class TestingSyncEngineDriver: SyncEngineDriver {
    private weak var receiver: (any SyncEngineReceiver)?
    private(set) var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private(set) var cancellations = 0
    private(set) var starts = 0
    private(set) var recordRegistrations: [[CKSyncEngine.PendingRecordZoneChange]] = []
    var automaticDelivery = true
    var snapshot = CloudSyncSnapshot()
    var fetchError: Error?
    var sendError: Error?
    var registrationObserver: (() -> Void)?
    var commitBatch: ((CKSyncEngine.RecordZoneChangeBatch) async throws -> SyncEngineSentChanges)?

    init(receiver: any SyncEngineReceiver) { self.receiver = receiver }

    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        recordRegistrations.append(pendingRecordZoneChanges)
        registrationObserver?()
        for change in pendingRecordZoneChanges where !self.pendingRecordZoneChanges.contains(change) {
            self.pendingRecordZoneChanges.append(change)
        }
    }

    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        self.pendingRecordZoneChanges.removeAll { pendingRecordZoneChanges.contains($0) }
    }

    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {
        self.pendingDatabaseChanges.append(contentsOf: pendingDatabaseChanges)
    }

    func finishDatabaseChanges() { pendingDatabaseChanges.removeAll() }

    func start() { starts += 1 }
    func cancelOperations() async { cancellations += 1 }
    func emit(_ event: SyncEngineEvent) async { await receiver?.receive(event, from: self) }

    func batch(scope: CKSyncEngine.SendChangesOptions.Scope = .all) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await receiver?.nextBatch(scope: scope, from: self)
    }

    func fetchChanges() async throws {
        if let fetchError { throw fetchError }
        guard automaticDelivery else { return }
        await emit(.willFetch)
        await emit(
            .fetchedRecords(
                modifications: snapshot.businessRecords + (snapshot.control.map { [$0] } ?? []), deletions: []))
        await emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: nil))
        await emit(.didFetch)
    }

    func sendChanges() async throws {
        if let sendError { throw sendError }
        guard automaticDelivery else { return }
        await emit(.willSend)
        while let batch = await batch() {
            let result =
                try await commitBatch?(batch)
                ?? SyncEngineSentChanges(
                    savedRecords: batch.recordsToSave,
                    deletedRecordIDs: batch.recordIDsToDelete)
            remove(
                pendingRecordZoneChanges: result.savedRecords.map { .saveRecord($0.recordID) }
                    + result.deletedRecordIDs.map { .deleteRecord($0) })
            await emit(.sentRecords(result))
        }
        pendingDatabaseChanges.removeAll()
        await emit(.didSend)
    }
}
