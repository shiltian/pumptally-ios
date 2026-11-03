import CloudKit
import SwiftData
import os

/// Durable sync bookkeeping uses operation-scoped contexts. A failed commit
/// invalidates this session; a new session replays from its last saved checkpoint.
@MainActor
final class SyncPersistenceStore {
    enum Health: Sendable { case ready, recoveryRequired, closed }
    struct PendingPayload: Codable {
        enum Kind: String, Codable { case modification, deletion }
        let kind: Kind
        let recordName: String
        let recordType: String
        let archivedRecord: Data?

        static func decode(_ data: Data) throws -> Self {
            if let payload = try? JSONDecoder().decode(Self.self, from: data) { return payload }
            guard let record = try CloudRecordCodec.unarchiveFullRecord(from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Self(
                kind: .modification, recordName: record.recordID.recordName,
                recordType: record.recordType, archivedRecord: data)
        }

        func record() throws -> CKRecord? {
            guard let archivedRecord else { return nil }
            return try CloudRecordCodec.unarchiveFullRecord(from: archivedRecord)
        }
    }

    private let writer: OwnedModelStore
    private let commit: OwnedModelStore.Commit
    private let admission = OSAllocatedUnfairLock(initialState: Health.ready)
    private(set) var health: Health {
        get { admission.withLock { $0 } }
        set { admission.withLock { $0 = newValue } }
    }
    nonisolated private static let key = "FuelioZone.private"

    init(writer: OwnedModelStore, commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() }) {
        self.writer = writer
        self.commit = commit
    }

    /// Stop admitting callbacks immediately, then drain requests accepted before
    /// shutdown. A local-copy removal never races a previous session's commit.
    func close() async {
        health = .closed
        await writer.drain()
    }

    func prepare(accountID: String) async throws {
        try await transaction { actor in
            let context = actor.modelContext
            let state = try Self.checkpoint(in: context)
            guard state.accountID == nil || state.accountID == accountID else {
                throw SyncPersistenceError.accountChanged
            }
            if state.accountID == nil { state.accountID = accountID }
        }
    }

    func bindGeneration(_ control: CloudSyncControl) async throws {
        try await transaction { actor in
            let checkpoint = try Self.checkpoint(in: actor.modelContext)
            try control.requireReady(generation: checkpoint.cloudGeneration ?? CloudSyncControl.baselineGeneration)
            if checkpoint.cloudGeneration != control.generation { checkpoint.cloudGeneration = control.generation }
        }
    }

    /// A sign-in notification can confirm the account already verified during
    /// startup. Every other transition requires explicit reconciliation, even
    /// if the user eventually switches back to the same account.
    func isVerifiedSignIn(_ change: CKSyncEngine.Event.AccountChange.ChangeType) async throws -> Bool {
        guard case .signIn(let currentUser) = change else { return false }
        return try await transaction { actor in
            try actor.modelContext.fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID == currentUser.recordName
        }
    }

    func loadEncodedState() async throws -> Data? {
        try await transaction { try $0.modelContext.fetch(FetchDescriptor<SyncCheckpoint>()).first?.engineState }
    }

    var bootstrapCompleted: Bool {
        get async throws {
            try await transaction {
                try $0.modelContext.fetch(FetchDescriptor<SyncCheckpoint>()).first?.bootstrapCompleted == true
            }
        }
    }

    func markBootstrapped() async throws {
        try await transaction { try Self.checkpoint(in: $0.modelContext).bootstrapCompleted = true }
    }

    func resetCheckpoint() async throws {
        try await transaction { actor in
            let state = try Self.checkpoint(in: actor.modelContext)
            state.engineState = nil
            state.bootstrapCompleted = false
        }
    }

    func saveEncodedState(_ data: Data) async throws {
        try await transaction { try Self.checkpoint(in: $0.modelContext).engineState = data }
    }

    func capture(modifications: [CKRecord], deletions: [(CKRecord.ID, String)]) async throws {
        try await transaction { actor in
            let context = actor.modelContext
            for record in modifications {
                try Self.stageInbound(
                    PendingPayload(
                        kind: .modification, recordName: record.recordID.recordName,
                        recordType: record.recordType, archivedRecord: CloudRecordCodec.archiveFullRecord(record)
                    ), in: context)
            }
            for (id, type) in deletions {
                try Self.stageInbound(
                    PendingPayload(kind: .deletion, recordName: id.recordName, recordType: type, archivedRecord: nil),
                    in: context)
            }
        }
    }

