import CloudKit
import Foundation

struct CloudSyncSnapshot: Sendable {
    var vehicles: [CKRecord] = []
    var fuelingRecords: [CKRecord] = []
    var control: CKRecord?
    var otherRecords: [CKRecord] = []
    var businessRecords: [CKRecord] { vehicles + fuelingRecords + otherRecords }
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
    var scopeIdentifier: String { get }
    var recordZoneID: CKRecordZone.ID { get }
    func accountStatus() async throws -> CKAccountStatus
    func accountID() async throws -> String
    func ensureZone() async throws
    func snapshot() async throws -> CloudSyncSnapshot
    func controlRecord() async throws -> CKRecord?
    func makeDriver(state: Data?, receiver: any SyncEngineReceiver, automaticallySync: Bool) throws
        -> any SyncEngineDriver
}

extension CloudSyncEnvironment {
    func makeDriver(state: Data?, receiver: any SyncEngineReceiver) throws -> any SyncEngineDriver {
        try makeDriver(state: state, receiver: receiver, automaticallySync: true)
    }
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
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "FuelioZone", ownerName: CKCurrentUserDefaultName)
    private let suppliedContainer: CKContainer?
    let recordZoneID: CKRecordZone.ID
    private lazy var container = suppliedContainer ?? CKContainer.default()

    init(container: CKContainer? = nil, zoneID: CKRecordZone.ID = NativeCloudSyncEnvironment.zoneID) {
        suppliedContainer = container
        recordZoneID = zoneID
    }
    private var database: CKDatabase { container.privateCloudDatabase }
    var scopeIdentifier: String { "\(container.containerIdentifier ?? "")/\(recordZoneID.zoneName)/private" }

    func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }
    func accountID() async throws -> String { try await container.userRecordID().recordName }

    func ensureZone() async throws {
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: recordZoneID)], deleting: [])
        guard let result = results.saveResults[recordZoneID] else { throw CloudSyncAdapterError.missingZoneResult }
        _ = try result.get()
    }

    func controlRecord() async throws -> CKRecord? {
        do { return try await database.record(for: CloudSyncControl.recordID(in: recordZoneID)) } catch let error
            as CKError where error.code == .unknownItem || error.code == .zoneNotFound
        { return nil }
    }

    func snapshot() async throws -> CloudSyncSnapshot {
        var vehicles: [CKRecord.ID: CKRecord] = [:]
        var records: [CKRecord.ID: CKRecord] = [:]
        var other: [CKRecord.ID: CKRecord] = [:]
        var control: CKRecord?
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            let page = try await database.recordZoneChanges(inZoneWith: recordZoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                switch record.recordType {
                case CloudRecordType.vehicle: vehicles[id] = record
                case CloudRecordType.fuelingRecord: records[id] = record
                case CloudSyncControl.recordType:
                    _ = try CloudSyncControl(record: record, zone: recordZoneID)
                    control = record
                default: other[id] = record
                }
            }
            for deletion in page.deletions {
                vehicles.removeValue(forKey: deletion.recordID)
                records.removeValue(forKey: deletion.recordID)
                other.removeValue(forKey: deletion.recordID)
                if deletion.recordID == control?.recordID { control = nil }
            }
            token = page.changeToken
            moreComing = page.moreComing
        }
        return CloudSyncSnapshot(
            vehicles: Array(vehicles.values), fuelingRecords: Array(records.values),
            control: control, otherRecords: Array(other.values))
    }

    func makeDriver(state: Data?, receiver: any SyncEngineReceiver, automaticallySync: Bool) throws
        -> any SyncEngineDriver
    {
        let serialization = try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        return NativeSyncEngineDriver(
            database: database, zoneID: recordZoneID, serialization: serialization, receiver: receiver,
            automaticallySync: automaticallySync)
    }
}

/// A thin SDK translation layer. All application effects live in the receiver.
@MainActor
final class NativeSyncEngineDriver: SyncEngineDriver, CKSyncEngineDelegate {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let serialization: CKSyncEngine.State.Serialization?
    private weak var receiver: (any SyncEngineReceiver)?
    private let automaticallySync: Bool
    private lazy var engine: CKSyncEngine = {
        var configuration = CKSyncEngine.Configuration(
            database: database, stateSerialization: serialization, delegate: self)
        configuration.subscriptionID = "FuelioZoneChanges"
        configuration.automaticallySync = automaticallySync
        return CKSyncEngine(configuration)
    }()

    init(
        database: CKDatabase, zoneID: CKRecordZone.ID, serialization: CKSyncEngine.State.Serialization?,
        receiver: any SyncEngineReceiver, automaticallySync: Bool = true
    ) {
        self.database = database
        self.zoneID = zoneID
        self.serialization = serialization
        self.receiver = receiver
        self.automaticallySync = automaticallySync
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
