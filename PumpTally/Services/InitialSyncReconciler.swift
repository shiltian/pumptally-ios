import CloudKit
import SwiftData

/// Stages initial business values, journal intent, system fields and caches.
/// The persistence store owns the single commit; this type never saves or awaits.
struct InitialSyncReconciler: Sendable {
    let codec: CloudRecordCodec

    enum Plan: Sendable {
        case merge(CloudSyncSnapshot)
        case useCloud(CloudSyncSnapshot, CloudSnapshotValidator.Snapshot)
    }

    func stage(_ plan: Plan, in context: ModelContext) throws {
        switch plan {
        case .merge(let snapshot):
            try stageMerge(snapshot, in: context)
        case .useCloud(let source, let validated):
            try stageReplacement(validated, in: context)
            for record in source.vehicles + source.fuelingRecords {
                try SyncPersistenceStore.stageSystemFields(from: record, in: context)
            }
        }
    }

    func stageMerge(_ snapshot: CloudSyncSnapshot, in context: ModelContext) throws {
        guard snapshot.otherRecords.isEmpty else {
            throw CloudSyncAdapterError.unsupportedRecordType(snapshot.otherRecords[0].recordType)
        }
        let deletions = try context.fetch(FetchDescriptor<SyncChange>()).filter { $0.operationRaw == "delete" }
        let deletedNames = Set(deletions.map(\.recordName))
        let result = try CloudReconciliationService(codec: codec).stageInitialMerge(
            vehicleCKRecords: snapshot.vehicles, fuelingCKRecords: snapshot.fuelingRecords, context: context)
        let affectedByDeletion = try applyConfirmedDeletions(deletions, in: context)
        try stageUploads(result.recordsToUpload.filter { !deletedNames.contains($0.recordID.recordName) }, in: context)
        for record in snapshot.vehicles + snapshot.fuelingRecords {
            try SyncPersistenceStore.stageSystemFields(from: record, in: context)
        }
        try consumeSupersededInbox(snapshot, deferredNames: result.deferredRecordNames, in: context)
        try rebuildCaches(affected: result.affectedVehicleIDs.union(affectedByDeletion), in: context)
    }

    /// A complete, fresh read supersedes earlier deliveries of records it
    /// successfully reconciled. Unreadable, unmatched and deferred work stays.
    private func consumeSupersededInbox(
        _ snapshot: CloudSyncSnapshot, deferredNames: Set<String>, in context: ModelContext
    ) throws {
        let accepted = Set(
            (snapshot.vehicles + snapshot.fuelingRecords)
                .filter { !deferredNames.contains($0.recordID.recordName) }
                .map { "\($0.recordType):\($0.recordID.recordName)" })
        for pending in try context.fetch(FetchDescriptor<PendingRemoteChange>()) {
            guard let payload = try? SyncPersistenceStore.PendingPayload.decode(pending.recordData),
                accepted.contains("\(payload.recordType):\(payload.recordName)")
            else { continue }
            context.delete(pending)
        }
    }

    func stageReplacement(_ snapshot: CloudSnapshotValidator.Snapshot, in context: ModelContext) throws {
        for change in try context.fetch(FetchDescriptor<SyncChange>()) { context.delete(change) }
        for pending in try context.fetch(FetchDescriptor<PendingRemoteChange>()) { context.delete(pending) }
        for metadata in try context.fetch(FetchDescriptor<CloudRecordMetadata>()) { context.delete(metadata) }
        for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) { context.delete(vehicle) }
        context.processPendingChanges()

        var vehicles: [UUID: Vehicle] = [:]
        for value in snapshot.vehicles {
            let vehicle = codec.vehicle(from: value)
            context.insert(vehicle)
            vehicles[value.id] = vehicle
        }
        for value in snapshot.fuelingRecords {
            guard let vehicle = vehicles[value.vehicleID] else {
                throw CloudSnapshotValidator.ValidationError.missingVehicle(
                    recordID: value.id, vehicleID: value.vehicleID)
            }
            context.insert(codec.fuelingRecord(from: value, vehicle: vehicle))
        }
        context.processPendingChanges()
        for vehicle in vehicles.values { StatisticsCacheService.recalculateAllStatistics(for: vehicle) }
    }

    func stageUploads(_ records: [CKRecord], in context: ModelContext) throws {
        // Validate all values before staging any intent.
        for record in records { try codec.validateOutgoing(record) }
        for record in records {
            guard let type = SyncChangeJournal.RecordType(rawValue: record.recordType) else {
                throw CloudSyncAdapterError.unsupportedRecordType(record.recordType)
            }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName, recordType: type, operation: .save, in: context)
        }
    }

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

    private func applyConfirmedDeletions(_ deletions: [SyncChange], in context: ModelContext) throws -> Set<UUID> {
        let confirmed = deletions.filter { $0.originRaw != nil }
        let vehicleNames = confirmed.filter { $0.recordTypeRaw == CloudRecordCodec.RecordType.vehicle }.map(
            \.recordName)
        let recordNames = confirmed.filter { $0.recordTypeRaw == CloudRecordCodec.RecordType.fuelingRecord }.map(
            \.recordName)
        let vehicleIDs = vehicleNames.compactMap(UUID.init(uuidString:))
        let recordIDs = recordNames.compactMap(UUID.init(uuidString:))
        var affected: Set<UUID> = []
        for record in try context.fetch(
            FetchDescriptor<FuelingRecord>(predicate: #Predicate { recordIDs.contains($0.id) }))
        {
            affected.insert(record.vehicle.id)
            context.delete(record)
        }
        for vehicle in try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { vehicleIDs.contains($0.id) }))
        {
            // Include valid children discovered after the device deleted their
            // parent, so the local cascade also has durable cloud intent.
            for child in vehicle.fuelingRecords ?? [] where !recordIDs.contains(child.id) {
                try SyncChangeJournal.enqueue(child, operation: .delete, in: context)
            }
            context.delete(vehicle)
        }
        context.processPendingChanges()
        return affected
    }

    private func rebuildCaches(affected: Set<UUID>, in context: ModelContext) throws {
        context.processPendingChanges()
        for vehicle in try context.fetch(FetchDescriptor<Vehicle>())
        where affected.contains(vehicle.id) || vehicle.needsCacheRebuild {
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        }
    }
}
