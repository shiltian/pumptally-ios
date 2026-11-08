import SwiftUI
import SwiftData

struct FuelingRecordEditSelection: Identifiable, Sendable {
    let id: UUID
    let values: FuelingRecordValues
    let storageUnit: UnitSystem

    @MainActor
    init(record: FuelingRecord) {
        id = record.id
        values = FuelingRecordValues(record: record)
        storageUnit = record.vehicle.unitSystem
    }

    init(record: FuelingHistoryRecord) {
        id = record.id
        values = record.values
        storageUnit = record.storageUnit
    }
}

struct EditRecordView: View {
    let selection: FuelingRecordEditSelection
    let vehicle: Vehicle
    let records: [FuelingRecord]

    @State private var isSaving = false
    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var metricEfficiencyFormatRaw: String

    private var units: UnitSystem { draft.inputUnit }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    @State private var draft: FuelingRecordDraft
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""

    @FocusState private var focusedField: FuelingRecordFormView.EditableField?

    init(selection: FuelingRecordEditSelection, vehicle: Vehicle, records: [FuelingRecord]) {
        self.selection = selection
        self.records = records
        self.vehicle = vehicle
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
        _draft = State(
            initialValue: FuelingRecordDraft(
                values: selection.values, storageUnit: selection.storageUnit,
                inputUnit: vehicle.displayUnitSystem))
    }

    private var chronologyValidation: OdometerChronologyValidation? {
        guard let current = draft.storageOdometer else { return nil }
        return OdometerChronologyValidator.validate(
            date: draft.date,
            odometer: current,
            records: records.map(OdometerReadingSnapshot.init(record:)),
            originalRecord: OdometerReadingSnapshot(
                id: selection.id, date: selection.values.date, odometer: selection.values.odometer)
        )
    }

    private func isValid(_ validation: OdometerChronologyValidation?) -> Bool {
        guard validation?.isValid == true else { return false }
        return draft.isValid
    }

    var body: some View {
        let validation = chronologyValidation

        NavigationStack {
            Form {
                FuelingRecordFormView(
                    unitSystem: units,
                    storageUnit: vehicle.unitSystem,
                    metricEfficiencyFormat: metricEfficiencyFormat,
                    draft: $draft,
                    focusedField: $focusedField,
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
                    Button("Save") { Task { await saveChanges() } }
                        .fontWeight(.semibold)
                        .disabled(!isValid(validation))
                }

                FuelingRecordKeyboardToolbar {
                    focusedField = nil
                    hideKeyboard()
                }
            }
            .alert("Unable to Save", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
    }

    private func saveChanges() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard isValid(chronologyValidation) else { return }
        do {
            try await FuelingRecordPersistenceService(writer: writer).update(
                recordID: selection.id, update: draft.makeUpdate()
            )
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
        }
    }
}

#Preview {
    let schema = Schema(versionedSchema: SchemaV5.self)
    let container = try! ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    let writer = OwnedModelStore(container: container)
    let vehicle = Vehicle(name: "Test Car")
    let record = FuelingRecord(
        odometer: 1000,
        pricePerFuelUnit: 3.459,
        fuelAmount: 12.5,
        totalCost: 43.24,
        vehicle: vehicle
    )

    return EditRecordView(selection: FuelingRecordEditSelection(record: record), vehicle: vehicle, records: [record])
        .modelContainer(container)
        .environmentObject(writer)
}
