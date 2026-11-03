import CloudKit
import Foundation

/// Owns the CloudKit wire contract and conversion between CKRecords and runtime models.
///
/// The field names and record types in this file are compatibility-critical: CloudKit
/// has no rollback, and released app versions continue to read and write these values.
struct CloudRecordCodec: Sendable {
    typealias RecordType = CloudRecordType

    enum CloudFieldKey {
        enum Vehicle {
            static let id = "vehicleID"
            static let name = "name"
            static let make = "make"
            static let model = "model"
            static let year = "year"
            static let unitSystemRaw = "unitSystemRaw"
            static let displayUnitSystemRaw = "displayUnitSystemRaw"
            static let createdAt = "vehicleCreatedAt"
            static let modifiedAt = "vehicleModifiedAt"
        }

        enum FuelingRecord {
            static let id = "fuelingRecordID"
            static let date = "date"
            static let odometer = "odometer"
            static let pricePerFuelUnit = "pricePerFuelUnit"
            static let fuelAmount = "fuelAmount"
            static let totalCost = "totalCost"
            static let fillUpTypeRaw = "fillUpTypeRaw"
            static let notes = "notes"
            static let createdAt = "fuelingCreatedAt"
            static let modifiedAt = "fuelingModifiedAt"
            static let vehicleRef = "vehicleOwnerID"
            static let measurements = "measurementsV1"
        }
    }