    /// This operation never creates deletion intent. Refuse to destroy any
    /// existing outbox work, including unverified deletions from older releases.
    func removeLocalCopy() async throws {
        try await transaction { actor in
            let context = actor.modelContext
            guard try context.fetchCount(FetchDescriptor<SyncChange>()) == 0 else {
                throw SyncPersistenceError.unsynchronizedChanges
            }
            for row in try context.fetch(FetchDescriptor<FuelingRecord>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<Vehicle>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<PendingRemoteChange>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) { context.delete(row) }
            let state = try Self.checkpoint(in: context)
            state.engineState = nil
            state.bootstrapCompleted = false
            state.detached = true
        }
    }

    /// Read-only preflight. Repeat inside the transaction before changing data.
    func validateActivation(accountID: String) async throws {
        try await transaction { actor in try Self.validateActivation(accountID: accountID, in: actor.modelContext) }
    }

    nonisolated private static func validateActivation(accountID: String, in context: ModelContext) throws {
        let state = try context.fetch(FetchDescriptor<SyncCheckpoint>()).first
        guard let previous = state?.accountID, previous != accountID else { return }
        guard try context.fetchCount(FetchDescriptor<PendingRemoteChange>()) == 0,
            try !context.fetch(FetchDescriptor<SyncChange>()).contains(where: { $0.operationRaw == "delete" })
        else {
            throw SyncPersistenceError.accountDataNeedsReview
        }
    }

    /// Reconciliation and activation are one durable store transaction. A failed
    /// commit retains the old account, inbox, checkpoint, records and outbox.
    func activate(
        accountID: String, generation: String = CloudSyncControl.baselineGeneration,
        reconciling operation: @escaping @Sendable (isolated ModelStoreActor) throws -> Void
    ) async throws {
        try await transaction { actor in
            let context = actor.modelContext
            try Self.validateActivation(accountID: accountID, in: context)
            let state = try Self.checkpoint(in: context)
            if let previous = state.accountID, previous != accountID {
                for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) { context.delete(metadata) }
                context.processPendingChanges()
            }
            try operation(actor)
            state.accountID = accountID
            state.cloudGeneration = generation
            state.engineState = nil
            state.bootstrapCompleted = true
            state.detached = false
        }
    }

    func detach() async throws {
        try await transaction { try Self.checkpoint(in: $0.modelContext).detached = true }
    }

    var isDetached: Bool {
        get async throws {
            try await transaction {
                try $0.modelContext.fetch(FetchDescriptor<SyncCheckpoint>()).first?.detached == true
            }
        }
    }

    /// Preferences may not have been written when the process stopped after
    /// activation. The store is authoritative; disabling records detachment.
    var committedAccountID: String? {
        get async throws {
            try await transaction { actor in
                guard let state = try actor.modelContext.fetch(FetchDescriptor<SyncCheckpoint>()).first,
                    state.bootstrapCompleted == true, state.detached != true
                else { return nil }
                return state.accountID
            }
        }
    }

    func transaction<Result: Sendable>(
        _ operation: @escaping @Sendable (isolated ModelStoreActor) throws -> Result
    ) async throws -> Result {
        let admission = admission
        let commit = commit
        return try await writer.transaction(commit: { actor in
            do { try commit(actor) } catch {
                admission.withLock { $0 = .recoveryRequired }
                throw error
            }
        }) { actor in
            guard admission.withLock({ $0 == .ready }) else { throw SyncPersistenceError.recoveryRequired }
            return try operation(actor)
        }
    }

    nonisolated private static func checkpoint(in context: ModelContext) throws -> SyncCheckpoint {
        if let existing = try context.fetch(FetchDescriptor<SyncCheckpoint>()).first { return existing }
        let state = SyncCheckpoint(key: key)
        context.insert(state)
        return state
    }

    nonisolated static func stageSystemFields(from record: CKRecord, in context: ModelContext) throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let key = "\(record.recordType):\(record.recordID.recordName)"
        var descriptor = FetchDescriptor<CloudRecordMetadata>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.systemFieldsData = archiver.encodedData
        } else {
            context.insert(CloudRecordMetadata(key: key, systemFieldsData: archiver.encodedData))
        }
    }

    nonisolated static func stageInbound(_ payload: PendingPayload, in context: ModelContext) throws {
        let key = "\(payload.recordType):\(payload.recordName)"
        let legacyKey = payload.recordName
        let descriptor = FetchDescriptor<PendingRemoteChange>(
            predicate: #Predicate { $0.key == key || $0.key == legacyKey })
        let data = try JSONEncoder().encode(payload)
        let matches = try context.fetch(descriptor)
        if let existing = matches.first(where: { $0.key == key }) ?? matches.first {
            for duplicate in matches where duplicate !== existing { context.delete(duplicate) }
            existing.key = key
            existing.recordData = data
        } else {
            context.insert(PendingRemoteChange(key: key, recordData: data))
        }
    }
}
