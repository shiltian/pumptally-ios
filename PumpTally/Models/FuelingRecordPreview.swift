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

    @MainActor
    init?(validation: OdometerChronologyValidation?, records: [FuelingRecord]) {
        guard let validation, validation.isValid, let predecessor = validation.neighbors.predecessor,
            let previous = records.first(where: { $0.id == predecessor.id })
        else { return nil }
        self.init(
            odometer: previous.odometer, fillUpType: previous.fillUpType,
            isFirstRecord: records.min(by: OdometerChronologyValidator.areInIncreasingOrder)?.id == previous.id)
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
