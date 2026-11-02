import CloudKit
import Foundation

/// Decodes and validates a complete CloudKit snapshot before local replacement begins.
///
/// Validation is intentionally strict because replacement deletes the current local
/// store after this succeeds. No SwiftData model is touched by this type.
struct CloudSnapshotValidator {
    struct VehicleSnapshot: Sendable {
        let id: UUID
        let name: String
        let make: String?
        let model: String?
        let year: Int?
        let createdAt: Date
        let modifiedAt: Date?
        let unitSystem: UnitSystem
        let displayUnitSystemRaw: String?
    }

    struct FuelingRecordSnapshot: Sendable {
        let id: UUID
        let date: Date
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpType: FillUpType
        let notes: String?
        let createdAt: Date
        let modifiedAt: Date?
        let vehicleID: UUID
    }

    struct Snapshot: Sendable {
        let vehicles: [VehicleSnapshot]
        let fuelingRecords: [FuelingRecordSnapshot]
    }

    enum ValidationError: LocalizedError {
        case invalidVehicleRecord(String)
        case duplicateVehicle(UUID)
        case invalidFuelingRecord(String)
        case duplicateFuelingRecord(UUID)
        case missingVehicle(recordID: UUID, vehicleID: UUID)

        var errorDescription: String? {
            switch self {
            case .invalidVehicleRecord(let recordName):
                return "Cloud vehicle \(recordName) is incomplete or malformed."
            case .duplicateVehicle(let id):
                return "Cloud data contains duplicate vehicle \(id.uuidString)."
            case .invalidFuelingRecord(let recordName):
                return "Cloud fueling record \(recordName) is incomplete or malformed."
            case .duplicateFuelingRecord(let id):
                return "Cloud data contains duplicate fueling record \(id.uuidString)."
            case .missingVehicle(let recordID, let vehicleID):
                return "Cloud fueling record \(recordID.uuidString) references missing vehicle \(vehicleID.uuidString)."
            }
        }
    }

