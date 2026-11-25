import Foundation

/// The preceding interval in storage units, including the baseline information
/// required by the same efficiency policy used for persisted statistics.
struct FuelingIntervalContext: Sendable {
    let odometer: Double
    let fillUpType: FillUpType
    let isFirstRecord: Bool

    init(odometer: Double, fillUpType: FillUpType, isFirstRecord: Bool) {
        self.odometer = odometer
        self.fillUpType = fillUpType
        self.isFirstRecord = isFirstRecord
    }
}

/// The editor captures live history once when its query updates. Draft edits
/// reuse the readings, and only chronology inputs can invalidate validation.
@MainActor
final class FuelingRecordEditorHistory {
    private struct Input: Equatable {
        let date: Date
        let odometer: Double
        let original: OdometerReadingSnapshot?
    }

    private let readings: [OdometerReadingSnapshot]
    private let fillUpTypes: [UUID: FillUpType]
    private let firstRecordID: UUID?
    private var lastValidation: (input: Input, result: OdometerChronologyValidation)?

    init(records: [FuelingRecord]) {
        var readings: [OdometerReadingSnapshot] = []
        var fillUpTypes: [UUID: FillUpType] = [:]
        readings.reserveCapacity(records.count)
        fillUpTypes.reserveCapacity(records.count)
        for record in records {
            let reading = OdometerReadingSnapshot(record: record)
            readings.append(reading)
            if fillUpTypes[reading.id] == nil { fillUpTypes[reading.id] = record.fillUpType }
        }
        self.readings = readings
        self.fillUpTypes = fillUpTypes
        firstRecordID = readings.min(by: OdometerChronologyValidator.areInIncreasingOrder)?.id
    }

    func validate(date: Date, odometer: Double?, original: OdometerReadingSnapshot? = nil)
        -> OdometerChronologyValidation?
    {
        guard let odometer else { return nil }
        let input = Input(date: date, odometer: odometer, original: original)
        if let lastValidation, lastValidation.input == input { return lastValidation.result }
        let result = OdometerChronologyValidator.validate(
            date: date, odometer: odometer, records: readings, originalRecord: original)
        lastValidation = (input, result)
        return result
    }

    func interval(for validation: OdometerChronologyValidation?) -> FuelingIntervalContext? {
        guard let validation, validation.isValid, let predecessor = validation.neighbors.predecessor,
            let fillUpType = fillUpTypes[predecessor.id]
        else { return nil }
        return FuelingIntervalContext(
            odometer: predecessor.odometer, fillUpType: fillUpType, isFirstRecord: firstRecordID == predecessor.id)
    }
}

/// Value-only preview in display units. Views format these results without
/// defining a second interpretation of interval eligibility.
struct FuelingRecordPreview: Equatable, Sendable {
    let distanceDriven: Double
    let efficiency: Double?
    let costPerDistance: Double?

    init?(
        values: FuelingRecordValues, previous: FuelingIntervalContext,
        storageUnit: UnitSystem, displayUnit: UnitSystem
    ) {
        let distance = values.odometer - previous.odometer
        guard previous.odometer > 0, distance.isFinite, distance > 0 else { return nil }
        distanceDriven = displayUnit.distanceValue(distance, from: storageUnit)
        efficiency = FuelEfficiencyPolicy.rawEfficiency(
            distanceDriven: distance, fuelAmount: values.fuelAmount, currentFillUpType: values.fillUpType,
            previousFillUpType: previous.fillUpType, previousIsFirstRecord: previous.isFirstRecord
        ).map { displayUnit.efficiencyValue($0, from: storageUnit) }
        costPerDistance =
            values.totalCost > 0
            ? displayUnit.costPerDistanceValue(values.totalCost / distance, from: storageUnit) : nil
    }
}
