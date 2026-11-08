import CloudKit
import SwiftData

/// Validates and reconciles incoming data through one implementation. Callers
/// select the full-merge upload policy or the incremental journal/cache boundary.
struct CloudReconciliationService: Sendable {
    struct RemoteApplyResult: Sendable {
        var recordsToUpload: [CKRecord] = []
        var unresolvedChildIDs: [UUID] = []
        var deferredRecordNames: Set<String> = []
        var affectedVehicleIDs: Set<UUID> = []
        var indexedVehicleCount = 0
        var indexedFuelingRecordCount = 0
    }

    private struct LocalIndexes {
        var vehicles: [UUID: Vehicle]
        var records: [UUID: FuelingRecord]
    }

    private let codec: CloudRecordCodec

    init(codec: CloudRecordCodec) { self.codec = codec }

    /// Stages a complete merge without saving or rebuilding caches. Local-only
    /// data is eligible for upload, except where incoming data is quarantined.
    func reconcileMerge(
        vehicleCKRecords: [CKRecord], fuelingCKRecords: [CKRecord], context: ModelContext
    ) throws -> [CKRecord] {
        try stageInitialMerge(
            vehicleCKRecords: vehicleCKRecords, fuelingCKRecords: fuelingCKRecords,
            context: context
        ).recordsToUpload
    }

    /// Returns affected owners as well as uploads so initial enable can commit
    /// cache changes in its own transaction without rebuilding unrelated history.
    func stageInitialMerge(
        vehicleCKRecords: [CKRecord], fuelingCKRecords: [CKRecord], context: ModelContext
    ) throws -> RemoteApplyResult {
        let local = try makeLocalIndexes(context: context)
        var result = try reconcile(
            changedRecords: vehicleCKRecords + fuelingCKRecords,
            deletedRecordIDs: [], local: local, context: context)
        let cloudVehicleNames = Set(vehicleCKRecords.map { $0.recordID.recordName })
        let cloudRecordNames = Set(fuelingCKRecords.map { $0.recordID.recordName })
        var uploads = result.recordsToUpload
        for vehicle in local.vehicles.values where !cloudVehicleNames.contains(vehicle.id.uuidString) {
            uploads.append(codec.vehicleToCKRecord(vehicle))
        }
        for record in local.records.values where !cloudRecordNames.contains(record.id.uuidString) {
            uploads.append(codec.fuelingRecordToCKRecord(record, vehicleRecordID: recordID(for: record.vehicle.id)))
        }
        let blockedVehicles = Set(
            vehicleCKRecords.filter {
                result.deferredRecordNames.contains($0.recordID.recordName)
            }.map { $0.recordID.recordName })
        result.recordsToUpload = uploads.filter { record in
            let owner =
                record.recordType == CloudRecordCodec.RecordType.vehicle
                ? record.recordID.recordName
                : record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String
            return !result.deferredRecordNames.contains(record.recordID.recordName)
                && owner.map { !blockedVehicles.contains($0) } == true
        }
        return result
    }

