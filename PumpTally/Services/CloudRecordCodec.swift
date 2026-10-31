import CloudKit
import Foundation

/// Owns the CloudKit wire contract and conversion between CKRecords and runtime models.
///
/// The field names and record types in this file are compatibility-critical: CloudKit
/// has no rollback, and released app versions continue to read and write these values.
struct CloudRecordCodec {
    enum RecordType {
        static let vehicle = "Vehicle"
        static let fuelingRecord = "FuelingRecord"
    }

    enum CloudFieldKey {
        enum Vehicle {
            static let id = "vehicleID"
            static let name = "name"
            static let make = "make"
            static let model = "model"
            static let year = "year"
            static let unitSystemRaw = "unitSystemRaw"
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
        record[CloudFieldKey.Vehicle.createdAt] = vehicle.createdAt
        record[CloudFieldKey.Vehicle.modifiedAt] = vehicle.modifiedAt

        return record
    }

    /// Convert a CloudKit vehicle record to a runtime model.
    func vehicleFromCKRecord(_ ckRecord: CKRecord) -> Vehicle {
        let id = UUID(uuidString: ckRecord[CloudFieldKey.Vehicle.id] as? String ?? "") ?? UUID()
        let name = ckRecord[CloudFieldKey.Vehicle.name] as? String ?? ""
        let make = ckRecord[CloudFieldKey.Vehicle.make] as? String
        let model = ckRecord[CloudFieldKey.Vehicle.model] as? String
        let year = ckRecord[CloudFieldKey.Vehicle.year] as? Int
        let unitSystemRaw = ckRecord[CloudFieldKey.Vehicle.unitSystemRaw] as? String ?? UnitSystem.imperial.rawValue
        let createdAt = ckRecord[CloudFieldKey.Vehicle.createdAt] as? Date ?? Date()

        let vehicle = Vehicle(
            id: id,
            name: name,
            make: make,
            model: model,
            year: year,
            createdAt: createdAt,
            unitSystem: UnitSystem(rawValue: unitSystemRaw) ?? .imperial
        )
        vehicle.modifiedAt = ckRecord[CloudFieldKey.Vehicle.modifiedAt] as? Date
        return vehicle
    }

    /// Apply a CloudKit vehicle payload to an existing runtime model.
    func updateVehicle(_ vehicle: Vehicle, from ckRecord: CKRecord) {
        vehicle.name = ckRecord[CloudFieldKey.Vehicle.name] as? String ?? vehicle.name
        vehicle.make = ckRecord[CloudFieldKey.Vehicle.make] as? String
        vehicle.model = ckRecord[CloudFieldKey.Vehicle.model] as? String
        vehicle.year = ckRecord[CloudFieldKey.Vehicle.year] as? Int
        vehicle.unitSystemRaw = ckRecord[CloudFieldKey.Vehicle.unitSystemRaw] as? String ?? vehicle.unitSystemRaw
        vehicle.modifiedAt = ckRecord[CloudFieldKey.Vehicle.modifiedAt] as? Date
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

        return record
    }

    /// Convert a CloudKit fueling record to a runtime model.
    func fuelingRecordFromCKRecord(
        _ ckRecord: CKRecord,
        vehicle: Vehicle
    ) -> FuelingRecord {
        let id = UUID(uuidString: ckRecord[CloudFieldKey.FuelingRecord.id] as? String ?? "") ?? UUID()
        let date = ckRecord[CloudFieldKey.FuelingRecord.date] as? Date ?? Date()
        let odometer = ckRecord[CloudFieldKey.FuelingRecord.odometer] as? Double ?? 0
        let pricePerFuelUnit = ckRecord[CloudFieldKey.FuelingRecord.pricePerFuelUnit] as? Double ?? 0
        let fuelAmount = ckRecord[CloudFieldKey.FuelingRecord.fuelAmount] as? Double ?? 0
        let totalCost = ckRecord[CloudFieldKey.FuelingRecord.totalCost] as? Double ?? 0
        let fillUpTypeRaw = ckRecord[CloudFieldKey.FuelingRecord.fillUpTypeRaw] as? String ?? FillUpType.full.rawValue
        let notes = ckRecord[CloudFieldKey.FuelingRecord.notes] as? String
        let createdAt = ckRecord[CloudFieldKey.FuelingRecord.createdAt] as? Date ?? Date()

        let record = FuelingRecord(
            id: id,
            date: date,
            odometer: odometer,
            pricePerFuelUnit: pricePerFuelUnit,
            fuelAmount: fuelAmount,
            totalCost: totalCost,
            fillUpType: FillUpType(rawValue: fillUpTypeRaw) ?? .full,
            notes: notes,
            createdAt: createdAt,
            vehicle: vehicle
        )
        record.modifiedAt = ckRecord[CloudFieldKey.FuelingRecord.modifiedAt] as? Date
        return record
    }

    /// Apply a CloudKit fueling payload to an existing runtime model.
    func updateFuelingRecord(_ record: FuelingRecord, from ckRecord: CKRecord) {
        record.date = ckRecord[CloudFieldKey.FuelingRecord.date] as? Date ?? record.date
        record.odometer = ckRecord[CloudFieldKey.FuelingRecord.odometer] as? Double ?? record.odometer
        record.pricePerFuelUnit = ckRecord[CloudFieldKey.FuelingRecord.pricePerFuelUnit] as? Double ?? record.pricePerFuelUnit
        record.fuelAmount = ckRecord[CloudFieldKey.FuelingRecord.fuelAmount] as? Double ?? record.fuelAmount
        record.totalCost = ckRecord[CloudFieldKey.FuelingRecord.totalCost] as? Double ?? record.totalCost
        record.fillUpTypeRaw = ckRecord[CloudFieldKey.FuelingRecord.fillUpTypeRaw] as? String ?? record.fillUpTypeRaw
        record.notes = ckRecord[CloudFieldKey.FuelingRecord.notes] as? String
        record.modifiedAt = ckRecord[CloudFieldKey.FuelingRecord.modifiedAt] as? Date
    }
}
