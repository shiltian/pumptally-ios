import SwiftUI

/// Shared form sections used by both AddRecordView and EditRecordView.
/// This eliminates duplication of the date, odometer, fuel, fill-up type,
/// preview, and notes sections.
struct FuelingRecordFormView: View {
    let unitSystem: UnitSystem
    let storageUnit: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    @Binding var draft: FuelingRecordDraft

    var focusedField: FocusState<EditableField?>.Binding

    /// Previous odometer reading — zero means first record, hides distance/preview
    var previousOdometer: Double = 0

    /// Chronology error produced by the shared validator, if any.
    var odometerValidationIssue: OdometerChronologyIssue?

    /// Whether to show the preview section (AddRecordView uses it, EditRecordView does not)
    var showPreview: Bool = true

    typealias EditableField = FuelingRecordDraft.Field

    private var currentOdometer: Double? { draft.odometer }
    private var fuelAmount: Double { draft.fuelAmount }
    private var totalCost: Double { draft.totalCost }

    private func numericBinding(_ field: EditableField) -> Binding<Int> {
        Binding(get: { draft.input(for: field) }, set: { draft.edit(field, input: $0) })
    }

    private var previewEfficiency: Double? {
        guard showPreview, draft.fillUpType == .full, let current = currentOdometer, fuelAmount > 0 else { return nil }
        let distance = current - previousOdometer
        guard distance > 0 else { return nil }
        return unitSystem.efficiencyDisplayValue(
            from: distance / fuelAmount,
            metricFormat: metricEfficiencyFormat
        )
    }

    private var previewCostPerDistance: Double? {
        guard showPreview, let current = currentOdometer, totalCost > 0 else { return nil }
        let distance = current - previousOdometer
        guard distance > 0 else { return nil }
        return totalCost / distance
    }

    var body: some View {
        dateSection
        odometerSection
        fuelSection
        if showPreview {
            previewSection
        }
        fillUpTypeSection
        notesSection
    }

    // MARK: - Date Section

    private var dateSection: some View {
        Section {
            DatePicker("Date & Time", selection: $draft.date, in: ...Date())
                .font(.appBody)
        } header: {
            Text("When")
                .font(.appCaption)
        }
    }

    // MARK: - Odometer Section

    private var odometerSection: some View {
        Section {
            HStack {
                Text("Odometer Reading")
                    .font(.appBody)
                Spacer()
                TextField(unitSystem.distanceUnit, text: $draft.odometerString)
                    .accessibilityIdentifier("fueling.odometer")
                    .font(.appBody)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }

            if showPreview,
               previousOdometer > 0,
               let current = currentOdometer,
               current > previousOdometer {
                HStack {
                    Text("\(unitSystem.distanceName) This Trip")
                        .font(.appBody)
                        .foregroundColor(.teal)
                    Spacer()
                    Text((current - previousOdometer).formatted(.number.precision(.fractionLength(0))))
                        .font(.appBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.teal)
                }
            }
        } header: {
            Text("Odometer")
                .font(.appCaption)
        } footer: {
            if let odometerValidationIssue {
                odometerValidationMessage(for: odometerValidationIssue)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private func odometerValidationMessage(for issue: OdometerChronologyIssue) -> some View {
        switch issue {
        case .invalidReading:
            Text("Odometer must be greater than zero.")
        case .notGreaterThanPredecessor(let predecessor):
            Text(
                "Odometer must be greater than the previous reading (\(unitSystem.distanceValue(predecessor.odometer, from: storageUnit).formatted(.number.precision(.fractionLength(0...2)))) \(unitSystem.distanceUnit))."
            )
        case .notLessThanSuccessor(let successor):
            Text(
                "Odometer must be less than the next reading (\(unitSystem.distanceValue(successor.odometer, from: storageUnit).formatted(.number.precision(.fractionLength(0...2)))) \(unitSystem.distanceUnit))."
            )
        }
    }

    // MARK: - Fuel Section

    private var fuelSection: some View {
        Section {
            HStack {
                Text(unitSystem.pricePerFuelLabel)
                    .font(.appBody)
                Spacer()
                Text("$")
                    .foregroundColor(.secondary)
                CurrencyInputField(
                    value: numericBinding(.pricePerFuelUnit),
                    decimalPlaces: 3,
                    width: 100,
                    accessibilityIdentifier: "fueling.price"
                )
                .focused(focusedField, equals: .pricePerFuelUnit)
            }

            HStack {
                Text(unitSystem.fuelName)
                    .font(.appBody)
                Spacer()
                CurrencyInputField(
                    value: numericBinding(.fuelAmount),
                    decimalPlaces: 3,
                    width: 100,
                    accessibilityIdentifier: "fueling.fuel"
                )
                .focused(focusedField, equals: .fuelAmount)
                Text(unitSystem.fuelUnit)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Total Cost")
                    .font(.appBody)
                Spacer()
                Text("$")
                    .foregroundColor(.secondary)
                CurrencyInputField(
                    value: numericBinding(.totalCost),
                    decimalPlaces: 2,
                    width: 100,
                    accessibilityIdentifier: "fueling.cost"
                )
                .focused(focusedField, equals: .totalCost)
            }
        } header: {
            Text("Fuel Details")
                .font(.appCaption)
        } footer: {
            Text("Enter any 2 fields and the third will be calculated automatically")
                .font(.appCaption)
        }
    }

    // MARK: - Preview Section

    @ViewBuilder
    private var previewSection: some View {
        if previousOdometer > 0, previewEfficiency != nil || previewCostPerDistance != nil {
            Section {
                if let efficiency = previewEfficiency {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .foregroundColor(.purple)
                        Text("Estimated \(unitSystem.efficiencyUnit(for: metricEfficiencyFormat))")
                            .font(.appBody)
                        Spacer()
                        Text("\(efficiency.formatted(.number.precision(.fractionLength(1)))) \(unitSystem.efficiencyUnit(for: metricEfficiencyFormat))")
                            .font(.appBody)
                            .fontWeight(.semibold)
                            .foregroundColor(.purple)
                    }
                }

                if let cpd = previewCostPerDistance {
                    HStack {
                        Image(systemName: "dollarsign.circle")
                            .foregroundColor(.orange)
                        Text(unitSystem.costPerDistanceLabel)
                            .font(.appBody)
                        Spacer()
                        Text(cpd.currencyFormatted)
                            .font(.appBody)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Preview")
                    .font(.appCaption)
            }
        }
    }

    // MARK: - Fill-Up Type Section

    private var fillUpTypeSection: some View {
        Section {
            Picker("Fill-up Type", selection: $draft.fillUpType) {
                ForEach(FillUpType.allCases, id: \.self) { type in
                    HStack {
                        Image(systemName: type.icon)
                            .foregroundColor(type.color)
                        Text(type.displayName)
                    }
                    .tag(type)
                }
            }
            .font(.appBody)
            .pickerStyle(.menu)
        } footer: {
            Text(draft.fillUpType.description)
                .font(.appCaption)
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        Section {
            TextField("Add notes (optional)", text: $draft.notes, axis: .vertical)
                .accessibilityIdentifier("fueling.notes")
                .font(.appBody)
                .lineLimit(3...6)
        } header: {
            Text("Notes")
                .font(.appCaption)
        }
    }

}
