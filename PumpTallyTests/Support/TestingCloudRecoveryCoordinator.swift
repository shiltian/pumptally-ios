import CloudKit
import SwiftData

/// Exercises guarded publication while released clients prevent running it in production.
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

extension CloudRecoveryStore {
    func prepare(
        accountID: String, scope: String, previousGeneration: String,
        codec: CloudRecordCodec, expectedLocalChanges: [String: String]? = nil
    ) async throws -> Receipt {
        try await persistence.transaction { actor in
            let context = actor.modelContext
            try Self.requireNoPendingRecovery(in: context)
            if let expectedLocalChanges,
                try InitialSyncProposal.localChanges(in: context) != expectedLocalChanges
            {
                throw InitialSyncError.localDataChanged
            }
            let records = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: context)
            let manifest = try CloudRecoveryManifest(
                version: 1, previousGeneration: previousGeneration,
                records: records.map(CloudRecordCodec.archiveFullRecord),
                journal: context.fetch(FetchDescriptor<SyncChange>()).map {
                    .init(
                        key: $0.key, recordName: $0.recordName, recordType: $0.recordTypeRaw,
                        operation: $0.operationRaw, generation: $0.generation, createdAt: $0.createdAt,
                        origin: $0.originRaw)
                },
                inbox: Self.inbox(in: context))
            let receipt = CloudRecoveryReceipt(
                id: UUID(), scope: scope, accountID: accountID,
                payload: try JSONEncoder().encode(manifest))
            context.insert(receipt)
            return try Self.value(receipt)
        }
    }

    func publishing(_ id: UUID, remoteRecords: [CKRecord]) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw == Phase.prepared.rawValue || receipt.phaseRaw == Phase.publishing.rawValue else {
                throw CloudRecoveryError.invalidReceipt
            }
            // Capture the old cloud values before any destructive business batch.
            if receipt.remoteBackup == nil {
                receipt.remoteBackup = try JSONEncoder().encode(remoteRecords.map(CloudRecordCodec.archiveFullRecord))
            }
            receipt.phaseRaw = Phase.publishing.rawValue
        }
    }

    func verified(_ id: UUID, records: [CKRecord]) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw == Phase.publishing.rawValue || receipt.phaseRaw == Phase.verified.rawValue else {
                throw CloudRecoveryError.invalidReceipt
            }
            receipt.verifiedRecords = try JSONEncoder().encode(records.map(CloudRecordCodec.archiveFullRecord))
            receipt.phaseRaw = Phase.verified.rawValue
        }
    }

    func supersede(_ id: UUID) async throws {
        try await persistence.transaction { actor in
            let receipt = try Self.model(id, in: actor.modelContext)
            guard receipt.phaseRaw != Phase.completed.rawValue else { throw CloudRecoveryError.invalidReceipt }
            receipt.phaseRaw = Phase.superseded.rawValue
        }
    }

    func complete(_ receipt: Receipt, codec: CloudRecordCodec) async throws {
        guard let records = receipt.verifiedRecords else { throw CloudRecoveryError.invalidReceipt }
        try await persistence.activate(accountID: receipt.accountID, generation: receipt.generation) { actor in
            let context = actor.modelContext
            let model = try Self.model(receipt.id, in: context)
            guard model.phaseRaw == Phase.verified.rawValue else { throw CloudRecoveryError.invalidReceipt }
            for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) { context.delete(metadata) }
            for record in records { try SyncPersistenceStore.stageSystemFields(from: record, in: context) }
            // All old-session callbacks were drained before the receipt was made.
            // Preserve any remaining original bytes before removing replay work.
            model.retainedInbox = try JSONEncoder().encode(Self.inbox(in: context))
            for entry in try context.fetch(FetchDescriptor<PendingRemoteChange>()) { context.delete(entry) }
            for entry in receipt.manifest.journal {
                try SyncChangeJournal.remove(key: entry.key, generation: entry.generation, in: context)
            }
            model.phaseRaw = Phase.completed.rawValue
        }
    }

    nonisolated private static func inbox(in context: ModelContext) throws -> [CloudRecoveryManifest.InboxEntry] {
        try context.fetch(FetchDescriptor<PendingRemoteChange>()).map { .init(key: $0.key, data: $0.recordData) }
    }

    nonisolated private static func model(_ id: UUID, in context: ModelContext) throws -> CloudRecoveryReceipt {
        guard
            let receipt = try context.fetch(
                FetchDescriptor<CloudRecoveryReceipt>(predicate: #Predicate { $0.id == id })
            ).first
        else {
            throw CloudRecoveryError.invalidReceipt
        }
        return receipt
    }
}