    func validate(
        vehicleRecords: [CKRecord],
        fuelingRecordRecords: [CKRecord]
    ) throws -> Snapshot {
        let vehicles = try validatedVehicleSnapshots(from: vehicleRecords)
        let vehicleIDs = Set(vehicles.map(\.id))
        let units = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.id, $0.unitSystem) })
        for record in fuelingRecordRecords {
            if let parent = record[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String,
                let id = UUID(uuidString: parent), let unit = units[id]
            {
                let payload = try CloudMeasurementPayload.validate(
                    record, storageUnit: unit, allowsLegacySnapshot: true)
                guard payload.unitSystemRaw == unit.rawValue else {
                    throw ValidationError.invalidFuelingRecord(record.recordID.recordName)
                }
            }
        }
        let fuelingRecords = try validateFuelingRecords(
            from: fuelingRecordRecords,
            vehicleIDs: vehicleIDs
        )
        return Snapshot(vehicles: vehicles, fuelingRecords: fuelingRecords)
    }

    private func validatedVehicleSnapshots(
        from records: [CKRecord]
    ) throws -> [VehicleSnapshot] {
        typealias Field = CloudRecordCodec.CloudFieldKey.Vehicle

        var seenIDs: Set<UUID> = []
        var snapshots: [VehicleSnapshot] = []
        snapshots.reserveCapacity(records.count)

        for record in records {
            let recordName = record.recordID.recordName
            guard record.recordType == CloudRecordCodec.RecordType.vehicle,
                  let idString = record[Field.id] as? String,
                  let id = UUID(uuidString: idString),
                  let recordNameID = UUID(uuidString: recordName),
                  id == recordNameID,
                  let name = record[Field.name] as? String,
                  let unitSystemRaw = record[Field.unitSystemRaw] as? String,
                  let unitSystem = UnitSystem(rawValue: unitSystemRaw),
                  let createdAt = record[Field.createdAt] as? Date else {
                throw ValidationError.invalidVehicleRecord(recordName)
            }

            guard seenIDs.insert(id).inserted else {
                throw ValidationError.duplicateVehicle(id)
            }

            snapshots.append(VehicleSnapshot(
                id: id,
                name: name,
                make: try optionalValue(
                    record[Field.make],
                    as: String.self,
                    invalidError: ValidationError.invalidVehicleRecord(recordName)
                ),
                model: try optionalValue(
                    record[Field.model],
                    as: String.self,
                    invalidError: ValidationError.invalidVehicleRecord(recordName)
                ),
                year: try optionalValue(
                    record[Field.year],
                    as: Int.self,
                    invalidError: ValidationError.invalidVehicleRecord(recordName)
                ),
                createdAt: createdAt,
                modifiedAt: try optionalValue(
                    record[Field.modifiedAt],
                    as: Date.self,
                    invalidError: ValidationError.invalidVehicleRecord(recordName)
                ),
                    unitSystem: unitSystem,
                    displayUnitSystemRaw: record[Field.displayUnitSystemRaw] as? String
            ))
        }

        return snapshots
    }

    /// Validates record structure independently of measurement wire versions.
    /// Recovery assessment uses the same checks as snapshot replacement.
    func validateFuelingRecords(
        from records: [CKRecord],
        vehicleIDs: Set<UUID>
    ) throws -> [FuelingRecordSnapshot] {
        typealias Field = CloudRecordCodec.CloudFieldKey.FuelingRecord

        var seenIDs: Set<UUID> = []
        var snapshots: [FuelingRecordSnapshot] = []
        snapshots.reserveCapacity(records.count)

        for record in records {
            let recordName = record.recordID.recordName
            guard record.recordType == CloudRecordCodec.RecordType.fuelingRecord,
                  let idString = record[Field.id] as? String,
                  let id = UUID(uuidString: idString),
                  let recordNameID = UUID(uuidString: recordName),
                  id == recordNameID,
                  let date = record[Field.date] as? Date,
                  let odometer = record[Field.odometer] as? Double,
                  odometer.isFinite,
                  let pricePerFuelUnit = record[Field.pricePerFuelUnit] as? Double,
                  pricePerFuelUnit.isFinite,
                  let fuelAmount = record[Field.fuelAmount] as? Double,
                  fuelAmount.isFinite,
                  let totalCost = record[Field.totalCost] as? Double,
                  totalCost.isFinite,
                  let fillUpTypeRaw = record[Field.fillUpTypeRaw] as? String,
                  let fillUpType = FillUpType(rawValue: fillUpTypeRaw),
                  let createdAt = record[Field.createdAt] as? Date,
                  let vehicleIDString = record[Field.vehicleRef] as? String,
                  let vehicleID = UUID(uuidString: vehicleIDString) else {
                throw ValidationError.invalidFuelingRecord(recordName)
            }

            guard seenIDs.insert(id).inserted else {
                throw ValidationError.duplicateFuelingRecord(id)
            }
            guard vehicleIDs.contains(vehicleID) else {
                throw ValidationError.missingVehicle(recordID: id, vehicleID: vehicleID)
            }

            snapshots.append(FuelingRecordSnapshot(
                id: id,
                date: date,
                odometer: odometer,
                pricePerFuelUnit: pricePerFuelUnit,
                fuelAmount: fuelAmount,
                totalCost: totalCost,
                fillUpType: fillUpType,
                notes: try optionalValue(
                    record[Field.notes],
                    as: String.self,
                    invalidError: ValidationError.invalidFuelingRecord(recordName)
                ),
                createdAt: createdAt,
                modifiedAt: try optionalValue(
                    record[Field.modifiedAt],
                    as: Date.self,
                    invalidError: ValidationError.invalidFuelingRecord(recordName)
                ),
                vehicleID: vehicleID
            ))
        }

        return snapshots
    }

    private func optionalValue<T>(
        _ value: CKRecordValue?,
        as type: T.Type,
        invalidError: Error
    ) throws -> T? {
        guard let value else { return nil }
        guard let typedValue = value as? T else { throw invalidError }
        return typedValue
    }
}