    /// Stages model changes, durable local winners, and only affected caches.
    /// The caller owns the save so an engine event can commit acknowledgements
    /// and conflict resolution together.
    func stageRemoteChanges(
        changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], context: ModelContext,
        retainedInboxIDs: Set<CKRecord.ID> = []
    ) throws -> RemoteApplyResult {
        let result = try reconcile(
            changedRecords: changedRecords, deletedRecordIDs: deletedRecordIDs,
            local: makeIncrementalIndexes(
                changedRecords: changedRecords, deletedRecordIDs: deletedRecordIDs, context: context),
            context: context, retainedInboxIDs: retainedInboxIDs)
        for record in result.recordsToUpload {
            let type: SyncChangeJournal.RecordType
            switch record.recordType {
            case CloudRecordCodec.RecordType.vehicle: type = .vehicle
            case CloudRecordCodec.RecordType.fuelingRecord: type = .fuelingRecord
            default: continue
            }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName,
                recordType: type, operation: .save, in: context)
        }
        if !result.affectedVehicleIDs.isEmpty {
            context.processPendingChanges()
            let ids = Array(result.affectedVehicleIDs)
            for vehicle in try context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { ids.contains($0.id) })) {
                StatisticsCacheService.refresh(for: vehicle)
            }
        }
        return result
    }

    private func reconcile(
        changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID],
        local: LocalIndexes, context: ModelContext, retainedInboxIDs: Set<CKRecord.ID> = []
    ) throws -> RemoteApplyResult {
        var result = RemoteApplyResult()
        result.indexedVehicleCount = local.vehicles.count
        result.indexedFuelingRecordCount = local.records.count
        var vehicleMap = local.vehicles
        var recordMap = local.records

        for record in changedRecords
        where record.recordType != CloudRecordCodec.RecordType.vehicle
            && record.recordType != CloudRecordCodec.RecordType.fuelingRecord
        {
            try deferRecord(record, retainedInboxIDs: retainedInboxIDs, in: context)
            result.deferredRecordNames.insert(record.recordID.recordName)
        }

        // Parents precede children, including parents inserted in this batch.
        for cloud in changedRecords where cloud.recordType == CloudRecordCodec.RecordType.vehicle {
            let snapshot: CloudSnapshotValidator.VehicleSnapshot
            do {
                snapshot = try CloudSnapshotValidator().validate(vehicleRecords: [cloud], fuelingRecordRecords: [])
                    .vehicles[0]
            } catch {
                try deferRecord(cloud, retainedInboxIDs: retainedInboxIDs, in: context)
                result.deferredRecordNames.insert(cloud.recordID.recordName)
                continue
            }
            if let existing = vehicleMap[snapshot.id] {
                guard existing.unitSystem == snapshot.unitSystem else {
                    try deferRecord(cloud, retainedInboxIDs: retainedInboxIDs, in: context)
                    result.deferredRecordNames.insert(cloud.recordID.recordName)
                    continue
                }
                switch resolveVehicleConflict(cloudRecord: cloud, localVehicle: existing) {
                case .cloud: codec.updateVehicle(existing, from: snapshot)
                case .local: result.recordsToUpload.append(codec.vehicleToCKRecord(existing))
                case .tie: break
                }
            } else {
                let vehicle = codec.vehicle(from: snapshot)
                context.insert(vehicle)
                vehicleMap[snapshot.id] = vehicle
                result.affectedVehicleIDs.insert(snapshot.id)
            }
        }

        for cloud in changedRecords where cloud.recordType == CloudRecordCodec.RecordType.fuelingRecord {
            guard let id = UUID(uuidString: cloud.recordID.recordName), fuelingRecordID(from: cloud) == id else {
                try deferRecord(cloud, retainedInboxIDs: retainedInboxIDs, in: context)
                result.deferredRecordNames.insert(cloud.recordID.recordName)
                continue
            }
            guard let ownerID = parentVehicleID(from: cloud), let owner = vehicleMap[ownerID] else {
                try deferRecord(cloud, retainedInboxIDs: retainedInboxIDs, in: context)
                result.unresolvedChildIDs.append(id)
                result.deferredRecordNames.insert(cloud.recordID.recordName)
                continue
            }
            let snapshot: CloudSnapshotValidator.FuelingRecordSnapshot
            do { snapshot = try codec.decodeFuelingRecord(cloud, owner: owner, existing: recordMap[id]) } catch {
                try deferRecord(cloud, retainedInboxIDs: retainedInboxIDs, in: context)
                result.deferredRecordNames.insert(cloud.recordID.recordName)
                continue
            }
            if let existing = recordMap[id] {
                switch resolveFuelingRecordConflict(cloudRecord: cloud, localRecord: existing) {
                case .cloud:
                    let previous = FuelingRecordValues(record: existing)
                    codec.updateFuelingRecord(existing, from: snapshot)
                    if StatisticsCacheService.invalidateIfNeeded(existing, previous: previous) {
                        result.affectedVehicleIDs.insert(owner.id)
                    }
                case .local:
                    result.recordsToUpload.append(
                        codec.fuelingRecordToCKRecord(
                            existing,
                            vehicleRecordID: recordID(for: existing.vehicle.id)))
                case .tie: break
                }
            } else {
                let record = codec.fuelingRecord(from: snapshot, vehicle: owner)
                context.insert(record)
                recordMap[id] = record
                result.affectedVehicleIDs.insert(owner.id)
            }
        }

        // CloudKit deletions carry no timestamps; the existing policy is delete-wins.
        for deletedID in deletedRecordIDs {
            guard let id = UUID(uuidString: deletedID.recordName) else { continue }
            if let vehicle = vehicleMap[id] {
                context.delete(vehicle)
            } else if let record = recordMap[id] {
                result.affectedVehicleIDs.insert(record.vehicle.id)
                context.delete(record)
            }
        }
        return result
    }

    private func deferRecord(
        _ record: CKRecord, retainedInboxIDs: Set<CKRecord.ID>, in context: ModelContext
    ) throws {
        // Replaying an inbox must keep the original archive, including fields
        // this client cannot interpret. Fresh remote records still get staged.
        guard !retainedInboxIDs.contains(record.recordID) else { return }
        try SyncPersistenceStore.stageInbound(
            .init(
                kind: .modification, recordName: record.recordID.recordName, recordType: record.recordType,
                archivedRecord: try CloudRecordCodec.archiveFullRecord(record)
            ), in: context)
    }

    private func makeLocalIndexes(context: ModelContext) throws -> LocalIndexes {
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        return makeIndexes(vehicles: vehicles, records: records)
    }

    /// Include incoming owners and existing owners: the latter are required to
    /// reject ownership reassignment and rebuild the owner of a deleted child.
    /// Relationships load chronology only if that owner's statistics change.
    private func makeIncrementalIndexes(
        changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], context: ModelContext
    ) throws -> LocalIndexes {
        let deletedIDs = deletedRecordIDs.compactMap { UUID(uuidString: $0.recordName) }
        let recordIDs = Array(
            Set(
                deletedIDs
                    + changedRecords.filter {
                        $0.recordType == CloudRecordCodec.RecordType.fuelingRecord
                    }.compactMap { UUID(uuidString: $0.recordID.recordName) }))
        let records =
            try recordIDs.isEmpty
            ? []
            : context.fetch(
                FetchDescriptor<FuelingRecord>(predicate: #Predicate { recordIDs.contains($0.id) }))
        let vehicleIDs = Array(
            Set(
                deletedIDs
                    + changedRecords.filter {
                        $0.recordType == CloudRecordCodec.RecordType.vehicle
                    }.compactMap { UUID(uuidString: $0.recordID.recordName) }
                    + changedRecords.compactMap(parentVehicleID(from:))
                    + records.map { $0.vehicle.id }))
        let vehicles =
            try vehicleIDs.isEmpty
            ? []
            : context.fetch(
                FetchDescriptor<Vehicle>(predicate: #Predicate { vehicleIDs.contains($0.id) }))
        return makeIndexes(vehicles: vehicles, records: records)
    }

    private func makeIndexes(vehicles: [Vehicle], records: [FuelingRecord]) -> LocalIndexes {
        var vehiclesByID: [UUID: Vehicle] = [:]
        var recordsByID: [UUID: FuelingRecord] = [:]
        for vehicle in vehicles {
            vehiclesByID[vehicle.id] = vehicle
        }
        for record in records {
            recordsByID[record.id] = record
        }
        return LocalIndexes(vehicles: vehiclesByID, records: recordsByID)
    }

    private func fuelingRecordID(from record: CKRecord) -> UUID? {
        guard let idString = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.id] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    private func parentVehicleID(from record: CKRecord) -> UUID? {
        guard let idString = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
    }

    private func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: codec.zoneID)
    }

    private func resolveVehicleConflict(
        cloudRecord: CKRecord,
        localVehicle: Vehicle
    ) -> SyncConflictResolver.Winner {
        SyncConflictResolver.resolve(
            cloudModifiedAt: cloudRecord[CloudRecordCodec.CloudFieldKey.Vehicle.modifiedAt] as? Date,
            cloudCreatedAt: cloudRecord[CloudRecordCodec.CloudFieldKey.Vehicle.createdAt] as? Date,
            localModifiedAt: localVehicle.modifiedAt,
            localCreatedAt: localVehicle.createdAt
        )
    }

    private func resolveFuelingRecordConflict(
        cloudRecord: CKRecord,
        localRecord: FuelingRecord
    ) -> SyncConflictResolver.Winner {
        SyncConflictResolver.resolve(
            cloudModifiedAt: cloudRecord[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] as? Date,
            cloudCreatedAt: cloudRecord[CloudRecordCodec.CloudFieldKey.FuelingRecord.createdAt] as? Date,
            localModifiedAt: localRecord.modifiedAt,
            localCreatedAt: localRecord.createdAt
        )
    }
}
