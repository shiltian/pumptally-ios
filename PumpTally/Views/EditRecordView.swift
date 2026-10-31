import SwiftUI
import SwiftData

struct EditRecordView: View {
    @Bindable var record: FuelingRecord
    let vehicle: Vehicle

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var metricEfficiencyFormatRaw: String

    private var units: UnitSystem { vehicle.unitSystem }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    // Form fields
    @State private var date: Date
    @State private var odometerString: String
    @State private var pricePerFuelUnitMills: Int
    @State private var fuelAmountMills: Int
    @State private var totalCostCents: Int
    @State private var fillUpType: FillUpType
    @State private var notes: String
    @State private var showingSaveError = false

    @FocusState private var focusedField: FuelingRecordFormView.EditableField?

    init(record: FuelingRecord, vehicle: Vehicle) {
        self.record = record
        self.vehicle = vehicle
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
        _date = State(initialValue: record.date)
        // Preserve the exact stored value so editing an unrelated field never
        // rounds an existing fractional odometer reading.
        _odometerString = State(initialValue: record.odometer.editableDecimalString)
        _pricePerFuelUnitMills = State(initialValue: Int(round(record.pricePerFuelUnit * 1000)))
        _fuelAmountMills = State(initialValue: Int(round(record.fuelAmount * 1000)))
        _totalCostCents = State(initialValue: Int(round(record.totalCost * 100)))
        _fillUpType = State(initialValue: record.fillUpType)
        _notes = State(initialValue: record.notes ?? "")
    }

    // Parsed values for validation
    private var currentOdometer: Double? { Double(odometerString) }
    private var pricePerFuelUnit: Double { Double(pricePerFuelUnitMills) / 1000.0 }
    private var fuelAmount: Double { Double(fuelAmountMills) / 1000.0 }
    private var totalCost: Double { Double(totalCostCents) / 100.0 }

    private var chronologyValidation: OdometerChronologyValidation? {
        guard let current = currentOdometer else { return nil }
        return OdometerChronologyValidator.validate(
            date: date,
            odometer: current,
            records: (vehicle.fuelingRecords ?? []).map(OdometerReadingSnapshot.init(record:)),
            originalRecord: OdometerReadingSnapshot(record: record)
        )
    }

    private func isValid(_ validation: OdometerChronologyValidation?) -> Bool {
        guard validation?.isValid == true else { return false }
        guard pricePerFuelUnit > 0 else { return false }
        guard fuelAmount > 0 else { return false }
        guard totalCost > 0 else { return false }
        return true
    }

    var body: some View {
        let validation = chronologyValidation

        NavigationStack {
            Form {
                FuelingRecordFormView(
                    unitSystem: units,
                    metricEfficiencyFormat: metricEfficiencyFormat,
                    date: $date,
                    odometerString: $odometerString,
                    pricePerFuelUnitMills: $pricePerFuelUnitMills,
                    fuelAmountMills: $fuelAmountMills,
                    totalCostCents: $totalCostCents,
                    fillUpType: $fillUpType,
                    notes: $notes,
                    focusedField: $focusedField,
                    previousOdometer: validation?.neighbors.predecessor?.odometer ?? 0,
                    odometerValidationIssue: validation?.issue,
                    showPreview: false
                )
            }
            .navigationTitle("Edit Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .fontWeight(.semibold)
                        .disabled(!isValid(validation))
                }

                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") {
                            focusedField = nil
                            hideKeyboard()
                        }
                    }
                }
            }
            .alert("Unable to Save", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your changes could not be saved. No data was changed. Please try again.")
            }
        }
    }

    private func saveChanges() {
        let validation = chronologyValidation
        guard isValid(validation), let current = currentOdometer else { return }

        do {
            try FuelingRecordPersistenceService.saveEdits(
                to: record,
                in: vehicle,
                context: modelContext
            ) {
                record.date = date
                record.odometer = current
                record.pricePerFuelUnit = pricePerFuelUnit
                record.fuelAmount = fuelAmount
                record.totalCost = totalCost
                record.fillUpType = fillUpType
                record.notes = notes.isEmpty ? nil : notes
                record.modifiedAt = Date()
            }
            dismiss()
        } catch {
            showingSaveError = true
        }
    }
}

#Preview {
    let vehicle = Vehicle(name: "Test Car")
    let record = FuelingRecord(
        odometer: 1000,
        pricePerFuelUnit: 3.459,
        fuelAmount: 12.5,
        totalCost: 43.24,
        vehicle: vehicle
    )

    return EditRecordView(record: record, vehicle: vehicle)
        .modelContainer(for: [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self], inMemory: true)
}
