import CloudKit
import SwiftData

/// Applies CloudKit records to SwiftData while preserving the distinct contracts
/// of initial merge and incremental pull.
@MainActor
struct CloudReconciliationService {
    struct RemoteApplyResult {
        var recordsToUpload: [CKRecord] = []
        var unresolvedChildIDs: [UUID] = []
    }

    private struct LocalIndexes {
        var vehicles: [UUID: Vehicle]
        var records: [UUID: FuelingRecord]
    }

    private let codec: CloudRecordCodec

    init(codec: CloudRecordCodec) {
        self.codec = codec
    }

    /// Initial full merge. Mutates the context in memory and returns records that
    /// must be uploaded, but deliberately does not save or rebuild caches.
    func reconcileMerge(
        vehicleCKRecords: [CKRecord],
        fuelingCKRecords: [CKRecord],
        context: ModelContext
    ) throws -> [CKRecord] {
        let local = try makeLocalIndexes(context: context)
        var cloudVehicleMap: [UUID: CKRecord] = [:]
        var ckRecordIDToVehicle: [CKRecord.ID: Vehicle] = [:]
        var recordsToUpload: [CKRecord] = []

        for ckRecord in vehicleCKRecords {
            guard let uuid = vehicleID(from: ckRecord) else { continue }
            cloudVehicleMap[uuid] = ckRecord

            if let localVehicle = local.vehicles[uuid] {
                switch resolveVehicleConflict(cloudRecord: ckRecord, localVehicle: localVehicle) {
                case .cloud:
                    codec.updateVehicle(localVehicle, from: ckRecord)
                case .local:
                    recordsToUpload.append(codec.vehicleToCKRecord(localVehicle))
                case .tie:
                    break
                }
                ckRecordIDToVehicle[ckRecord.recordID] = localVehicle
            } else {
                let vehicle = codec.vehicleFromCKRecord(ckRecord)
                context.insert(vehicle)
                ckRecordIDToVehicle[ckRecord.recordID] = vehicle
            }
        }

        // Full merge uploads local-only vehicles. Incremental pull intentionally
        // does not scan unrelated local data.
        for (uuid, vehicle) in local.vehicles where cloudVehicleMap[uuid] == nil {
            let ckRecord = codec.vehicleToCKRecord(vehicle)
            recordsToUpload.append(ckRecord)
            ckRecordIDToVehicle[ckRecord.recordID] = vehicle
        }

        var vehicleByUUID: [UUID: Vehicle] = [:]
        for vehicle in ckRecordIDToVehicle.values {
            vehicleByUUID[vehicle.id] = vehicle
        }

        var cloudRecordMap: [UUID: CKRecord] = [:]
        for ckRecord in fuelingCKRecords {
            guard let uuid = fuelingRecordID(from: ckRecord) else { continue }
            cloudRecordMap[uuid] = ckRecord

            if let localRecord = local.records[uuid] {
                switch resolveFuelingRecordConflict(cloudRecord: ckRecord, localRecord: localRecord) {
                case .cloud:
                    codec.updateFuelingRecord(localRecord, from: ckRecord)
                case .local:
                    recordsToUpload.append(codec.fuelingRecordToCKRecord(
                        localRecord,
                        vehicleRecordID: recordID(for: localRecord.vehicle.id)
                    ))
                case .tie:
                    break
                }
            } else if let vehicleUUID = parentVehicleID(from: ckRecord),
                      let vehicle = local.vehicles[vehicleUUID] ?? vehicleByUUID[vehicleUUID] {
                context.insert(codec.fuelingRecordFromCKRecord(ckRecord, vehicle: vehicle))
            }
            // Full merge preserves the current behavior of silently skipping a
            // cloud-only child whose parent cannot be resolved.
        }

        // Full merge uploads local-only fueling records.
        for (uuid, record) in local.records where cloudRecordMap[uuid] == nil {
            recordsToUpload.append(codec.fuelingRecordToCKRecord(
                record,
                vehicleRecordID: recordID(for: record.vehicle.id)
            ))
        }

        return recordsToUpload
    }

