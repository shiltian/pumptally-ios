import CloudKit

/// Receipt state and a server generation own recovery across process lifetimes.
/// A restart reads the server again; acknowledged-but-unrecorded batches are
/// idempotently omitted rather than replaying a guessed cursor.
@MainActor
struct CloudRecoveryCoordinator {
    let environment: any CloudSyncEnvironment
    let store: CloudRecoveryStore
    let codec: CloudRecordCodec

    func replace(accountID: String, expectedGeneration: String?, expectedLocalChanges: [String: String]?) async throws {
        if let receipt = try await store.pending() {
            try await resume(receipt)
            return
        }
        try await verifyAccount(accountID)
        let control = try await currentControl()
        try control.requireReady(generation: expectedGeneration ?? control.generation)
        try await store.persistence.validateActivation(accountID: accountID)
        let receipt = try await store.prepare(
            accountID: accountID, scope: environment.scopeIdentifier,
            previousGeneration: control.generation, codec: codec, expectedLocalChanges: expectedLocalChanges)
        try await resume(receipt)
    }

    @discardableResult
    func resumeIfNeeded() async throws -> Bool {
        guard let receipt = try await store.pending() else { return false }
        try await resume(receipt)
        return true
    }

    private func resume(_ receipt: CloudRecoveryStore.Receipt) async throws {
        guard receipt.scope == environment.scopeIdentifier else { throw InitialSyncError.differentStore }
        try await verifyAccount(receipt.accountID)
        let chosen = try receipt.manifest.decodedRecords()
        for record in chosen {
            guard record.recordID.zoneID == codec.zoneID else { throw CloudRecoveryError.invalidReceipt }
            try codec.validateOutgoing(record)
        }
        guard Set(chosen.map(\.recordID)).count == chosen.count else { throw CloudRecoveryError.invalidReceipt }
        let chosenByID = Dictionary(uniqueKeysWithValues: chosen.map { ($0.recordID, $0) })
        var control = try await currentControl()
        if control.generation != receipt.generation {
            guard receipt.phase == .prepared, control.phase == .ready,
                control.generation == receipt.manifest.previousGeneration
            else {
                try await store.supersede(receipt.id)
                throw CloudRecoveryError.generationChanged
            }
            try await environment.ensureZone()
            let claim = try control.changing(generation: receipt.generation, phase: .replacing)
            control = try await send(control: claim, accountID: receipt.accountID)
        }
        if control.phase == .ready {
            guard receipt.phase == .verified else { throw CloudRecoveryError.invalidReceipt }
            try await verifyAccount(receipt.accountID)
            try await store.complete(receipt, codec: codec)
            return
        }

        let before = try await snapshot(accountID: receipt.accountID, generation: receipt.generation)
        // The old cloud copy is retained before the first business deletion.
        if receipt.phase == .prepared || receipt.phase == .publishing {
            try await store.publishing(receipt.id, remoteRecords: before.businessRecords)
        }
        let deletions = before.businessRecords.filter { server in
            chosenByID[server.recordID]?.recordType != server.recordType
        }.map(\.recordID)
        if !deletions.isEmpty {
            control = try await send(control: control, accountID: receipt.accountID, deleting: deletions)
        }
        let deletedIDs = Set(deletions)
        let existing = Dictionary(
            uniqueKeysWithValues: before.businessRecords.filter {
                !deletedIDs.contains($0.recordID)
            }.map { ($0.recordID, $0) })
        let uploads = try chosen.compactMap { record -> CKRecord? in
            if let server = existing[record.recordID],
                try CloudRecoveryManifest.matches(record, server: server, generation: receipt.generation)
            {
                return nil
            }
            return try CloudRecoveryManifest.publicationRecord(
                record, existing: existing[record.recordID],
                generation: receipt.generation)
        }
        if !uploads.isEmpty {
            control = try await send(control: control, accountID: receipt.accountID, saving: uploads)
        }
        let verified = try await snapshot(accountID: receipt.accountID, generation: receipt.generation)
        guard verified.businessRecords.count == chosen.count else { throw CloudRecoveryError.verificationFailed }
        for server in verified.businessRecords {
            guard let original = chosenByID[server.recordID],
                try CloudRecoveryManifest.matches(original, server: server, generation: receipt.generation)
            else { throw CloudRecoveryError.verificationFailed }
        }
        try await store.verified(receipt.id, records: verified.businessRecords)
        let ready = try control.changing(generation: receipt.generation, phase: .ready)
        _ = try await send(control: ready, accountID: receipt.accountID)
        try await verifyAccount(receipt.accountID)
        guard let final = try await store.pending(), final.id == receipt.id else {
            throw CloudRecoveryError.invalidReceipt
        }
        try await store.complete(final, codec: codec)
    }

    private func currentControl() async throws -> CloudSyncControl {
        if let record = try await environment.controlRecord() {
            return try CloudSyncControl(record: record, zone: codec.zoneID)
        }
        return try CloudSyncControl.baseline(in: codec.zoneID)
    }

    private func snapshot(accountID: String, generation: String) async throws -> CloudSyncSnapshot {
        try await verifyAccount(accountID)
        let snapshot = try await environment.snapshot()
        try await verifyAccount(accountID)
        let current = try await currentControl()
        guard current.generation == generation, current.phase == .replacing else {
            throw CloudRecoveryError.generationChanged
        }
        return snapshot
    }

    private func send(
        control: CloudSyncControl, accountID: String, saving: [CKRecord] = [], deleting: [CKRecord.ID] = []
    ) async throws -> CloudSyncControl {
        try await verifyAccount(accountID)
        let session = try GuardedCloudSession(
            environment: environment, accountID: accountID, control: control,
            saving: saving, deleting: deleting)
        let result = try await session.send()
        try await verifyAccount(accountID)
        return result
    }

    private func verifyAccount(_ expected: String) async throws {
        try Task.checkCancellation()
        guard try await environment.accountID() == expected else { throw SyncPersistenceError.accountChanged }
        try Task.checkCancellation()
    }
}
