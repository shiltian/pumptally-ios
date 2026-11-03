import Foundation

/// Editable business values, independent of a model context and its lifetime.
struct FuelingRecordValues: Equatable, Sendable {
    var date: Date
    var odometer: Double
    var pricePerFuelUnit: Double
    var fuelAmount: Double
    var totalCost: Double
    var fillUpType: FillUpType
    var notes: String?

    init(record: FuelingRecord) {
        date = record.date
        odometer = record.odometer
        pricePerFuelUnit = record.pricePerFuelUnit
        fuelAmount = record.fuelAmount
        totalCost = record.totalCost
        fillUpType = record.fillUpType
        notes = record.notes
    }

    init(
        date: Date, odometer: Double, pricePerFuelUnit: Double,
        fuelAmount: Double, totalCost: Double, fillUpType: FillUpType, notes: String?
    ) {
        self.date = date
        self.odometer = odometer
        self.pricePerFuelUnit = pricePerFuelUnit
        self.fuelAmount = fuelAmount
        self.totalCost = totalCost
        self.fillUpType = fillUpType
        self.notes = notes
    }

    func converted(from source: UnitSystem, to target: UnitSystem) -> Self {
        var result = self
        result.odometer = target.distanceValue(odometer, from: source)
        result.fuelAmount = target.fuelValue(fuelAmount, from: source)
        result.pricePerFuelUnit = target.priceValue(pricePerFuelUnit, from: source)
        return result
    }
}

enum FuelingRecordEditingError: LocalizedError, Equatable {
    case invalidInput
    case recordChanged
    case recordUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return String(localized: "Enter valid odometer, price, fuel, and cost values.")
        case .recordChanged:
            return String(
                localized: "This record changed while you were editing. Reopen it to review the latest values.")
        case .recordUnavailable:
            return String(localized: "This vehicle or record is no longer available.")
        }
    }
}

/// A field-level, optimistic update. Unedited fields come from the current
/// record, so a notes edit cannot overwrite measurements received during editing.
struct FuelingRecordUpdate: Sendable {
    let original: FuelingRecordValues
    let proposed: FuelingRecordValues
    var storageUnit: UnitSystem? = nil

    var isEmpty: Bool { original == proposed }

    func merging(into current: FuelingRecordValues) throws -> FuelingRecordValues {
        func merge<Value: Equatable>(
            _ keyPath: KeyPath<FuelingRecordValues, Value>
        ) throws -> Value {
            let old = original[keyPath: keyPath]
            let new = proposed[keyPath: keyPath]
            let latest = current[keyPath: keyPath]
            guard old != new else { return latest }
            guard latest == old || latest == new else {
                throw FuelingRecordEditingError.recordChanged
            }
            return new
        }

        return try FuelingRecordValues(
            date: merge(\.date), odometer: merge(\.odometer),
            pricePerFuelUnit: merge(\.pricePerFuelUnit), fuelAmount: merge(\.fuelAmount),
            totalCost: merge(\.totalCost), fillUpType: merge(\.fillUpType), notes: merge(\.notes)
        )
    }
}

/// The form owns a draft; formatted input never becomes the original data.
struct FuelingRecordDraft: Sendable {
    enum Field: CaseIterable, Sendable {
        case pricePerFuelUnit, fuelAmount, totalCost

        var decimalPlaces: Int { self == .totalCost ? 2 : 3 }
    }

    private struct NumericInput: Sendable {
        let original: Double
        let scale: Int
        let initialInput: Int
        var input: Int

        init(value: Double, decimalPlaces: Int) {
            original = value
            scale = decimalPlaces == 2 ? 100 : 1000
            initialInput = Int(exactly: (value * Double(scale)).rounded()) ?? 0
            input = initialInput
        }

        var value: Double {
            input == initialInput ? original : Double(input) / Double(scale)
        }
    }

    private let original: FuelingRecordValues?
    let storageUnit: UnitSystem
    let inputUnit: UnitSystem
    private var numericInputs: [Field: NumericInput]
    private var editedFields: [Field] = []
    private(set) var calculationIsValid = true

    var date: Date
    var odometerString: String
    var fillUpType: FillUpType
    var notes: String

    init(date: Date = Date(), storageUnit: UnitSystem = .imperial, inputUnit: UnitSystem = .imperial) {
        original = nil
        self.storageUnit = storageUnit
        self.inputUnit = inputUnit
        self.date = date
        odometerString = ""
        fillUpType = .full
        notes = ""
        numericInputs = Dictionary(
            uniqueKeysWithValues: Field.allCases.map {
                ($0, NumericInput(value: 0, decimalPlaces: $0.decimalPlaces))
            })
    }

