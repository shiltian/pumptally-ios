import CloudKit
import Foundation

/// An additive wire version. Legacy scalar fields remain readable by released
/// clients; agreement with this payload detects a legacy writer's later edits.
struct CloudMeasurementPayload: Codable, Equatable {
    let version: Int
    let unitSystemRaw: String
    let odometer: Double
    let pricePerFuelUnit: Double
    let fuelAmount: Double
    let totalCost: Double

    enum ValidationError: LocalizedError {
        case malformedRecord
        case unresolvedUnits
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .malformedRecord:
                return String(
                    localized: "An iCloud record is incomplete. Its original data has been kept for diagnosis.")
            case .unresolvedUnits:
                return String(
                    localized:
                        "Measurements from an older app need unit confirmation. Update your other devices or review the pending changes."
                )
            case .unsupportedVersion:
                return String(
                    localized:
                        "This iCloud record uses an unsupported measurement format. Update PumpTally before syncing it."
                )
            }
        }
    }

    init(record: FuelingRecord) {
        version = 1
        unitSystemRaw = record.vehicle.unitSystemRaw
        odometer = record.odometer
        pricePerFuelUnit = record.pricePerFuelUnit
        fuelAmount = record.fuelAmount
        totalCost = record.totalCost
    }

    private init(record: CKRecord, unit: UnitSystem) throws {
        typealias Field = CloudRecordCodec.CloudFieldKey.FuelingRecord
        guard let odometer = record[Field.odometer] as? Double, odometer.isFinite,
            let price = record[Field.pricePerFuelUnit] as? Double, price.isFinite,
            let fuel = record[Field.fuelAmount] as? Double, fuel.isFinite,
            let cost = record[Field.totalCost] as? Double, cost.isFinite,
            let id = record[Field.id] as? String, UUID(uuidString: id) == UUID(uuidString: record.recordID.recordName),
            UUID(uuidString: id) != nil,
            record[Field.date] is Date, record[Field.createdAt] is Date,
            let rawType = record[Field.fillUpTypeRaw] as? String, FillUpType(rawValue: rawType) != nil,
            let parent = record[Field.vehicleRef] as? String, UUID(uuidString: parent) != nil
        else {
            throw ValidationError.malformedRecord
        }
        version = 1
        unitSystemRaw = unit.rawValue
        self.odometer = odometer
        pricePerFuelUnit = price
        fuelAmount = fuel
        totalCost = cost
    }

    static func validate(
        _ record: CKRecord, storageUnit: UnitSystem, existing: FuelingRecord? = nil,
        allowsLegacySnapshot: Bool = false
    ) throws -> CloudMeasurementPayload {
        let field = CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements
        if let value = record[field] {
            guard let data = value as? Data else { throw ValidationError.malformedRecord }
            let payload = try JSONDecoder().decode(Self.self, from: data)
            guard payload.version == 1 else { throw ValidationError.unsupportedVersion }
            guard let source = UnitSystem(rawValue: payload.unitSystemRaw) else {
                throw ValidationError.malformedRecord
            }
            guard payload == (try Self(record: record, unit: source)) else {
                throw ValidationError.unresolvedUnits
            }
            return payload
        }
        let payload = try Self(record: record, unit: storageUnit)
        let unchangedMeasurements =
            existing.map {
                $0.odometer == payload.odometer && $0.pricePerFuelUnit == payload.pricePerFuelUnit
                    && $0.fuelAmount == payload.fuelAmount && $0.totalCost == payload.totalCost
            } ?? false
        guard allowsLegacySnapshot || unchangedMeasurements else { throw ValidationError.unresolvedUnits }
        return payload
    }

    /// Used only after explicit unit confirmation in the review screen.
    static func confirmedLegacyRecord(_ record: CKRecord, unit: UnitSystem) throws -> CKRecord {
        let payload = try Self(record: record, unit: unit)
        let result = record.copy() as! CKRecord
        result[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = try JSONEncoder().encode(payload)
        return result
    }

    func applying(to record: CKRecord, storageUnit: UnitSystem) throws -> CKRecord {
        // Validation has established the enum value. Transform the known source
        // into the existing local storage basis, never the display preference.
        let source = UnitSystem(rawValue: unitSystemRaw)!
        let result = record.copy() as! CKRecord
        typealias Field = CloudRecordCodec.CloudFieldKey.FuelingRecord
        let distance = storageUnit.distanceValue(odometer, from: source)
        let price = storageUnit.priceValue(pricePerFuelUnit, from: source)
        let fuel = storageUnit.fuelValue(fuelAmount, from: source)
        guard distance.isFinite, price.isFinite, fuel.isFinite else { throw ValidationError.malformedRecord }
        result[Field.odometer] = distance
        result[Field.pricePerFuelUnit] = price
        result[Field.fuelAmount] = fuel
        result[Field.totalCost] = totalCost
        return result
    }
}