extension InitialSyncReconciler {
    func uploadSnapshot(in context: ModelContext) throws -> [CKRecord] {
        var records: [CKRecord] = []
        for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) {
            let parent = codec.vehicleToCKRecord(vehicle)
            records.append(parent)
            for child in vehicle.fuelingRecords ?? [] {
                records.append(codec.fuelingRecordToCKRecord(child, vehicleRecordID: parent.recordID))
            }
        }
        for record in records { try codec.validateOutgoing(record) }
        return records
    }
}

extension CloudRecoveryManifest {
    func decodedRecords() throws -> [CKRecord] {
        guard version == 1 else { throw CloudRecoveryError.invalidReceipt }
        return try records.map {
            guard let record = try CloudRecordCodec.unarchiveFullRecord(from: $0) else {
                throw CloudRecoveryError.invalidReceipt
            }
            return record
        }
    }

    /// Overlay known business fields on current system fields. Unknown additive
    /// fields survive; omitted optional business fields are explicitly cleared.
    static func publicationRecord(_ chosen: CKRecord, existing: CKRecord?, generation: String) throws -> CKRecord {
        guard existing == nil || existing?.recordType == chosen.recordType else {
            throw CloudRecoveryError.verificationFailed
        }
        let result =
            existing?.copy() as? CKRecord
            ?? CKRecord(recordType: chosen.recordType, recordID: chosen.recordID)
        for key in try businessFields(for: chosen.recordType) { result[key] = chosen[key] }
        result[CloudSyncControl.businessGenerationField] = generation
        return result
    }

    static func matches(_ chosen: CKRecord, server: CKRecord, generation: String) throws -> Bool {
        guard chosen.recordID == server.recordID, chosen.recordType == server.recordType,
            server[CloudSyncControl.businessGenerationField] as? String == generation
        else { return false }
        for key in try businessFields(for: chosen.recordType) {
            let lhs = chosen[key]
            let rhs = server[key]
            switch (lhs, rhs) {
            case (nil, nil): break
            case (let lhs as Date, let rhs as Date):
                // CloudKit's wire timestamp uses the Unix epoch. Converting
                // epochs may change a Date's reference-epoch least-significant
                // bit without changing its representable wire instant.
                guard lhs.timeIntervalSince1970.bitPattern == rhs.timeIntervalSince1970.bitPattern else { return false }
            case (let lhs as Data, let rhs as Data):
                if key == CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements {
                    // JSON key order is not part of the measurement contract.
                    // Malformed server data is a mismatch to repair, never a
                    // reason to substitute or weaken the trusted source.
                    let expected = try JSONDecoder().decode(CloudMeasurementPayload.self, from: lhs)
                    guard let actual = try? JSONDecoder().decode(CloudMeasurementPayload.self, from: rhs),
                        expected == actual
                    else { return false }
                } else {
                    guard lhs == rhs else { return false }
                }
            case (let lhs as String, let rhs as String):
                guard lhs == rhs else { return false }
            case (let lhs as NSNumber, let rhs as NSNumber):
                if key == CloudRecordCodec.CloudFieldKey.Vehicle.year {
                    guard lhs.int64Value == rhs.int64Value else { return false }
                } else {
                    guard lhs.doubleValue.bitPattern == rhs.doubleValue.bitPattern else { return false }
                }
            default: return false
            }
        }
        return true
    }

    private static func businessFields(for type: String) throws -> [String] {
        switch type {
        case CloudRecordCodec.RecordType.vehicle:
            typealias F = CloudRecordCodec.CloudFieldKey.Vehicle
            return [
                F.id, F.name, F.make, F.model, F.year, F.unitSystemRaw, F.displayUnitSystemRaw, F.createdAt,
                F.modifiedAt,
            ]
        case CloudRecordCodec.RecordType.fuelingRecord:
            typealias F = CloudRecordCodec.CloudFieldKey.FuelingRecord
            return [
                F.id, F.date, F.odometer, F.pricePerFuelUnit, F.fuelAmount, F.totalCost, F.fillUpTypeRaw,
                F.notes, F.createdAt, F.modifiedAt, F.vehicleRef, F.measurements,
            ]
        default: throw CloudRecoveryError.invalidReceipt
        }
    }
}
