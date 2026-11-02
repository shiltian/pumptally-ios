import CloudKit
import Foundation

struct CloudSyncSnapshot: Sendable {
    var vehicles: [CKRecord] = []
    var fuelingRecords: [CKRecord] = []
}

struct SyncEngineSentChanges: Sendable {
    var savedRecords: [CKRecord] = []
    var deletedRecordIDs: [CKRecord.ID] = []
    var failedSaves: [(record: CKRecord, error: CKError)] = []
    var failedDeletes: [CKRecord.ID: CKError] = [:]
}

/// Values at the SDK boundary. Persistence and session behavior are shared by
/// the native adapter and deterministic drivers; neither implements retries.
enum SyncEngineEvent {
    case checkpoint(Data)
    case willFetch, didFetch, willSend, didSend
    case fetchedRecords(modifications: [CKRecord], deletions: [(recordID: CKRecord.ID, recordType: String)])
    case fetchedZone(CKRecordZone.ID, error: CKError?)
    case sentRecords(SyncEngineSentChanges)
    case deletedZones([CKRecordZone.ID])
    case sentZones(errors: [CKError])
    case accountChanged(CKSyncEngine.Event.AccountChange.ChangeType)
    case adapterFailure(Error)
}

@MainActor
protocol SyncEngineReceiver: AnyObject {
    func receive(_ event: SyncEngineEvent, from driver: any SyncEngineDriver) async
    func nextBatch(scope: CKSyncEngine.SendChangesOptions.Scope, from driver: any SyncEngineDriver) async
        -> CKSyncEngine.RecordZoneChangeBatch?
}

@MainActor
protocol SyncEngineDriver: AnyObject {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { get }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange])
    func start()
    func fetchChanges() async throws
    func sendChanges() async throws
    func cancelOperations() async
}

@MainActor
protocol CloudSyncEnvironment {
    func accountStatus() async throws -> CKAccountStatus
    func accountID() async throws -> String
    func ensureZone() async throws
    func snapshot() async throws -> CloudSyncSnapshot
    func recreateZone() async throws
    func makeDriver(state: Data?, receiver: any SyncEngineReceiver) throws -> any SyncEngineDriver
}

enum CloudSyncAdapterError: Error {
    case missingZoneResult
    case unsupportedRecordType(String)
    case unsupportedEvent
}

/// The only adapter that accesses CloudKit. Construction is lazy so ordinary
/// local use never opens a CloudKit container.
@MainActor
final class NativeCloudSyncEnvironment: CloudSyncEnvironment {
    static let zoneID = CKRecordZone.ID(zoneName: "FuelioZone", ownerName: CKCurrentUserDefaultName)
    private lazy var container = CKContainer.default()
    private var database: CKDatabase { container.privateCloudDatabase }

    func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }
    func accountID() async throws -> String { try await container.userRecordID().recordName }

    func ensureZone() async throws {
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        guard let result = results.saveResults[Self.zoneID] else { throw CloudSyncAdapterError.missingZoneResult }
        _ = try result.get()
    }

    func recreateZone() async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        guard let result = results.deleteResults[Self.zoneID] else { throw CloudSyncAdapterError.missingZoneResult }
        _ = try result.get()
        try await ensureZone()
    }

    func snapshot() async throws -> CloudSyncSnapshot {
        var vehicles: [CKRecord.ID: CKRecord] = [:]
        var records: [CKRecord.ID: CKRecord] = [:]
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                switch record.recordType {
                case CloudRecordCodec.RecordType.vehicle: vehicles[id] = record
                case CloudRecordCodec.RecordType.fuelingRecord: records[id] = record
                default: throw CloudSyncAdapterError.unsupportedRecordType(record.recordType)
                }
            }
            for deletion in page.deletions {
                vehicles.removeValue(forKey: deletion.recordID)
                records.removeValue(forKey: deletion.recordID)
            }
            token = page.changeToken
            moreComing = page.moreComing
        }
        return CloudSyncSnapshot(vehicles: Array(vehicles.values), fuelingRecords: Array(records.values))
    }

    func makeDriver(state: Data?, receiver: any SyncEngineReceiver) throws -> any SyncEngineDriver {
        let serialization = try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        return NativeSyncEngineDriver(
            database: database, zoneID: Self.zoneID, serialization: serialization, receiver: receiver)
    }
}

/// A thin SDK translation layer. All application effects live in the receiver.
@MainActor
final class NativeSyncEngineDriver: SyncEngineDriver, CKSyncEngineDelegate {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let serialization: CKSyncEngine.State.Serialization?
    private weak var receiver: (any SyncEngineReceiver)?
    private lazy var engine: CKSyncEngine = {
        var configuration = CKSyncEngine.Configuration(
            database: database, stateSerialization: serialization, delegate: self)
        configuration.subscriptionID = "FuelioZoneChanges"
        return CKSyncEngine(configuration)
    }()

    init(
        database: CKDatabase, zoneID: CKRecordZone.ID, serialization: CKSyncEngine.State.Serialization?,
        receiver: any SyncEngineReceiver
    ) {
        self.database = database
        self.zoneID = zoneID
        self.serialization = serialization
        self.receiver = receiver
    }

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { engine.state.pendingRecordZoneChanges }
    var pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] { engine.state.pendingDatabaseChanges }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.add(pendingRecordZoneChanges: pendingRecordZoneChanges)
    }
    func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]) {
        engine.state.remove(pendingRecordZoneChanges: pendingRecordZoneChanges)
    }
    func add(pendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange]) {
        engine.state.add(pendingDatabaseChanges: pendingDatabaseChanges)
    }
    func start() { _ = engine }
    func fetchChanges() async throws { try await engine.fetchChanges() }
    func sendChanges() async throws { try await engine.sendChanges() }
    func cancelOperations() async { await engine.cancelOperations() }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.FetchChangesOptions
    {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        await receiver?.nextBatch(scope: context.options.scope, from: self)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let translated: SyncEngineEvent
        switch event {
        case .stateUpdate(let update):
            do { translated = .checkpoint(try JSONEncoder().encode(update.stateSerialization)) } catch {
                translated = .adapterFailure(error)
            }
        case .willFetchChanges: translated = .willFetch
        case .didFetchChanges: translated = .didFetch
        case .willSendChanges: translated = .willSend
        case .didSendChanges: translated = .didSend
        case .fetchedRecordZoneChanges(let changes):
            translated = .fetchedRecords(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
        case .didFetchRecordZoneChanges(let result): translated = .fetchedZone(result.zoneID, error: result.error)
        case .sentRecordZoneChanges(let changes):
            translated = .sentRecords(
                SyncEngineSentChanges(
                    savedRecords: changes.savedRecords,
                    deletedRecordIDs: changes.deletedRecordIDs,
                    failedSaves: changes.failedRecordSaves.map { ($0.record, $0.error) },
                    failedDeletes: changes.failedRecordDeletes))
        case .fetchedDatabaseChanges(let changes): translated = .deletedZones(changes.deletions.map(\.zoneID))
        case .sentDatabaseChanges(let changes):
            translated = .sentZones(
                errors: changes.failedZoneSaves.map(\.error) + Array(changes.failedZoneDeletes.values))
        case .accountChange(let change): translated = .accountChanged(change.changeType)
        case .willFetchRecordZoneChanges: return
        @unknown default: translated = .adapterFailure(CloudSyncAdapterError.unsupportedEvent)
        }
        await receiver?.receive(translated, from: self)
    }
}