    /// Archives the complete record for the durable inbound-change inbox.
    static func archiveFullRecord(_ record: CKRecord) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
    }

    /// Decodes a complete record archive. `CKRecord(coder:)` is reserved for
    /// records encoded with `encodeSystemFields(with:)`, which stores metadata
    /// fields directly rather than archiving a CKRecord root object.
    static func unarchiveFullRecord(from data: Data) throws -> CKRecord? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }

    let zoneID: CKRecordZone.ID

    func validateOutgoing(_ record: CKRecord) throws {
        if record.recordType == RecordType.vehicle {
            _ = try CloudSnapshotValidator().validate(vehicleRecords: [record], fuelingRecordRecords: [])
        } else if record.recordType == RecordType.fuelingRecord {
            guard let data = record[CloudFieldKey.FuelingRecord.measurements] as? Data,
                let payload = try? JSONDecoder().decode(CloudMeasurementPayload.self, from: data),
                let unit = UnitSystem(rawValue: payload.unitSystemRaw)
            else {
                throw CloudMeasurementPayload.ValidationError.malformedRecord
            }
            _ = try CloudMeasurementPayload.validate(record, storageUnit: unit)
        }
    }

    /// Convert a Vehicle model to its exact CloudKit representation.
    func vehicleToCKRecord(_ vehicle: Vehicle, existingRecord: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: vehicle.id.uuidString, zoneID: zoneID)
        let record = existingRecord ?? CKRecord(recordType: RecordType.vehicle, recordID: recordID)

        record[CloudFieldKey.Vehicle.id] = vehicle.id.uuidString
        record[CloudFieldKey.Vehicle.name] = vehicle.name
        record[CloudFieldKey.Vehicle.make] = vehicle.make
        record[CloudFieldKey.Vehicle.model] = vehicle.model
        record[CloudFieldKey.Vehicle.year] = vehicle.year as? CKRecordValue
        record[CloudFieldKey.Vehicle.unitSystemRaw] = vehicle.unitSystemRaw
        record[CloudFieldKey.Vehicle.displayUnitSystemRaw] = vehicle.displayUnitSystemRaw
        record[CloudFieldKey.Vehicle.createdAt] = vehicle.createdAt
        record[CloudFieldKey.Vehicle.modifiedAt] = vehicle.modifiedAt

        return record
    }

    /// Runtime models are constructed only from validated snapshots.
    func vehicle(from snapshot: CloudSnapshotValidator.VehicleSnapshot) -> Vehicle {
        let vehicle = Vehicle(
            id: snapshot.id, name: snapshot.name, make: snapshot.make,
            model: snapshot.model, year: snapshot.year, createdAt: snapshot.createdAt,
            unitSystem: snapshot.unitSystem
        )
        vehicle.modifiedAt = snapshot.modifiedAt
        vehicle.displayUnitSystemRaw = snapshot.displayUnitSystemRaw
        return vehicle
    }

    func updateVehicle(_ vehicle: Vehicle, from snapshot: CloudSnapshotValidator.VehicleSnapshot) {
        vehicle.name = snapshot.name
        vehicle.make = snapshot.make
        vehicle.model = snapshot.model
        vehicle.year = snapshot.year
        // A legacy storage-unit change is resolved at the compatibility boundary.
        // Display preferences never change the basis of existing measurements.
        vehicle.displayUnitSystemRaw = snapshot.displayUnitSystemRaw ?? vehicle.displayUnitSystemRaw
        vehicle.modifiedAt = snapshot.modifiedAt
    }

    /// Convert a FuelingRecord model to its exact CloudKit representation.
    func fuelingRecordToCKRecord(
        _ fuelingRecord: FuelingRecord,
        vehicleRecordID: CKRecord.ID,
        existingRecord: CKRecord? = nil
    ) -> CKRecord {
        let recordID = CKRecord.ID(recordName: fuelingRecord.id.uuidString, zoneID: zoneID)
        let record = existingRecord ?? CKRecord(recordType: RecordType.fuelingRecord, recordID: recordID)

        record[CloudFieldKey.FuelingRecord.id] = fuelingRecord.id.uuidString
        record[CloudFieldKey.FuelingRecord.date] = fuelingRecord.date
        record[CloudFieldKey.FuelingRecord.odometer] = fuelingRecord.odometer
        record[CloudFieldKey.FuelingRecord.pricePerFuelUnit] = fuelingRecord.pricePerFuelUnit
        record[CloudFieldKey.FuelingRecord.fuelAmount] = fuelingRecord.fuelAmount
        record[CloudFieldKey.FuelingRecord.totalCost] = fuelingRecord.totalCost
        record[CloudFieldKey.FuelingRecord.fillUpTypeRaw] = fuelingRecord.fillUpTypeRaw
        record[CloudFieldKey.FuelingRecord.notes] = fuelingRecord.notes
        record[CloudFieldKey.FuelingRecord.createdAt] = fuelingRecord.createdAt
        record[CloudFieldKey.FuelingRecord.modifiedAt] = fuelingRecord.modifiedAt

        // Stored as a plain string to preserve the existing wire format and avoid
        // CloudKit's owning-reference limit.
        record[CloudFieldKey.FuelingRecord.vehicleRef] = vehicleRecordID.recordName
        record[CloudFieldKey.FuelingRecord.measurements] = try? JSONEncoder().encode(
            CloudMeasurementPayload(record: fuelingRecord))

        return record
    }

    /// The same structural, ownership, and unit boundary serves incremental
    /// changes, initial merge, and recovery assessment.
    func decodeFuelingRecord(
        _ record: CKRecord, owner: Vehicle, existing: FuelingRecord?
    ) throws -> CloudSnapshotValidator.FuelingRecordSnapshot {
        guard existing == nil || existing?.vehicle.id == owner.id else {
            throw CloudSnapshotValidator.ValidationError.invalidFuelingRecord(record.recordID.recordName)
        }
        let normalized = try CloudMeasurementPayload.validate(
            record, storageUnit: owner.unitSystem, existing: existing
        ).applying(to: record, storageUnit: owner.unitSystem)
        return try CloudSnapshotValidator().validateFuelingRecords(from: [normalized], vehicleIDs: [owner.id])[0]
    }

    func fuelingRecord(
        from snapshot: CloudSnapshotValidator.FuelingRecordSnapshot,
        vehicle: Vehicle
    ) -> FuelingRecord {
        let record = FuelingRecord(
            id: snapshot.id, date: snapshot.date, odometer: snapshot.odometer,
            pricePerFuelUnit: snapshot.pricePerFuelUnit, fuelAmount: snapshot.fuelAmount,
            totalCost: snapshot.totalCost, fillUpType: snapshot.fillUpType,
            notes: snapshot.notes, createdAt: snapshot.createdAt, vehicle: vehicle
        )
        record.modifiedAt = snapshot.modifiedAt
        return record
    }

    func updateFuelingRecord(_ record: FuelingRecord, from snapshot: CloudSnapshotValidator.FuelingRecordSnapshot) {
        record.date = snapshot.date
        record.odometer = snapshot.odometer
        record.pricePerFuelUnit = snapshot.pricePerFuelUnit
        record.fuelAmount = snapshot.fuelAmount
        record.totalCost = snapshot.totalCost
        record.fillUpType = snapshot.fillUpType
        record.notes = snapshot.notes
        record.modifiedAt = snapshot.modifiedAt
    }
}
