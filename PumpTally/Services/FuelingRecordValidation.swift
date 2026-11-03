import Foundation

/// Business validation shared by drafts, local commands and imports. Existing
/// values are preserved when untouched, so editing notes never repairs history.
enum FuelingRecordValidation {
    static func isValid(_ values: FuelingRecordValues, preserving original: FuelingRecordValues? = nil) -> Bool {
        (original?.date == values.date || values.date.timeIntervalSince1970.isFinite)
            && (original?.odometer == values.odometer || (values.odometer.isFinite && values.odometer > 0))
            && (original?.pricePerFuelUnit == values.pricePerFuelUnit
                || (values.pricePerFuelUnit.isFinite && values.pricePerFuelUnit >= 0))
            && (original?.fuelAmount == values.fuelAmount || (values.fuelAmount.isFinite && values.fuelAmount > 0))
            && (original?.totalCost == values.totalCost || (values.totalCost.isFinite && values.totalCost >= 0))
    }

    static func validate(_ values: FuelingRecordValues, preserving original: FuelingRecordValues? = nil) throws {
        guard isValid(values, preserving: original) else { throw FuelingRecordEditingError.invalidInput }
    }
}
