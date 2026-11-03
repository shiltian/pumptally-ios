import Foundation
import CloudKit
import SwiftData
import Combine
import os

/// Synchronizes SwiftData with a private CloudKit database using a durable
/// local journal and explicit conflict-resolution rules.
@MainActor
final class CloudSyncService: ObservableObject, SyncEngineReceiver {

    // MARK: - Properties

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "CloudSync"
    )

    let stateManager: SyncStateManager

    private let environment: any CloudSyncEnvironment
    private let writer: OwnedModelStore
    private let makePersistenceStore: @MainActor (OwnedModelStore) -> SyncPersistenceStore
    private let zoneID: CKRecordZone.ID
    private var activity = SyncActivity()

    private var saveObserver: AnyCancellable?
    private var stateForwardingObserver: AnyCancellable?
    private final class Runtime {
        let driver: any SyncEngineDriver
        let store: SyncPersistenceStore
        let accountID: String
        var control: CloudSyncControl
        init(driver: any SyncEngineDriver, store: SyncPersistenceStore, accountID: String, control: CloudSyncControl) {
            self.driver = driver
            self.store = store
            self.accountID = accountID
            self.control = control
        }
    }
    private enum Session {
        case stopped
        case starting(UUID, SyncPersistenceStore)
        case stopping, recovering
        case running(Runtime)
        case recoveryRequired
    }
    private var session: Session = .stopped
    private func ownsStartup(_ attempt: UUID) -> Bool {
        guard case .starting(let current, _) = session else { return false }
        return current == attempt
    }
    private var runtime: Runtime? {
        guard case .running(let runtime) = session else { return nil }
        return runtime
    }
    private var syncStore: SyncPersistenceStore? {
        switch session {
        case .starting(_, let store): return store
        case .running(let runtime): return runtime.store
        default: return nil
        }
    }
    private var syncEngine: (any SyncEngineDriver)? { runtime?.driver }
    private func recoveryCoordinator() -> CloudRecoveryCoordinator {
        CloudRecoveryCoordinator(
            environment: environment,
            store: CloudRecoveryStore(persistence: makePersistenceStore(writer)), codec: recordCodec)
    }
    private let operationCoordinator = SyncOperationCoordinator()
    private var inFlightGenerations: [String: String] = [:]
    private var journalRead: UUID?
    private var statusRead: UUID?

    /// Suppresses automatic local-save pushes while a vetted bulk write is in progress.
    private let localPushSuspensionCount = OSAllocatedUnfairLock(initialState: 0)

    // MARK: - Constants

    /// Debounce interval for local save observations (seconds).
    private static let saveDebounceInterval: TimeInterval = 1

    private var recordCodec: CloudRecordCodec {
        CloudRecordCodec(zoneID: zoneID)
    }

    // MARK: - Initialization

    init(
        writer: OwnedModelStore,
        stateManager: SyncStateManager = SyncStateManager(),
        environment: (any CloudSyncEnvironment)? = nil,
        makePersistenceStore: @escaping @MainActor (OwnedModelStore) -> SyncPersistenceStore = {
            SyncPersistenceStore(writer: $0)
        }
    ) {
        self.writer = writer
        self.stateManager = stateManager
        let selectedEnvironment = environment ?? NativeCloudSyncEnvironment()
        self.environment = selectedEnvironment
        self.zoneID = selectedEnvironment.recordZoneID
        self.makePersistenceStore = makePersistenceStore

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
            let status = try await environment.accountStatus()
            switch status {
            case .available:
                return true
            default:
                stateManager.syncStatus = .unavailable
                return false
            }
        } catch {
            stateManager.syncStatus = .error(String(localized: "Failed to check iCloud status"))
            return false
        }
    }

    // MARK: - Zone Management

    /// Ensure the custom record zone exists
    private func ensureZoneExists() async throws {
        try await environment.ensureZone()
    }

    // MARK: - Initial Enable

    /// Reads the current source without changing local data or enabling sends.
    /// The proposal binds the eventual user choice to this account and store.
    func prepareInitialSync() async throws -> InitialSyncProposal {
        let container = writer.container
        return try await operationCoordinator.runExclusive {
            try requireInitialEnable()
            do {
                stateManager.syncStatus = .syncing
                guard try await environment.accountStatus() == .available else {
                    throw InitialSyncError.unavailableAccount
                }
                let accountID = try await environment.accountID()
                let store = makePersistenceStore(writer)
                try await store.validateActivation(accountID: accountID)
                try await store.transaction { try CloudRecoveryStore.requireNoPendingRecovery(in: $0.modelContext) }
                try await ensureZoneExists()
                let snapshot = try await environment.snapshot()
                try await verifyAccount(accountID)
                try requireInitialEnable()
                let control =
                    try snapshot.control.map { try CloudSyncControl(record: $0, zone: zoneID) }
                    ?? CloudSyncControl.baseline(in: zoneID)
                try control.requireReady(generation: control.generation)
                stateManager.syncStatus = .idle
                return InitialSyncProposal(
                    accountID: accountID, containerID: ObjectIdentifier(container),
                    hasCloudData: !snapshot.businessRecords.isEmpty,
                    localChanges: try await writer.transaction {
                        try InitialSyncProposal.localChanges(in: $0.modelContext)
                    }, cloudGeneration: control.generation)
            } catch {
                stateManager.syncStatus = .error(error.localizedDescription)
                throw error
            }
        }
    }

    /// Owns account verification, preparation, the local transaction, preferences,
    /// and engine startup. No network suspension occurs inside the transaction.
    func enableSync(
        strategy: InitialSyncStrategy, proposal: InitialSyncProposal
    ) async throws {
        try await operationCoordinator.runExclusive {
            try requireInitialEnable()
            guard proposal.containerID == ObjectIdentifier(writer.container) else {
                throw InitialSyncError.differentStore
            }
            do {
                stateManager.syncStatus = .syncing
                await stopMonitoring()
                try await verifyAccount(proposal.accountID)
                let store = makePersistenceStore(writer)
                try await store.validateActivation(accountID: proposal.accountID)
                if case .replaceCloud = strategy {
                    try await performRecovery(
                        accountID: proposal.accountID, expectedGeneration: proposal.cloudGeneration,
                        expectedLocalChanges: proposal.localChanges)
                    return
                }
                let snapshot = try await environment.snapshot()
                let control =
                    try snapshot.control.map { try CloudSyncControl(record: $0, zone: zoneID) }
                    ?? CloudSyncControl.baseline(in: zoneID)
                try control.requireReady(generation: proposal.cloudGeneration)
                for record in snapshot.businessRecords {
                    try CloudSyncControl.validateBusinessRecord(record, generation: control.generation)
                }
                let reconciler = InitialSyncReconciler(codec: recordCodec)
                let plan: InitialSyncReconciler.Plan
                if case .useCloud = strategy {
                    guard snapshot.otherRecords.isEmpty else { throw CloudRecoveryError.invalidControl }
                    plan = .useCloud(
                        snapshot,
                        try CloudSnapshotValidator().validate(
                            vehicleRecords: snapshot.vehicles, fuelingRecordRecords: snapshot.fuelingRecords))
                } else {
                    plan = .merge(snapshot)
                }
                try await verifyAccount(proposal.accountID)
                try Task.checkCancellation()
                try await store.activate(accountID: proposal.accountID, generation: control.generation) { actor in
                    let context = actor.modelContext
                    if case .useCloud = strategy {
                        guard try InitialSyncProposal.localChanges(in: context) == proposal.localChanges else {
                            throw InitialSyncError.localDataChanged
                        }
                    }
                    try reconciler.stage(plan, in: context)
                }
                // Preferences describe the committed user intent. Later network
                // failures keep the durable activation and its outgoing work.
                stateManager.initialSyncCompleted = true
                stateManager.iCloudSyncEnabled = true
                stateManager.syncStatus = .syncing
                await synchronizeNow()
            } catch {
                recordRecoveryFailure(error)
                throw error
            }
        }
    }

    private func requireInitialEnable() throws {
        try Task.checkCancellation()
        guard !stateManager.iCloudSyncEnabled || !stateManager.initialSyncCompleted else {
            throw InitialSyncError.alreadyEnabled
        }
    }

    private func verifyAccount(_ expected: String) async throws {
        let current = try await environment.accountID()
        try Task.checkCancellation()
        guard current == expected else { throw SyncPersistenceError.accountChanged }
    }

    // MARK: - Durable cloud replacement

    func replaceCloudDataWithLocal() async throws {
        try await operationCoordinator.runExclusive {
            do {
                let accountID = try await environment.accountID()
                try await performRecovery(accountID: accountID)
            } catch {
                recordRecoveryFailure(error)
                throw error
            }
        }
    }

    /// Called at startup even when a crash occurred before enabling preferences.
    /// The persisted receipt, rather than a preference flag, owns resumption.
    func resumeRecoveryIfNeeded() async throws {
        var resumed = false
        try await operationCoordinator.runExclusive {
            let coordinator = recoveryCoordinator()
            guard try await coordinator.store.pending() != nil else {
                if !stateManager.iCloudSyncEnabled || !stateManager.initialSyncCompleted,
                    let account = try await coordinator.store.persistence.committedAccountID,
                    try await environment.accountID() == account
                {
                    finishRecoveryIntent()
                    resumed = true
                }
                return
            }
            await stopMonitoring()
            session = .recovering
            stateManager.syncStatus = .syncing
            do {
                _ = try await coordinator.resumeIfNeeded()
                finishRecoveryIntent()
                resumed = true
            } catch {
                recordRecoveryFailure(error)
                throw error
            }
        }
        if resumed { await synchronizeNow() }
    }

    private func performRecovery(
        accountID: String, expectedGeneration: String? = nil,
        expectedLocalChanges: [String: String]? = nil
    ) async throws {
        await stopMonitoring()
        session = .recovering
        stateManager.syncStatus = .syncing
        try await recoveryCoordinator().replace(
            accountID: accountID, expectedGeneration: expectedGeneration,
            expectedLocalChanges: expectedLocalChanges)
        finishRecoveryIntent()
        await synchronizeNow()
    }

    private func finishRecoveryIntent() {
        session = .stopped
        stateManager.initialSyncCompleted = true
        stateManager.iCloudSyncEnabled = true
        stateManager.syncStatus = .syncing
    }

    private func recordRecoveryFailure(_ error: Error) {
        session = .recoveryRequired
        switch error {
        case CloudRecoveryError.generationChanged, SyncPersistenceError.accountChanged:
            stateManager.iCloudSyncEnabled = false
            stateManager.initialSyncCompleted = false
        default: break
        }
        stateManager.syncStatus = .error(error.localizedDescription)
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
        let snapshot = try await environment.snapshot()
        return (snapshot.vehicles, snapshot.fuelingRecords)
    }

    // MARK: - Monitoring Local Changes

    /// Start CKSyncEngine and monitor durable journal changes.
    func startMonitoring() async {
        switch session {
        case .running, .starting, .stopping, .recovering: return
        case .stopped, .recoveryRequired: break
        }
        let attempt = UUID()
        let store = makePersistenceStore(writer)
        session = .starting(attempt, store)
        saveObserver?.cancel()
        do {
            try await store.transaction { try CloudRecoveryStore.requireNoPendingRecovery(in: $0.modelContext) }
            let detached = try await store.isDetached
            guard ownsStartup(attempt) else { return }
            guard !detached else {
                stateManager.iCloudSyncEnabled = false
                session = .stopped
                return
            }
            let accountID = try await environment.accountID()
            guard ownsStartup(attempt) else { return }
            try await store.prepare(accountID: accountID)
            guard ownsStartup(attempt), stateManager.iCloudSyncEnabled else { return }
            try await ensureZoneExists()
            let control = try await loadControl()
            guard ownsStartup(attempt) else { return }
            try await store.bindGeneration(control)
            guard ownsStartup(attempt) else { return }
            try await bootstrapSyncEngineIfNeeded(accountID: accountID, store: store, control: control)
            guard ownsStartup(attempt) else { return }
            try await verifyAccount(accountID)
            guard ownsStartup(attempt) else { return }
            let database = SyncDatabase(codec: recordCodec, generation: control.generation)
            _ = try await store.transaction { try database.applyInbox(in: $0.modelContext) }
            guard ownsStartup(attempt) else { return }
            let encoded = try await store.loadEncodedState()
            guard ownsStartup(attempt), stateManager.iCloudSyncEnabled else { return }
            let driver = try environment.makeDriver(state: encoded, receiver: self)
            activity = SyncActivity()
            session = .running(Runtime(driver: driver, store: store, accountID: accountID, control: control))
            driver.start()
        } catch {
            guard ownsStartup(attempt) else { return }
            recordRecoveryFailure(error)
            Self.logger.error("CloudKit sync bootstrap failed: \(error)")
            await store.close()
            return
        }

        saveObserver = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .map { [suppression = localPushSuspensionCount] _ in suppression.withLock { $0 > 0 } }
            .receive(on: RunLoop.main)
            .debounce(for: .seconds(Self.saveDebounceInterval), scheduler: RunLoop.main)
            .sink { [weak self] wasSuppressedWhenSaved in
                guard Self.shouldScheduleAutomaticPush(
                    wasSuppressedWhenSaved: wasSuppressedWhenSaved,
                        isCurrentlySuppressed: self?.localPushSuspensionCount.withLock { $0 > 0 } ?? false
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
    private func bootstrapSyncEngineIfNeeded(accountID: String, store: SyncPersistenceStore, control: CloudSyncControl)
        async throws
    {
        guard try await !store.bootstrapCompleted else { return }
        let snapshot = try await environment.snapshot()
        try await verifyAccount(accountID)
        guard self.syncStore === store, stateManager.iCloudSyncEnabled else { throw CancellationError() }
        let current =
            try snapshot.control.map { try CloudSyncControl(record: $0, zone: zoneID) }
            ?? CloudSyncControl.baseline(in: zoneID)
        try current.requireReady(generation: control.generation)
        for record in snapshot.businessRecords {
            try CloudSyncControl.validateBusinessRecord(record, generation: control.generation)
        }
        let reconciler = InitialSyncReconciler(codec: recordCodec)
        try await store.activate(accountID: accountID, generation: control.generation) { actor in
            try reconciler.stageMerge(snapshot, in: actor.modelContext)
        }
    }

    private func loadControl() async throws -> CloudSyncControl {
        if let record = try await environment.controlRecord() {
            return try CloudSyncControl(record: record, zone: zoneID)
        }
        return try CloudSyncControl.baseline(in: zoneID)
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
        localPushSuspensionCount.withLock { $0 += 1 }
        defer { localPushSuspensionCount.withLock { $0 -= 1 } }
        return try operation()
    }

    /// Run an async local bulk write without allowing intermediate saves to auto-push.
    func withLocalPushesSuspended<T>(_ operation: () async throws -> T) async rethrows -> T {
        localPushSuspensionCount.withLock { $0 += 1 }
        defer { localPushSuspensionCount.withLock { $0 -= 1 } }
        return try await operation()
    }

    enum DisablePolicy { case keepLocalData, removeLocalCopy }

    func disable(_ policy: DisablePolicy) async throws {
        try await operationCoordinator.runExclusive {
            do { try await performDisable(policy) } catch {
                stateManager.syncStatus = .error(error.localizedDescription); throw error
            }
        }
    }

    private func performDisable(_ policy: DisablePolicy) async throws {
        let store = makePersistenceStore(writer)
        try await store.transaction { try CloudRecoveryStore.requireNoPendingRecovery(in: $0.modelContext) }
        if case .removeLocalCopy = policy {
            let pending = try await writer.transaction { try $0.modelContext.fetchCount(FetchDescriptor<SyncChange>()) }
            guard pending == 0 else { throw SyncPersistenceError.unsynchronizedChanges }
        }
        stateManager.iCloudSyncEnabled = false
        stateManager.syncStatus = .syncing
        await stopMonitoring()
        switch policy {
        case .removeLocalCopy: try await store.removeLocalCopy()
        case .keepLocalData: try await store.detach()
        }
        stateManager.resetSyncState()
    }

    func stopMonitoring() async {
        saveObserver?.cancel()
        saveObserver = nil
        let previousEngine = syncEngine
        let previousStore = syncStore
        session = .stopping
        inFlightGenerations.removeAll()
        await previousStore?.close()
        await previousEngine?.cancelOperations()
        if case .stopping = session { session = .stopped }
    }

    /// Register every durable journal entry with CKSyncEngine. The journal
    /// remains authoritative until a sent-changes event acknowledges its exact
    /// generation, so an app crash never loses pending work.
    private func enqueuePendingJournalChanges() async {
        guard stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted,
            let syncEngine
        else { return }

        let request = UUID()
        journalRead = request
        do {
            let database = SyncDatabase(codec: recordCodec)
            let pending = try await writer.transaction { try database.pendingChanges(in: $0.modelContext) }
            guard self.syncEngine === syncEngine, journalRead == request, stateManager.iCloudSyncEnabled else { return }
            let registered = syncEngine.pendingRecordZoneChanges
            let desired = Set(pending)
            let existing = Set(registered)
            let superseded = registered.filter { !desired.contains($0) }
            let additions = pending.filter { !existing.contains($0) }
            if !superseded.isEmpty { syncEngine.remove(pendingRecordZoneChanges: superseded) }
            if !additions.isEmpty { syncEngine.add(pendingRecordZoneChanges: additions) }
            try await refreshStatus(driver: syncEngine)
        } catch {
            guard self.syncEngine === syncEngine, journalRead == request else { return }
            activity.failed(.send, error: error)
            Self.logger.error("Failed to read pending CloudKit changes: \(error)")
            stateManager.syncStatus = .error(String(localized: "Sync failed"))
        }
    }

    /// Explicit foreground/manual sync prompt; automatic scheduling and retry
    /// remain owned by CKSyncEngine.
    func synchronizeNow() async {
        guard stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted else { return }
        if syncEngine == nil {
            await startMonitoring()
        }
        guard let syncEngine else { return }
        await enqueuePendingJournalChanges()
        guard await perform(.fetch, on: syncEngine) else { return }
        guard self.syncEngine === syncEngine, stateManager.iCloudSyncEnabled else { return }
        _ = await perform(.send, on: syncEngine)
    }

    /// CKSyncEngine owns transient retry and scheduling. Explicit requests share
    /// the same outcome tracking as automatic SDK callbacks.
    private func perform(_ operation: SyncActivity.Operation, on driver: any SyncEngineDriver) async -> Bool {
        activity.started(operation)
        do {
            try await refreshStatus(driver: driver)
            guard syncEngine === driver, stateManager.iCloudSyncEnabled else { return false }
            switch operation {
            case .fetch: try await driver.fetchChanges()
            case .send: try await driver.sendChanges()
            }
            guard syncEngine === driver else { return false }
            activity.finished(operation)
            try await refreshStatus(driver: driver)
            return true
        } catch {
            guard syncEngine === driver else { return false }
            activity.failed(operation, error: error)
            stateManager.syncStatus = .error(error.localizedDescription)
            return false
        }
    }

    func pushPendingLocalChanges() async {
        await enqueuePendingJournalChanges()
        guard let syncEngine, stateManager.iCloudSyncEnabled,
              stateManager.initialSyncCompleted else { return }
        _ = await perform(.send, on: syncEngine)
    }

    // MARK: - SyncEngineReceiver

    func nextBatch(
        scope: CKSyncEngine.SendChangesOptions.Scope,
        from syncEngine: any SyncEngineDriver
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let bound = runtime, bound.driver === syncEngine, bound.store.health == .ready,
            stateManager.iCloudSyncEnabled
        else { return nil }
        do {
            let pending = syncEngine.pendingRecordZoneChanges.filter { change in
                guard scope.contains(change) else { return false }
                switch change {
                case .saveRecord(let recordID), .deleteRecord(let recordID):
                    return recordID.zoneID == zoneID
                @unknown default:
                    return false
                }
            }
            guard !pending.isEmpty else { return nil }

            let database = SyncDatabase(codec: recordCodec)
            let blocked = try await writer.transaction { try database.blockedVehicleNames(in: $0.modelContext) }
            let builder = await CloudChangeBatchBuilder.make(
                container: writer.container, codec: recordCodec, blockedParents: blocked)
            let prepared = try await builder.build(pendingChanges: pending, control: bound.control)
            let metrics = await builder.metrics
            guard self.syncEngine === syncEngine, syncStore?.health == .ready,
                stateManager.iCloudSyncEnabled, let prepared
            else { return nil }
            inFlightGenerations.merge(prepared.generations) { _, current in current }
            Self.logger.debug(
                "Prepared sync batch: journal=\(metrics.journalEntriesRead) vehicles=\(metrics.vehiclesRead) records=\(metrics.fuelingRecordsRead) metadata=\(metrics.metadataRead) encoded=\(metrics.recordsEncoded)"
            )
            return prepared.batch
        } catch {
            guard self.syncEngine === syncEngine else { return nil }
            Self.logger.error("Failed to prepare CloudKit change batch: \(error)")
            activity.failed(.send, error: error)
            stateManager.syncStatus = .error(error.localizedDescription)
            return nil
        }
    }

    func receive(_ event: SyncEngineEvent, from driver: any SyncEngineDriver) async {
        guard stateManager.iCloudSyncEnabled && stateManager.initialSyncCompleted,
            let bound = runtime, bound.driver === driver, bound.store.health == .ready
        else { return }
        let store = bound.store
        let database = SyncDatabase(codec: recordCodec, generation: bound.control.generation)
        do {
            switch event {
            case .checkpoint(let data):
                try await store.saveEncodedState(data)
                guard self.syncEngine === driver else { return }
                stateManager.retireLegacyCheckpoint()
            case .willFetch: activity.started(.fetch)
            case .willSend: activity.started(.send)
            case .fetchedRecords(let modifications, let deletions):
                try await store.capture(
                    modifications: modifications.filter { $0.recordID.zoneID == zoneID },
                    deletions: deletions.filter { $0.recordID.zoneID == zoneID })
                guard self.syncEngine === driver else { return }
                for record in modifications
                where record.recordType == CloudSyncControl.recordType && record.recordID.zoneID == zoneID {
                    let incoming = try CloudSyncControl(record: record, zone: zoneID)
                    try incoming.requireReady(generation: bound.control.generation)
                    bound.control = incoming
                }
            case .fetchedZone(let id, let error):
                guard id == zoneID else { break }
                if let error {
                    activity.failed(.fetch, error: error)
                } else {
                    let control = try await loadControl()
                    try control.requireReady(generation: bound.control.generation)
                    try await verifyAccount(bound.accountID)
                    guard self.syncEngine === driver else { return }
                    bound.control = control
                    let effects = try await store.transaction { try database.applyInbox(in: $0.modelContext) }
                    guard self.syncEngine === driver else { return }
                    apply(effects, to: driver)
                }
            case .sentRecords(let sent):
                try await verifyAccount(bound.accountID)
                guard self.syncEngine === driver else { return }
                let outcome = try bound.control.outcome(of: sent)
                bound.control = outcome.control
                let generations = inFlightGenerations
                let effects = try await store.transaction {
                    let context = $0.modelContext
                    var effects = try database.stageSent(outcome.business, generations: generations, in: context)
                    if !outcome.retryIDs.isEmpty {
                        effects.additions += try database.pendingChanges(in: context).filter { change in
                            switch change {
                            case .saveRecord(let id), .deleteRecord(let id): return outcome.retryIDs.contains(id)
                            @unknown default: return false
                            }
                        }
                    }
                    return effects
                }
                guard self.syncEngine === driver else { return }
                apply(effects, to: driver)
            case .didFetch: activity.finished(.fetch)
            case .didSend: activity.finished(.send)
            case .deletedZones(let ids):
                guard ids.contains(zoneID) else { break }
                throw CloudRecoveryError.generationChanged
            case .sentZones(let errors):
                for error in errors { activity.failed(.send, error: error) }
            case .accountChanged(let change):
                let verified = try await store.isVerifiedSignIn(change)
                guard self.syncEngine === driver else { return }
                if verified {
                    await enqueuePendingJournalChanges()
                } else {
                    try await store.detach()
                    guard self.syncEngine === driver else { return }
                    stateManager.iCloudSyncEnabled = false
                    stateManager.initialSyncCompleted = false
                    stateManager.syncStatus = .unavailable
                    saveObserver?.cancel()
                    saveObserver = nil
                    inFlightGenerations.removeAll()
                    session = .stopped
                    await store.close()
                    Task { await driver.cancelOperations() }
                }
            case .adapterFailure(let error): throw error
            }
            guard self.syncEngine === driver else { return }
            try await refreshStatus(driver: driver)
        } catch {
            guard self.syncEngine === driver else { return }
            Self.logger.error("Failed to persist or apply CloudKit changes: \(error)")
            recordRecoveryFailure(error)
            await store.close()
            Task { await driver.cancelOperations() }
        }
    }

    private func apply(_ effects: SyncDatabase.Effects, to driver: any SyncEngineDriver) {
        journalRead = nil
        for (key, generation) in effects.acknowledged where inFlightGenerations[key] == generation {
            inFlightGenerations.removeValue(forKey: key)
        }
        for key in effects.clearedKeys { inFlightGenerations.removeValue(forKey: key) }
        if !effects.additions.isEmpty { driver.add(pendingRecordZoneChanges: effects.additions) }
        let removals = driver.pendingRecordZoneChanges.filter {
            switch $0 {
            case .saveRecord(let id), .deleteRecord(let id): return effects.removals.contains(id)
            @unknown default: return false
            }
        }
        if !removals.isEmpty { driver.remove(pendingRecordZoneChanges: removals) }
        for error in effects.errors { activity.failed(.send, error: error) }
    }

    private func refreshStatus(driver: any SyncEngineDriver) async throws {
        let request = UUID()
        statusRead = request
        let database = SyncDatabase(codec: recordCodec)
        let status = try await writer.transaction { try database.status(in: $0.modelContext) }
        guard self.syncEngine === driver, statusRead == request else { return }
        let hasPending =
            !driver.pendingRecordZoneChanges.isEmpty || !driver.pendingDatabaseChanges.isEmpty
            || status.outboxCount > 0 || status.inboxCount > 0
        let resolved = activity.status(hasPendingWork: hasPending, needsReview: status.needsReview)
        let description = activity.description
        let records = driver.pendingRecordZoneChanges.count
        let zones = driver.pendingDatabaseChanges.count
        Self.logger.debug(
            "Sync progress: \(description, privacy: .public); local=\(status.outboxCount) inbox=\(status.inboxCount) records=\(records) zones=\(zones) review=\(status.needsReview)"
        )
        if stateManager.syncStatus != resolved { stateManager.syncStatus = resolved }
    }
}