    init(
        values storedValues: FuelingRecordValues, storageUnit: UnitSystem = .imperial, inputUnit: UnitSystem = .imperial
    ) {
        self.storageUnit = storageUnit
        self.inputUnit = inputUnit
        let values = storedValues.converted(from: storageUnit, to: inputUnit)
        original = storedValues
        date = values.date
        odometerString = values.odometer.editableDecimalString
        fillUpType = values.fillUpType
        notes = values.notes ?? ""
        numericInputs = [
            .pricePerFuelUnit: NumericInput(value: values.pricePerFuelUnit, decimalPlaces: 3),
            .fuelAmount: NumericInput(value: values.fuelAmount, decimalPlaces: 3),
            .totalCost: NumericInput(value: values.totalCost, decimalPlaces: 2),
        ]
    }

    var odometer: Double? { Double(odometerString) }
    var storageOdometer: Double? { odometer.map { storageUnit.distanceValue($0, from: inputUnit) } }
    var pricePerFuelUnit: Double { value(for: .pricePerFuelUnit) }
    var fuelAmount: Double { value(for: .fuelAmount) }
    var totalCost: Double { value(for: .totalCost) }

    var isValid: Bool {
        guard calculationIsValid, original != nil || editedFields.count == 2,
            let values = try? proposedValues()
        else { return false }
        return FuelingRecordValidation.isValid(values, preserving: original)
    }

    func input(for field: Field) -> Int { numericInputs[field]!.input }
    func value(for field: Field) -> Double { numericInputs[field]!.value }

    mutating func edit(_ field: Field, input: Int) {
        guard input != self.input(for: field) else { return }
        numericInputs[field]!.input = input
        editedFields.removeAll { $0 == field }
        editedFields.append(field)
        editedFields = Array(editedFields.suffix(2))
        calculationIsValid = true
        calculateRemainingField()
    }

    func makeValues() throws -> FuelingRecordValues {
        guard isValid else { throw FuelingRecordEditingError.invalidInput }
        return try proposedValues()
    }

    func preview(after previous: FuelingIntervalContext?) -> FuelingRecordPreview? {
        guard let previous, let values = try? proposedValues() else { return nil }
        return FuelingRecordPreview(
            values: values, previous: previous,
            storageUnit: storageUnit, displayUnit: inputUnit)
    }

    private func proposedValues() throws -> FuelingRecordValues {
        guard let odometer else { throw FuelingRecordEditingError.invalidInput }
        let savedNotes = notes == (original?.notes ?? "") ? original?.notes : (notes.isEmpty ? nil : notes)
        let displayed = FuelingRecordValues(
            date: date, odometer: odometer, pricePerFuelUnit: pricePerFuelUnit,
            fuelAmount: fuelAmount, totalCost: totalCost, fillUpType: fillUpType, notes: savedNotes)
        var result = displayed.converted(from: inputUnit, to: storageUnit)
        if let original {
            let baseline = original.converted(from: storageUnit, to: inputUnit)
            if displayed.odometer == baseline.odometer { result.odometer = original.odometer }
            if displayed.fuelAmount == baseline.fuelAmount { result.fuelAmount = original.fuelAmount }
            if displayed.pricePerFuelUnit == baseline.pricePerFuelUnit {
                result.pricePerFuelUnit = original.pricePerFuelUnit
            }
        }
        return result
    }

    func makeUpdate() throws -> FuelingRecordUpdate {
        guard let original else { throw FuelingRecordEditingError.invalidInput }
        return try FuelingRecordUpdate(original: original, proposed: makeValues(), storageUnit: storageUnit)
    }

    private mutating func calculateRemainingField() {
        guard editedFields.count == 2,
            let target = Field.allCases.first(where: { !editedFields.contains($0) }),
            editedFields.allSatisfy({ value(for: $0) > 0 })
        else { return }

        // Decimal arithmetic and a single rounding boundary avoid recursive
        // binding updates and repeated binary floating-point rounding.
        let operands = editedFields.compactMap {
            Decimal(string: String(value(for: $0)), locale: Locale(identifier: "en_US_POSIX"))
        }
        guard operands.count == 2, operands.allSatisfy({ !$0.isNaN }) else {
            calculationIsValid = false
            return
        }
        let numbers = Dictionary(uniqueKeysWithValues: zip(editedFields, operands))
        var calculated: Decimal
        switch target {
        case .pricePerFuelUnit: calculated = numbers[.totalCost]! / numbers[.fuelAmount]!
        case .fuelAmount: calculated = numbers[.totalCost]! / numbers[.pricePerFuelUnit]!
        case .totalCost: calculated = numbers[.pricePerFuelUnit]! * numbers[.fuelAmount]!
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &calculated, target.decimalPlaces, .plain)
        let scaled = rounded * Decimal(numericInputs[target]!.scale)
        guard !scaled.isNaN, scaled >= 0, scaled <= 999_999_999 else {
            calculationIsValid = false
            return
        }
        numericInputs[target]!.input = NSDecimalNumber(decimal: scaled).intValue
    }
}