    /// Incremental delta apply. This method deliberately owns its save and forced
    /// cache rebuild, preserving the existing direct-call persistence contract.
    func applyRemoteChanges(
        changedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        context: ModelContext
    ) throws -> RemoteApplyResult {
        var result = RemoteApplyResult()
        let local = try makeLocalIndexes(context: context)
        var vehicleMap = local.vehicles
        var recordMap = local.records

        // Pass 1: vehicles first so children in the same change window can resolve.
        for ckRecord in changedRecords where ckRecord.recordType == CloudRecordCodec.RecordType.vehicle {
            guard let uuid = vehicleID(from: ckRecord) else { continue }

            if let existing = vehicleMap[uuid] {
                switch resolveVehicleConflict(cloudRecord: ckRecord, localVehicle: existing) {
                case .cloud:
                    codec.updateVehicle(existing, from: ckRecord)
                case .local:
                    result.recordsToUpload.append(codec.vehicleToCKRecord(existing))
                case .tie:
                    break
                }
            } else {
                let vehicle = codec.vehicleFromCKRecord(ckRecord)
                context.insert(vehicle)
                vehicleMap[uuid] = vehicle
            }
        }

        // Pass 2: fueling records after all changed parent vehicles.
        for ckRecord in changedRecords where ckRecord.recordType == CloudRecordCodec.RecordType.fuelingRecord {
            guard let uuid = fuelingRecordID(from: ckRecord) else { continue }

            if let existing = recordMap[uuid] {
                switch resolveFuelingRecordConflict(cloudRecord: ckRecord, localRecord: existing) {
                case .cloud:
                    codec.updateFuelingRecord(existing, from: ckRecord)
                case .local:
                    result.recordsToUpload.append(codec.fuelingRecordToCKRecord(
                        existing,
                        vehicleRecordID: recordID(for: existing.vehicle.id)
                    ))
                case .tie:
                    break
                }
            } else if let vehicleUUID = parentVehicleID(from: ckRecord),
                      let vehicle = vehicleMap[vehicleUUID] {
                let record = codec.fuelingRecordFromCKRecord(ckRecord, vehicle: vehicle)
                context.insert(record)
                recordMap[uuid] = record
            } else {
                result.unresolvedChildIDs.append(uuid)
            }
        }

        // Existing policy is delete-wins because CloudKit deletion events do not
        // include timestamps and this schema intentionally has no tombstones.
        for deletedID in deletedRecordIDs {
            guard let uuid = UUID(uuidString: deletedID.recordName) else { continue }
            if let vehicle = vehicleMap[uuid] {
                context.delete(vehicle)
            } else if let record = recordMap[uuid] {
                context.delete(record)
            }
        }

        // Keep a local winner durable until CloudKit acknowledges it. Queue it
        // before saving the reconciled models so a crash cannot leave the local
        // winner persisted without the corresponding upload request.
        for record in result.recordsToUpload {
            let recordType: SyncChangeJournal.RecordType
            switch record.recordType {
            case CloudRecordCodec.RecordType.vehicle:
                recordType = .vehicle
            case CloudRecordCodec.RecordType.fuelingRecord:
                recordType = .fuelingRecord
            default:
                continue
            }
            try SyncChangeJournal.enqueue(
                recordName: record.recordID.recordName,
                recordType: recordType,
                operation: .save,
                in: context
            )
        }

        try context.save()
        StatisticsCacheService.rebuildCacheForAllVehicles(in: context, force: true)
        return result
    }

    private func makeLocalIndexes(context: ModelContext) throws -> LocalIndexes {
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
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

    private func vehicleID(from record: CKRecord) -> UUID? {
        guard let idString = record[CloudRecordCodec.CloudFieldKey.Vehicle.id] as? String else {
            return nil
        }
        return UUID(uuidString: idString)
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
