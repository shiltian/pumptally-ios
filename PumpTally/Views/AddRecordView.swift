import SwiftUI
import SwiftData

struct AddRecordView: View {
    let vehicle: Vehicle
    let records: [FuelingRecord]
    let onSave: ((SavedFuelingRecord) -> Void)?

    @State private var isSaving = false
    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage private var metricEfficiencyFormatRaw: String

    private var units: UnitSystem { draft.inputUnit }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    @State private var draft = FuelingRecordDraft()
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""

    @FocusState private var focusedField: FuelingRecordFormView.EditableField?

    init(vehicle: Vehicle, records: [FuelingRecord], onSave: ((SavedFuelingRecord) -> Void)? = nil) {
        self.vehicle = vehicle
        self.records = records
        self.onSave = onSave
        _draft = State(
            initialValue: FuelingRecordDraft(storageUnit: vehicle.unitSystem, inputUnit: vehicle.displayUnitSystem))
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
    }

    private var chronologyValidation: OdometerChronologyValidation? {
        guard let current = draft.storageOdometer else { return nil }
        return OdometerChronologyValidator.validate(
            date: draft.date,
            odometer: current,
            records: records.map(OdometerReadingSnapshot.init(record:))
        )
    }

    private func isValid(_ validation: OdometerChronologyValidation?) -> Bool {
        guard validation?.isValid == true else { return false }
        return draft.isValid
    }

    var body: some View {
        let validation = chronologyValidation
        let preview = draft.preview(after: FuelingIntervalContext(validation: validation, records: records))

        NavigationStack {
            Form {
                FuelingRecordFormView(
                    unitSystem: units,
                    storageUnit: vehicle.unitSystem,
                    metricEfficiencyFormat: metricEfficiencyFormat,
                    draft: $draft,
                    focusedField: $focusedField,
                    preview: preview,
                    odometerValidationIssue: validation?.issue,
                    showPreview: true
                )
            }
            .navigationTitle("Add Fueling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveRecord() } }
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

    private func saveRecord() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let validation = chronologyValidation
        guard isValid(validation) else { return }
        do {
            let record = try await FuelingRecordPersistenceService(writer: writer).create(
                values: draft.makeValues(), storageUnit: draft.storageUnit, vehicleID: vehicle.id
            )
            onSave?(record)
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
    return AddRecordView(vehicle: Vehicle(name: "Test Car"), records: [])
        .modelContainer(container)
        .environmentObject(writer)
}
