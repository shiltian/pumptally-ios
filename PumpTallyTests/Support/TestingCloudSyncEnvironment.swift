import CloudKit

/// Compiled into the isolated Testing app only. It supplies SDK boundary values
/// while the application runs its real startup, persistence and event handling.
@MainActor
final class TestingCloudSyncEnvironment: CloudSyncEnvironment {
    var records = CloudSyncSnapshot()
    var status = CKAccountStatus.available
    var userID = "isolated-test-account"
    var accountError: Error?
    var snapshotError: Error?
    var zoneError: Error?
    var driverError: Error?
    var snapshotHandler: (() async throws -> CloudSyncSnapshot)?
    var zoneHandler: (() async throws -> Void)?
    var replacementHandler: (() async throws -> Void)?
    var automaticDelivery = true
    private(set) var snapshotReads = 0
    private(set) var accountReads = 0
    private(set) var zonePreparations = 0
    private(set) var zoneReplacements = 0
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

    func recreateZone() async throws {
        zoneReplacements += 1
        if let zoneError { throw zoneError }
        records = CloudSyncSnapshot()
        try await replacementHandler?()
    }

    func makeDriver(state: Data?, receiver: any SyncEngineReceiver) throws -> any SyncEngineDriver {
        if let driverError { throw driverError }
        restoredStates.append(state)
        let driver = TestingSyncEngineDriver(receiver: receiver)
        driver.automaticDelivery = automaticDelivery
        driver.snapshot = records
        drivers.append(driver)
        return driver
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
        await emit(.fetchedRecords(modifications: snapshot.vehicles + snapshot.fuelingRecords, deletions: []))
        await emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: nil))
        await emit(.didFetch)
    }

    func sendChanges() async throws {
        if let sendError { throw sendError }
        guard automaticDelivery else { return }
        await emit(.willSend)
        if let batch = await batch() {
            let changes =
                batch.recordsToSave.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
                + batch.recordIDsToDelete.map { .deleteRecord($0) }
            remove(pendingRecordZoneChanges: changes)
            await emit(
                .sentRecords(
                    SyncEngineSentChanges(
                        savedRecords: batch.recordsToSave,
                        deletedRecordIDs: batch.recordIDsToDelete)))
        }
        pendingDatabaseChanges.removeAll()
        await emit(.didSend)
    }
}
