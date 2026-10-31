import Foundation
import CloudKit
import SwiftData
import Combine
import os

/// Core CloudKit sync engine that mirrors local SwiftData to a private CloudKit database.
/// The local store is always the source of truth; CloudKit acts as a mirror.
@MainActor
final class CloudSyncService: ObservableObject, CKSyncEngineDelegate {

    // MARK: - Properties

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "CloudSync"
    )

    let stateManager: SyncStateManager

    /// CloudKit container — created lazily so the app never touches CloudKit
    /// until the user actually tries to enable iCloud sync.
    /// Uses the default container configured in the app's entitlements.
    private lazy var container: CKContainer = {
        CKContainer.default()
    }()

    private lazy var privateDatabase: CKDatabase = {
        container.privateCloudDatabase
    }()

    private lazy var zoneID: CKRecordZone.ID = {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }()

    private var saveObserver: AnyCancellable?
    private var stateForwardingObserver: AnyCancellable?
    private var modelContainer: ModelContainer?
    private var syncEngine: CKSyncEngine?
    private let operationCoordinator = SyncOperationCoordinator()
    private var inFlightGenerations: [String: String] = [:]

    private struct PendingRemoteChangePayload: Codable {
        enum Kind: String, Codable {
            case modification
            case deletion
        }

        let kind: Kind
        let recordName: String
        let recordType: String
        let archivedRecord: Data?
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
        let model: PendingRemoteChange
        let change: DecodedRemoteChange
    }

    /// Suppresses automatic local-save pushes while a vetted bulk write is in progress.
    private var localPushSuspensionCount = 0

    // MARK: - Constants

    private typealias RecordType = CloudRecordCodec.RecordType

    /// Compatibility namespaces retained for the existing test and call seams.
    typealias CloudFieldKey = CloudRecordCodec.CloudFieldKey
    typealias ConflictWinner = SyncConflictResolver.Winner
    typealias CloudReplacementError = CloudSnapshotValidator.ValidationError
    typealias RemoteApplyResult = CloudReconciliationService.RemoteApplyResult

    private static let zoneName = "FuelioZone"
    private static let subscriptionID = "FuelioZoneChanges"

    private static let batchSize = 200
    private static let maxRetries = 3
    private static let retryBaseDelay: UInt64 = 2_000_000_000
    private static let interBatchDelay: UInt64 = 500_000_000
    /// Debounce interval for local save observations (seconds).
    private static let saveDebounceInterval: TimeInterval = 1

    private var recordCodec: CloudRecordCodec {
        CloudRecordCodec(zoneID: zoneID)
    }

    private var reconciliationService: CloudReconciliationService {
        CloudReconciliationService(codec: recordCodec)
    }

    // MARK: - Initialization

    init(stateManager: SyncStateManager = SyncStateManager()) {
        self.stateManager = stateManager

        // Forward stateManager's change notifications so that views observing
        // CloudSyncService (via @EnvironmentObject) also re-render when
        // syncStatus, iCloudSyncEnabled, etc. change.
        stateForwardingObserver = stateManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - iCloud Availability

    /// Check if the user is signed in to iCloud
    func checkiCloudAvailability() async -> Bool {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                return true
            default:
                await MainActor.run {
                    stateManager.syncStatus = .unavailable
                }
                return false
            }
        } catch {
            await MainActor.run {
                stateManager.syncStatus = .error(String(localized: "Failed to check iCloud status"))
            }
            return false
        }
    }

    // MARK: - Zone Management

    /// Ensure the custom record zone exists
    private func ensureZoneExists() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let _ = try await privateDatabase.modifyRecordZones(saving: [zone], deleting: [])
    }

    // MARK: - Initial Sync Check

    /// Check if the cloud has any data in FuelioZone.
    /// Uses recordZoneChanges (change token based) instead of CKQuery to avoid
    /// issues with non-existent record types and non-queryable fields on first use.
    func checkCloudHasData() async throws -> Bool {
        try await operationCoordinator.runExclusive {
            do {
                return try await performCheckCloudHasData()
            } catch {
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                throw error
            }
        }
    }

    private func performCheckCloudHasData() async throws -> Bool {
        try await ensureZoneExists()

        // Read the complete zone instead of treating an empty first page as an
        // empty cloud. Errors intentionally propagate: callers must distinguish
        // "empty" from "unknown because CloudKit failed" before choosing the
        // destructive initial-sync strategy.
        let (vehicles, fuelingRecords) = try await fetchAllCloudRecords()
        return !vehicles.isEmpty || !fuelingRecords.isEmpty
    }

    // MARK: - Upload All Local Data

    /// Upload all local vehicles and fueling records to CloudKit
    func uploadAllLocalData(from context: ModelContext) async throws {
        try await operationCoordinator.runExclusive {
            do {
                try await performUploadAllLocalData(from: context)
            } catch {
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                throw error
            }
        }
    }

    private func performUploadAllLocalData(from context: ModelContext) async throws {
        stateManager.syncStatus = .syncing

        try await ensureZoneExists()

        // Fetch all local vehicles
        let vehicleDescriptor = FetchDescriptor<Vehicle>()
        let vehicles = try context.fetch(vehicleDescriptor)

        var recordsToSave: [CKRecord] = []

        for vehicle in vehicles {
            let vehicleRecord = vehicleToCKRecord(vehicle)
            recordsToSave.append(vehicleRecord)

            // Add fueling records for this vehicle
            for fuelingRecord in vehicle.fuelingRecords ?? [] {
                let ckRecord = fuelingRecordToCKRecord(fuelingRecord, vehicleRecordID: vehicleRecord.recordID)
                recordsToSave.append(ckRecord)
            }
        }

        // Batch save in chunks (CloudKit has a 400 record limit per operation)
        try await batchSave(records: recordsToSave)

        stateManager.syncStatus = .synced
    }

    // MARK: - Download All Cloud Data

    /// Download all cloud data and replace local data.
    ///
    /// The complete cloud snapshot is decoded and validated before touching the
    /// local context. The replacement is then persisted by one `save()`, which
    /// SwiftData commits as one store transaction. If that save fails, rollback
    /// restores the context to its last successfully saved local state.
    func downloadAllCloudData(to context: ModelContext) async throws {
        try await operationCoordinator.runExclusive {
            do {
                try await performDownloadAllCloudData(to: context)
            } catch {
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                throw error
            }
        }
    }

    private func performDownloadAllCloudData(to context: ModelContext) async throws {
        stateManager.syncStatus = .syncing
        // Fetch cloud data before deleting local data. If iCloud fails here, the
        // local store remains untouched.
        let (vehicleCKRecords, fuelingCKRecords) = try await fetchAllCloudRecords()

        try replaceLocalData(
            vehicleCKRecords: vehicleCKRecords,
            fuelingCKRecords: fuelingCKRecords,
            context: context
        )

        // Rebuild all caches
        StatisticsCacheService.rebuildCacheForAllVehicles(in: context, force: true)

        stateManager.syncStatus = .synced
    }

    /// Network-free replacement seam used by `downloadAllCloudData` and tests.
    ///
    /// Validation happens before the first context mutation. Any pending local
    /// edits are saved first so rollback cannot discard unrelated user changes.
    func replaceLocalData(
        vehicleCKRecords: [CKRecord],
        fuelingCKRecords: [CKRecord],
        context: ModelContext
    ) throws {
        let validatedSnapshot = try CloudSnapshotValidator().validate(
            vehicleRecords: vehicleCKRecords,
            fuelingRecordRecords: fuelingCKRecords
        )
        let vehicleSnapshots = validatedSnapshot.vehicles
        let fuelingSnapshots = validatedSnapshot.fuelingRecords

        // Establish a clean rollback boundary before beginning the replacement.
        if context.hasChanges {
            try context.save()
        }

        do {
            for pending in try context.fetch(FetchDescriptor<SyncChange>()) {
                context.delete(pending)
            }
            for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) {
                context.delete(metadata)
            }
            for pendingRemote in try context.fetch(FetchDescriptor<PendingRemoteChange>()) {
                context.delete(pendingRemote)
            }

            let localVehicles = try context.fetch(FetchDescriptor<Vehicle>())
            for vehicle in localVehicles {
                context.delete(vehicle)
            }

            var vehiclesByID: [UUID: Vehicle] = [:]
            vehiclesByID.reserveCapacity(vehicleSnapshots.count)

            for snapshot in vehicleSnapshots {
                let vehicle = Vehicle(
                    id: snapshot.id,
                    name: snapshot.name,
                    make: snapshot.make,
                    model: snapshot.model,
                    year: snapshot.year,
                    createdAt: snapshot.createdAt,
                    unitSystem: snapshot.unitSystem
                )
                vehicle.modifiedAt = snapshot.modifiedAt
                context.insert(vehicle)
                vehiclesByID[snapshot.id] = vehicle
            }

            for snapshot in fuelingSnapshots {
                guard let vehicle = vehiclesByID[snapshot.vehicleID] else {
                    throw CloudReplacementError.missingVehicle(
                        recordID: snapshot.id,
                        vehicleID: snapshot.vehicleID
                    )
                }

                let record = FuelingRecord(
                    id: snapshot.id,
                    date: snapshot.date,
                    odometer: snapshot.odometer,
                    pricePerFuelUnit: snapshot.pricePerFuelUnit,
                    fuelAmount: snapshot.fuelAmount,
                    totalCost: snapshot.totalCost,
                    fillUpType: snapshot.fillUpType,
                    notes: snapshot.notes,
                    createdAt: snapshot.createdAt,
                    vehicle: vehicle
                )
                record.modifiedAt = snapshot.modifiedAt
                context.insert(record)
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Merge Cloud and Local

    /// Merge cloud and local data: match by UUID, keep newer for matches, insert unique from both sides
    func mergeCloudAndLocal(context: ModelContext) async throws {
        try await operationCoordinator.runExclusive {
            do {
                try await performMergeCloudAndLocal(context: context)
            } catch {
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                throw error
            }
        }
    }

    private func performMergeCloudAndLocal(context: ModelContext) async throws {
        stateManager.syncStatus = .syncing
        // Fetch all cloud records using change token (avoids queryable field requirements)
        let (vehicleCKRecords, fuelingCKRecords) = try await fetchAllCloudRecords()

        // Reconcile in memory: pull cloud-newer values down, insert cloud-only
        // records, and collect the records that must be pushed back up.
        let recordsToUpload = try reconcileMerge(
            vehicleCKRecords: vehicleCKRecords,
            fuelingCKRecords: fuelingCKRecords,
            context: context
        )

        // Batch upload
        if !recordsToUpload.isEmpty {
            try await batchSave(records: recordsToUpload)
        }

        try context.save()

        // Rebuild all caches
        StatisticsCacheService.rebuildCacheForAllVehicles(in: context, force: true)

        stateManager.syncStatus = .synced
    }

    /// Pure, network-free reconciliation used by ``mergeCloudAndLocal(context:)``.
    ///
    /// Mutates `context` in place (updates local from cloud where the cloud copy
    /// is newer, inserts cloud-only records) and returns the CKRecords that must
    /// be uploaded to the cloud. Records are uploaded when they are local-only
    /// **or** when they exist on both sides but the local copy is newer — the
    /// latter case is what previously left other devices stuck with stale data.
    ///
    /// Extracted so the conflict/upload logic can be unit-tested without CloudKit.
    func reconcileMerge(
        vehicleCKRecords: [CKRecord],
        fuelingCKRecords: [CKRecord],
        context: ModelContext
    ) throws -> [CKRecord] {
        try reconciliationService.reconcileMerge(
            vehicleCKRecords: vehicleCKRecords,
            fuelingCKRecords: fuelingCKRecords,
            context: context
        )
    }

    // MARK: - Delete All Cloud Data

    /// Atomically reserves the sync pipeline for the complete destructive
    /// delete-and-upload sequence so no automatic pull or push can observe the
    /// temporary empty cloud zone.
    func replaceCloudDataWithLocal(from context: ModelContext) async throws {
        let wasMonitoring = syncEngine != nil
        let containerToRestart = modelContainer ?? context.container
        let previousEngine = syncEngine
        syncEngine = nil
        await previousEngine?.cancelOperations()
        stateManager.syncEngineState = nil
        stateManager.syncEngineBootstrapComplete = false

        do {
            try await operationCoordinator.runExclusive {
                try await performDeleteAllCloudData()
                try await performUploadAllLocalData(from: context)
            }

            try clearCloudMetadata(in: context)
            if wasMonitoring && stateManager.iCloudSyncEnabled && stateManager.initialSyncCompleted {
                await startMonitoring(container: containerToRestart)
                await synchronizeNow()
            }
        } catch {
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
            if wasMonitoring && stateManager.iCloudSyncEnabled && stateManager.initialSyncCompleted {
                await startMonitoring(container: containerToRestart)
            }
            throw error
        }
    }

    private func performDeleteAllCloudData() async throws {
        stateManager.syncStatus = .syncing

        // Deleting the zone deletes all records in it
        let _ = try await privateDatabase.modifyRecordZones(saving: [], deleting: [zoneID])

        // Recreate the zone for future use
        try await ensureZoneExists()

        // Reset the change token
        stateManager.serverChangeToken = nil
    }

    // MARK: - Cloud Record Counts

    /// Fetch the number of vehicles and fueling records currently in CloudKit.
    func fetchCloudRecordCounts() async -> (vehicles: Int, fuelingRecords: Int) {
        await operationCoordinator.runExclusive {
            do {
                let (vehicles, fuelingRecords) = try await fetchAllCloudRecords()
                return (vehicles.count, fuelingRecords.count)
            } catch {
                Self.logger.error("Failed to fetch cloud record counts: \(error)")
                return (0, 0)
            }
        }
    }

    // MARK: - Fetch All Cloud Records Helper

    /// Fetch all records from the custom zone using recordZoneChanges (change-token based).
    /// This avoids CKQuery which requires fields to be marked queryable in the CloudKit dashboard.
    /// Returns separate arrays for Vehicle and FuelingRecord CKRecords.
    private func fetchAllCloudRecords() async throws -> (vehicles: [CKRecord], fuelingRecords: [CKRecord]) {
        // Use dictionaries to deduplicate by CKRecord.ID.
        // recordZoneChanges(since: nil) returns the full change history,
        // so the same record can appear multiple times if it was re-uploaded.
        // Keeping the latest version (last write wins).
        var vehicleRecords: [CKRecord.ID: CKRecord] = [:]
        var fuelingRecords: [CKRecord.ID: CKRecord] = [:]
        var changeToken: CKServerChangeToken? = nil
        var moreComing = true

        while moreComing {
            let results = try await privateDatabase.recordZoneChanges(
                inZoneWith: zoneID,
                since: changeToken
            )

            for (recordID, result) in results.modificationResultsByID {
                switch result {
                case .success(let modification):
                    let record = modification.record
                    switch record.recordType {
                    case RecordType.vehicle:
                        vehicleRecords[recordID] = record
                    case RecordType.fuelingRecord:
                        fuelingRecords[recordID] = record
                    default:
                        break
                    }
                case .failure(let error):
                    // A successful page can still contain failed individual
                    // records. Returning the rest would create a partial
                    // snapshot and could make replacement delete valid local
                    // data that merely failed to download.
                    Self.logger.error("Full-zone fetch failed for \(recordID.recordName): \(error.localizedDescription)")
                    throw error
                }
            }

            // Track deletions so we don't count deleted records
            for deletion in results.deletions {
                let recordID = deletion.recordID
                vehicleRecords.removeValue(forKey: recordID)
                fuelingRecords.removeValue(forKey: recordID)
            }

            changeToken = results.changeToken
            moreComing = results.moreComing
        }

        return (Array(vehicleRecords.values), Array(fuelingRecords.values))
    }

    // MARK: - Pull Outcome Compatibility Seam

    /// Legacy decision helper retained for tests. Runtime change tokens are now
    /// owned and persisted by CKSyncEngine.
    ///
    /// The token advances only when the entire change window was applied
    /// safely: no per-record fetch failure **and** no fueling record left
    /// unresolved because its parent vehicle was missing. In either of those
    /// cases the token is held so the same window is re-delivered on the next
    /// pull (re-application is idempotent) and the record is picked up once its
    /// parent arrives — advancing would move the token past a record that was
    /// never stored locally, skipping it forever, which this app's
    /// data-integrity guarantees forbid.
    ///
    /// - Returns: `true` if the token advanced, `false` if it was held.
    @discardableResult
    func commitPullOutcome(
        fetchedToken: CKServerChangeToken?,
        hadFetchFailure: Bool,
        unresolvedChildIDs: [UUID]
    ) -> Bool {
        guard !hadFetchFailure && unresolvedChildIDs.isEmpty else {
            stateManager.syncStatus = .error(String(localized: "Pull incomplete — will retry"))
            return false
        }
        stateManager.serverChangeToken = fetchedToken
        stateManager.syncStatus = .synced
        return true
    }

    /// Apply fetched remote changes to the local store.
    ///
    /// Vehicles are applied before fueling records: CloudKit does not guarantee
    /// ordering within a change set, so a fueling record and its brand-new parent
    /// vehicle may arrive in either order. Processing the record first used to
    /// drop it (its owner wasn't inserted yet) while the change token still
    /// advanced, losing the record permanently. A two-pass apply removes that
    /// dependency on arrival order.
    ///
    /// Existing local objects are overwritten only when the incoming cloud copy
    /// is strictly newer (last-writer-wins). When the local copy is newer it is
    /// kept *and* returned in ``RemoteApplyResult/recordsToUpload`` so the caller
    /// can push it back to the cloud, keeping devices convergent.
    ///
    /// A fueling record whose parent vehicle cannot be resolved is left
    /// un-applied and reported in ``RemoteApplyResult/unresolvedChildIDs`` rather
    /// than silently dropped.
    @discardableResult
    func applyRemoteChanges(changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], context: ModelContext) throws -> RemoteApplyResult {
        try reconciliationService.applyRemoteChanges(
            changedRecords: changedRecords,
            deletedRecordIDs: deletedRecordIDs,
            context: context
        )
    }

    // MARK: - Monitoring Local Changes

    /// Start CKSyncEngine and monitor durable journal changes.
    func startMonitoring(container: ModelContainer) async {
        self.modelContainer = container
        saveObserver?.cancel()

        do {
            try await ensureZoneExists()
            try await bootstrapSyncEngineIfNeeded(container: container)
            try applyPendingRemoteChanges(in: container.mainContext, syncEngine: nil)
        } catch {
            Self.logger.error("CloudKit sync bootstrap failed: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
            return
        }

        if syncEngine == nil {
            var configuration = CKSyncEngine.Configuration(
                database: privateDatabase,
                stateSerialization: stateManager.syncEngineState,
                delegate: self
            )
            configuration.subscriptionID = Self.subscriptionID
            syncEngine = CKSyncEngine(configuration)
        }

        saveObserver = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .map { [weak self] _ in (self?.localPushSuspensionCount ?? 0) > 0 }
            .debounce(for: .seconds(Self.saveDebounceInterval), scheduler: RunLoop.main)
            .sink { [weak self] wasSuppressedWhenSaved in
                guard Self.shouldScheduleAutomaticPush(
                    wasSuppressedWhenSaved: wasSuppressedWhenSaved,
                    isCurrentlySuppressed: (self?.localPushSuspensionCount ?? 0) > 0
                ) else { return }
                Task(priority: .utility) { @MainActor [weak self] in
                    await self?.enqueuePendingJournalChanges()
                }
            }

        await enqueuePendingJournalChanges()
    }

    /// On the first launch after the manual-sync migration, reconcile a complete
    /// cloud snapshot before CKSyncEngine starts. This recovers previously
    /// unsent local inserts/edits and preserves the existing conflict policy.
    private func bootstrapSyncEngineIfNeeded(container: ModelContainer) async throws {
        guard !stateManager.syncEngineBootstrapComplete else { return }

        let (vehicleRecords, fuelingRecords) = try await fetchAllCloudRecords()
        let context = container.mainContext
        let localWinners = try reconcileMerge(
            vehicleCKRecords: vehicleRecords,
            fuelingCKRecords: fuelingRecords,
            context: context
        )
        let existingChanges = try context.fetch(FetchDescriptor<SyncChange>())
        try applyLocalDeleteTombstones(
            existingChanges.filter { $0.operationRaw == SyncChangeJournal.Operation.delete.rawValue },
            in: context
        )

        for record in localWinners {
            let type: SyncChangeJournal.RecordType
            switch record.recordType {
            case RecordType.vehicle: type = .vehicle
            case RecordType.fuelingRecord: type = .fuelingRecord
            default: continue
            }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName,
                recordType: type,
                operation: .save,
                in: context
            )
        }

        for record in vehicleRecords + fuelingRecords {
            try storeSystemFields(from: record, in: context)
        }

        try context.save()
        StatisticsCacheService.rebuildCacheForAllVehicles(in: context, force: true)
        stateManager.syncEngineBootstrapComplete = true
    }

    /// The save-time value is captured before debounce. This keeps a save made
    /// while applying remote records suppressed even though the pull has
    /// released its scope by the time the debounced observer runs.
    nonisolated static func shouldScheduleAutomaticPush(
        wasSuppressedWhenSaved: Bool,
        isCurrentlySuppressed: Bool
    ) -> Bool {
        !wasSuppressedWhenSaved && !isCurrentlySuppressed
    }

    /// Run a local bulk write without allowing intermediate saves to auto-push.
    func withLocalPushesSuspended<T>(_ operation: () throws -> T) rethrows -> T {
        localPushSuspensionCount += 1
        defer { localPushSuspensionCount -= 1 }
        return try operation()
    }

    /// Run an async local bulk write without allowing intermediate saves to auto-push.
    func withLocalPushesSuspended<T>(_ operation: () async throws -> T) async rethrows -> T {
        localPushSuspensionCount += 1
        defer { localPushSuspensionCount -= 1 }
        return try await operation()
    }

    /// Stop monitoring local saves
    func stopMonitoring() {
        saveObserver?.cancel()
        saveObserver = nil
        let previousEngine = syncEngine
        syncEngine = nil
        Task {
            await previousEngine?.cancelOperations()
        }
        inFlightGenerations.removeAll()
        modelContainer = nil
    }

    /// Register every durable journal entry with CKSyncEngine. The journal
    /// remains authoritative until a sent-changes event acknowledges its exact
    /// generation, so an app crash never loses pending work.
    private func enqueuePendingJournalChanges() async {
        guard stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted,
              let syncEngine,
              let modelContainer else { return }

        do {
            let context = modelContainer.mainContext
            let entries = try context.fetch(FetchDescriptor<SyncChange>())
            let pending = entries.compactMap { entry -> CKSyncEngine.PendingRecordZoneChange? in
                guard let operation = SyncChangeJournal.Operation(rawValue: entry.operationRaw) else { return nil }
                let recordID = CKRecord.ID(recordName: entry.recordName, zoneID: zoneID)
                switch operation {
                case .save: return .saveRecord(recordID)
                case .delete: return .deleteRecord(recordID)
                }
            }
            if !pending.isEmpty {
                syncEngine.state.add(pendingRecordZoneChanges: pending)
            }
        } catch {
            Self.logger.error("Failed to read pending CloudKit changes: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
        }
    }

    /// Explicit foreground/manual sync prompt; automatic scheduling and retry
    /// remain owned by CKSyncEngine.
    func synchronizeNow() async {
        guard stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted else { return }
        if syncEngine == nil, let modelContainer {
            await startMonitoring(container: modelContainer)
        }
        guard let syncEngine else { return }
        do {
            if !stateManager.syncEngineBootstrapComplete, let modelContainer {
                try await ensureZoneExists()
                try await bootstrapSyncEngineIfNeeded(container: modelContainer)
            }
        } catch {
            Self.logger.error("CloudKit sync bootstrap retry failed: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
            return
        }
        await enqueuePendingJournalChanges()
        stateManager.syncStatus = .syncing
        do {
            try await syncEngine.fetchChanges()
            try await syncEngine.sendChanges()
        } catch {
            Self.logger.error("CloudKit sync request failed: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
        }
    }

    /// Compatibility for existing bulk-write callers; the persistent journal
    /// is still the source of pending work.
    func pushPendingLocalChanges() async {
        await enqueuePendingJournalChanges()
        guard let syncEngine,
              stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted else { return }
        do {
            try await syncEngine.sendChanges()
        } catch {
            Self.logger.error("CloudKit send request failed: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
        }
    }

    // MARK: CKSyncEngineDelegate

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let modelContainer else { return nil }
        do {
            let pending = syncEngine.state.pendingRecordZoneChanges.filter { change in
                guard context.options.scope.contains(change) else { return false }
                switch change {
                case .saveRecord(let recordID), .deleteRecord(let recordID):
                    return recordID.zoneID == zoneID
                @unknown default:
                    return false
                }
            }
            guard !pending.isEmpty else { return nil }

            let modelContext = modelContainer.mainContext
            let vehicles = try modelContext.fetch(FetchDescriptor<Vehicle>())
            let records = try modelContext.fetch(FetchDescriptor<FuelingRecord>())
            let metadata = try modelContext.fetch(FetchDescriptor<CloudRecordMetadata>())
                .reduce(into: [String: Data]()) { $0[$1.key] = $1.systemFieldsData }
            var cloudRecords: [CKRecord.ID: CKRecord] = [:]
            for vehicle in vehicles {
                let id = CKRecord.ID(recordName: vehicle.id.uuidString, zoneID: zoneID)
                let existing = try metadataRecord(key: metadataKey(type: RecordType.vehicle, recordName: id.recordName), data: metadata[metadataKey(type: RecordType.vehicle, recordName: id.recordName)])
                cloudRecords[id] = recordCodec.vehicleToCKRecord(vehicle, existingRecord: existing)
            }
            for record in records {
                let vehicleID = CKRecord.ID(recordName: record.vehicle.id.uuidString, zoneID: zoneID)
                let id = CKRecord.ID(recordName: record.id.uuidString, zoneID: zoneID)
                let key = metadataKey(type: RecordType.fuelingRecord, recordName: id.recordName)
                let existing = try metadataRecord(key: key, data: metadata[key])
                cloudRecords[id] = recordCodec.fuelingRecordToCKRecord(record, vehicleRecordID: vehicleID, existingRecord: existing)
            }

            let recordsToProvide = cloudRecords
            for change in pending {
                let recordID: CKRecord.ID
                switch change {
                case .saveRecord(let id), .deleteRecord(let id): recordID = id
                @unknown default: continue
                }
                if let entry = try journalEntry(for: recordID, context: modelContext) {
                    inFlightGenerations[entry.key] = entry.generation
                }
            }
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
                recordsToProvide[recordID]
            }
        } catch {
            Self.logger.error("Failed to prepare CloudKit change batch: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
            return nil
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard stateManager.iCloudSyncEnabled && stateManager.initialSyncCompleted else { return }
        guard let modelContainer else { return }
        let context = modelContainer.mainContext

        do {
            switch event {
            case .stateUpdate(let update):
                stateManager.syncEngineState = update.stateSerialization

            case .willFetchChanges, .willSendChanges:
                stateManager.syncStatus = .syncing

            case .fetchedRecordZoneChanges(let fetched):
                for modification in fetched.modifications where modification.record.recordID.zoneID == zoneID {
                    try storePendingRemoteChange(modification.record, in: context)
                }
                for deletion in fetched.deletions where deletion.recordID.zoneID == zoneID {
                    try storePendingRemoteDeletion(
                        recordID: deletion.recordID,
                        recordType: deletion.recordType,
                        in: context
                    )
                }
                // CKSyncEngine state updates can include the token for these
                // changes. Persist the inbox before this delegate event returns
                // so a process restart can replay them from that token.
                if context.hasChanges {
                    try context.save()
                }

            case .didFetchRecordZoneChanges(let finished):
                guard finished.zoneID == zoneID else { break }
                try applyPendingRemoteChanges(in: context, syncEngine: syncEngine)

            case .sentRecordZoneChanges(let sent):
                for record in sent.savedRecords {
                    try storeSystemFields(from: record, in: context)
                }
                for recordID in sent.deletedRecordIDs {
                    try deleteSystemFields(for: recordID, in: context)
                }
                if context.hasChanges {
                    try context.save()
                }
                for record in sent.savedRecords {
                    try acknowledge(recordID: record.recordID, in: context)
                }
                for recordID in sent.deletedRecordIDs {
                    try acknowledge(recordID: recordID, in: context)
                }
                for failure in sent.failedRecordSaves {
                    Self.logger.error("CloudKit rejected record \(failure.record.recordID.recordName): \(failure.error.localizedDescription)")
                    if failure.error.code == .serverRecordChanged,
                       let serverRecord = failure.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                        try storeSystemFields(from: serverRecord, in: context)
                        let result = try applyRemoteChanges(
                            changedRecords: [serverRecord],
                            deletedRecordIDs: [],
                            context: context
                        )
                        if result.recordsToUpload.contains(where: { $0.recordID == failure.record.recordID }) {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                        } else {
                            try acknowledge(recordID: failure.record.recordID, in: context)
                        }
                    } else {
                        stateManager.syncStatus = .error(String(localized: "Sync failed"))
                    }
                }
                for (recordID, error) in sent.failedRecordDeletes {
                    Self.logger.error("CloudKit rejected delete \(recordID.recordName): \(error.localizedDescription)")
                    if error.code == .unknownItem {
                        try acknowledge(recordID: recordID, in: context)
                    } else {
                        stateManager.syncStatus = .error(String(localized: "Sync failed"))
                    }
                }

            case .didFetchChanges:
                if syncEngine.state.pendingRecordZoneChanges.isEmpty,
                   try context.fetch(FetchDescriptor<SyncChange>()).isEmpty {
                    stateManager.syncStatus = .synced
                }

            case .didSendChanges:
                if syncEngine.state.pendingRecordZoneChanges.isEmpty,
                   try context.fetch(FetchDescriptor<SyncChange>()).isEmpty {
                    stateManager.syncStatus = .synced
                } else {
                    stateManager.syncStatus = .error(String(localized: "Sync failed"))
                }

            case .fetchedDatabaseChanges(let changes):
                let zoneWasDeleted = changes.deletions.contains { $0.zoneID == zoneID }
                guard zoneWasDeleted else { break }

                try clearCloudMetadata(in: context)
                for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) {
                    try SyncChangeJournal.enqueue(vehicle, in: context)
                }
                for record in try context.fetch(FetchDescriptor<FuelingRecord>()) {
                    try SyncChangeJournal.enqueue(record, in: context)
                }
                try context.save()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

            case .sentDatabaseChanges(let changes):
                if !changes.failedZoneSaves.isEmpty {
                    for failure in changes.failedZoneSaves {
                        Self.logger.error("CloudKit failed to recreate zone \(failure.zone.zoneID.zoneName): \(failure.error.localizedDescription)")
                    }
                    stateManager.syncStatus = .error(String(localized: "Sync failed"))
                }

            case .accountChange(let change):
                try clearCloudMetadata(in: context)
                stateManager.syncEngineBootstrapComplete = false
                if case .signOut = change.changeType {
                    stateManager.syncStatus = .unavailable
                } else {
                    try await ensureZoneExists()
                    try await bootstrapSyncEngineIfNeeded(container: modelContainer)
                }

            case .willFetchRecordZoneChanges:
                break

            @unknown default:
                Self.logger.error("Received an unhandled CloudKit sync event")
            }
        } catch {
            Self.logger.error("Failed to apply CloudKit sync event \(String(describing: event)): \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
        }
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

    private func metadataRecord(key: String, data: Data?) throws -> CKRecord? {
        guard let data else { return nil }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private func storeSystemFields(from record: CKRecord, in context: ModelContext) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let data = archiver.encodedData

        let key = metadataKey(type: record.recordType, recordName: record.recordID.recordName)
        var descriptor = FetchDescriptor<CloudRecordMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.systemFieldsData = data
        } else {
            context.insert(CloudRecordMetadata(key: key, systemFieldsData: data))
        }
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

    private func clearCloudMetadata(in context: ModelContext) throws {
        for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) {
            context.delete(metadata)
        }
        for pending in try context.fetch(FetchDescriptor<PendingRemoteChange>()) {
            context.delete(pending)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    private func applyPendingRemoteChanges(in context: ModelContext, syncEngine: CKSyncEngine?) throws {
        let entries = try loadPendingRemoteChanges(in: context)
            .filter { $0.change.recordID.zoneID == zoneID }
        guard !entries.isEmpty else { return }

        var modificationsByID: [CKRecord.ID: CKRecord] = [:]
        var deletionsByID: [CKRecord.ID: String] = [:]
        for entry in entries {
            switch entry.change {
            case .modification(let record):
                modificationsByID[record.recordID] = record
            case .deletion(let recordID, let recordType):
                deletionsByID[recordID] = recordType
            }
        }

        let deletedKeys = Set(deletionsByID.map { entry in
            metadataKey(type: entry.value, recordName: entry.key.recordName)
        })
        let localDeleteKeys = Set(try context.fetch(FetchDescriptor<SyncChange>())
            .filter { $0.operationRaw == SyncChangeJournal.Operation.delete.rawValue }
            .map(\.key))
        let changedRecords = modificationsByID.values.filter { record in
            let key = metadataKey(type: record.recordType, recordName: record.recordID.recordName)
            return !deletedKeys.contains(key) && !localDeleteKeys.contains(key)
        }
        let deletedRecordIDs = Array(deletionsByID.keys)
        var discardedInboxKeys = Set<String>()

        for (recordID, recordType) in deletionsByID where recordType == RecordType.vehicle {
            guard let vehicleID = UUID(uuidString: recordID.recordName) else { continue }
            var descriptor = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })
            descriptor.fetchLimit = 1
            if let vehicle = try context.fetch(descriptor).first {
                for child in vehicle.fuelingRecords ?? [] {
                    try SyncChangeJournal.enqueue(child, operation: .delete, in: context)
                }
            }
            discardedInboxKeys.formUnion(try removePendingRemoteChildren(of: vehicleID, in: context))
        }

        for record in changedRecords {
            try storeSystemFields(from: record, in: context)
        }
        for recordID in deletedRecordIDs {
            try deleteSystemFields(for: recordID, in: context)
        }

        let result = try applyRemoteChanges(
            changedRecords: changedRecords,
            deletedRecordIDs: deletedRecordIDs,
            context: context
        )
        for record in result.recordsToUpload {
            syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        }
        if !result.unresolvedChildIDs.isEmpty {
            Self.logger.error("Fetched \(result.unresolvedChildIDs.count) fueling records without a local parent vehicle")
        }

        let unresolvedNames = Set(result.unresolvedChildIDs.map(\.uuidString))
        for entry in entries where !discardedInboxKeys.contains(entry.model.key) {
            switch entry.change {
            case .modification(let record) where unresolvedNames.contains(record.recordID.recordName):
                continue
            case .modification:
                context.delete(entry.model)
            case .deletion(let recordID, _):
                context.delete(entry.model)
                try removeJournalEntries(for: recordID, in: context)
                if let syncEngine {
                    let pendingToRemove = syncEngine.state.pendingRecordZoneChanges.filter { change in
                        switch change {
                        case .saveRecord(let pendingID), .deleteRecord(let pendingID):
                            return pendingID == recordID
                        @unknown default:
                            return false
                        }
                    }
                    syncEngine.state.remove(pendingRecordZoneChanges: pendingToRemove)
                }
            }
        }

        if context.hasChanges {
            try context.save()
        }
    }

    private func loadPendingRemoteChanges(in context: ModelContext) throws -> [PendingRemoteChangeEntry] {
        try context.fetch(FetchDescriptor<PendingRemoteChange>()).map { pending in
            if let payload = try? JSONDecoder().decode(PendingRemoteChangePayload.self, from: pending.recordData) {
                switch payload.kind {
                case .modification:
                    guard let archivedRecord = payload.archivedRecord,
                          let record = try unarchiveRecord(from: archivedRecord) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return PendingRemoteChangeEntry(model: pending, change: .modification(record))
                case .deletion:
                    let recordID = CKRecord.ID(recordName: payload.recordName, zoneID: zoneID)
                    return PendingRemoteChangeEntry(
                        model: pending,
                        change: .deletion(recordID: recordID, recordType: payload.recordType)
                    )
                }
            }

            // Accept records written by the earlier V3 inbox format, which
            // stored the archived CKRecord directly instead of wrapping it.
            guard let record = try unarchiveRecord(from: pending.recordData) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return PendingRemoteChangeEntry(model: pending, change: .modification(record))
        }
    }

    private func storePendingRemoteChange(_ record: CKRecord, in context: ModelContext) throws {
        let archivedRecord = try CloudRecordCodec.archiveFullRecord(record)
        let payload = PendingRemoteChangePayload(
            kind: .modification,
            recordName: record.recordID.recordName,
            recordType: record.recordType,
            archivedRecord: archivedRecord
        )
        try storePendingRemoteChange(payload, in: context)
    }

    private func storePendingRemoteDeletion(
        recordID: CKRecord.ID,
        recordType: String,
        in context: ModelContext
    ) throws {
        let payload = PendingRemoteChangePayload(
            kind: .deletion,
            recordName: recordID.recordName,
            recordType: recordType,
            archivedRecord: nil
        )
        try storePendingRemoteChange(payload, in: context)
    }

    private func storePendingRemoteChange(_ payload: PendingRemoteChangePayload, in context: ModelContext) throws {
        let data = try JSONEncoder().encode(payload)
        let key = metadataKey(type: payload.recordType, recordName: payload.recordName)
        var descriptor = FetchDescriptor<PendingRemoteChange>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        var existing = try context.fetch(descriptor).first

        // Migrate the earlier V3 implementation's record-name-only key when
        // replaying an inbox entry created by that build.
        if existing == nil {
            let legacyKey = payload.recordName
            descriptor = FetchDescriptor<PendingRemoteChange>(predicate: #Predicate { $0.key == legacyKey })
            descriptor.fetchLimit = 1
            existing = try context.fetch(descriptor).first
        }

        if let existing {
            existing.key = key
            existing.recordData = data
        } else {
            context.insert(PendingRemoteChange(key: key, recordData: data))
        }
    }

    private func unarchiveRecord(from data: Data) throws -> CKRecord? {
        try CloudRecordCodec.unarchiveFullRecord(from: data)
    }

    /// Removes unresolved remote children after their parent is deleted and
    /// returns the inbox keys removed so callers don't delete them twice.
    private func removePendingRemoteChildren(of vehicleID: UUID, in context: ModelContext) throws -> Set<String> {
        var removedKeys = Set<String>()
        for pending in try loadPendingRemoteChanges(in: context) {
            guard case .modification(let record) = pending.change,
                  record.recordType == RecordType.fuelingRecord,
                  record[CloudFieldKey.FuelingRecord.vehicleRef] as? String == vehicleID.uuidString else { continue }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName,
                recordType: .fuelingRecord,
                operation: .delete,
                in: context
            )
            context.delete(pending.model)
            removedKeys.insert(pending.model.key)
        }
        return removedKeys
    }

    private func removeJournalEntries(for recordID: CKRecord.ID, in context: ModelContext) throws {
        for type in [RecordType.vehicle, RecordType.fuelingRecord] {
            let key = metadataKey(type: type, recordName: recordID.recordName)
            var descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == key })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                inFlightGenerations.removeValue(forKey: key)
                context.delete(existing)
            }
        }
    }

    private func applyLocalDeleteTombstones(
        _ entries: [SyncChange],
        in context: ModelContext
    ) throws {
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        let vehicleByID = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.id.uuidString, $0) })
        let recordByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id.uuidString, $0) })
        let deletedVehicleIDs = Set(entries.filter { $0.recordTypeRaw == RecordType.vehicle }
            .map(\.recordName))

        for entry in entries where entry.recordTypeRaw == RecordType.vehicle {
            if let vehicle = vehicleByID[entry.recordName] {
                context.delete(vehicle)
            }
        }
        for entry in entries where entry.recordTypeRaw == RecordType.fuelingRecord {
            guard let record = recordByID[entry.recordName],
                  !deletedVehicleIDs.contains(record.vehicle.id.uuidString) else { continue }
            context.delete(record)
        }
    }

    private func acknowledge(recordID: CKRecord.ID, in context: ModelContext) throws {
        guard let entry = try journalEntry(for: recordID, context: context) else { return }
        let capturedGeneration = inFlightGenerations.removeValue(forKey: entry.key) ?? entry.generation
        try SyncChangeJournal.remove(key: entry.key, generation: capturedGeneration, in: context)

        // If a newer edit replaced the journal entry while this request was in
        // flight, register that generation again after the old save completes.
        if let current = try journalEntry(for: recordID, context: context),
           current.generation != capturedGeneration,
           let syncEngine {
            let pending: CKSyncEngine.PendingRecordZoneChange
            if current.operationRaw == SyncChangeJournal.Operation.delete.rawValue {
                pending = .deleteRecord(recordID)
            } else {
                pending = .saveRecord(recordID)
            }
            syncEngine.state.add(pendingRecordZoneChanges: [pending])
        }
    }

    // MARK: - Conflict Resolution

    /// Decide which copy of a record is newer using `modifiedAt` with a
    /// `createdAt` fallback. Retained as a compatibility seam for tests.
    nonisolated static func resolveConflict(
        cloudModifiedAt: Date?,
        cloudCreatedAt: Date?,
        localModifiedAt: Date?,
        localCreatedAt: Date?
    ) -> ConflictWinner {
        SyncConflictResolver.resolve(
            cloudModifiedAt: cloudModifiedAt,
            cloudCreatedAt: cloudCreatedAt,
            localModifiedAt: localModifiedAt,
            localCreatedAt: localCreatedAt
        )
    }

    // MARK: - CKRecord Mapping

    /// Compatibility forwarding seam for existing tests and callers.
    func vehicleToCKRecord(_ vehicle: Vehicle) -> CKRecord {
        recordCodec.vehicleToCKRecord(vehicle)
    }

    /// Compatibility forwarding seam for existing tests and callers.
    func fuelingRecordToCKRecord(_ fuelingRecord: FuelingRecord, vehicleRecordID: CKRecord.ID) -> CKRecord {
        recordCodec.fuelingRecordToCKRecord(
            fuelingRecord,
            vehicleRecordID: vehicleRecordID
        )
    }

    // MARK: - Batch Operations

    /// Save records in batches with retry logic.
    private func batchSave(records: [CKRecord]) async throws {
        var offset = 0

        while offset < records.count {
            let end = min(offset + Self.batchSize, records.count)
            let batch = Array(records[offset..<end])

            var lastError: Error?
            var succeeded = false

            for attempt in 1...Self.maxRetries {
                do {
                    let (saveResults, _) = try await privateDatabase.modifyRecords(
                        saving: batch, deleting: [], savePolicy: .changedKeys
                    )

                    // Check per-record results for failures
                    var failedRecordIDs: [CKRecord.ID] = []
                    for (recordID, result) in saveResults {
                        if case .failure(let error) = result {
                            failedRecordIDs.append(recordID)
                            lastError = error
                            Self.logger.warning("Failed to save record \(recordID): \(error)")
                        }
                    }

                    if failedRecordIDs.isEmpty {
                        succeeded = true
                        break
                    } else {
                        Self.logger.warning("Batch attempt \(attempt): \(failedRecordIDs.count)/\(batch.count) records failed")
                        if attempt < Self.maxRetries {
                            try await Task.sleep(nanoseconds: UInt64(attempt) * Self.retryBaseDelay)
                        }
                    }
                } catch {
                    lastError = error
                    Self.logger.error("Batch save attempt \(attempt) threw error: \(error)")
                    if attempt < Self.maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(attempt) * Self.retryBaseDelay)
                    }
                }
            }

            if !succeeded, let error = lastError {
                throw error
            }

            offset = end

            if offset < records.count {
                try await Task.sleep(nanoseconds: Self.interBatchDelay)
            }
        }
    }

}
