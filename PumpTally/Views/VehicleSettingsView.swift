import SwiftUI
import SwiftData
import os

struct VehicleSettingsView: View {
    let vehicle: Vehicle

    @State private var isSaving = false
    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudSyncService: CloudSyncService

    // Vehicle detail editing
    @State private var originalSettings: VehicleSettingsValues
    @State private var name: String
    @State private var make: String
    @State private var model: String
    @State private var yearString: String

    // Unit system
    @State private var selectedUnit: UnitSystem
    @State private var metricEfficiencyFormat: MetricEfficiencyFormat

    // CSV
    @State private var showingExportOptions = false
    @State private var showingImportPicker = false

    // Clear history
    @State private var showingClearHistoryAlert = false
    @State private var showingClearHistoryConfirmation = false
    @State private var showingClearHistorySuccess = false
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""
    @State private var showingClearHistoryError = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        _originalSettings = State(initialValue: VehicleSettingsValues(vehicle: vehicle))
        _name = State(initialValue: vehicle.name)
        _make = State(initialValue: vehicle.make ?? "")
        _model = State(initialValue: vehicle.model ?? "")
        _yearString = State(initialValue: vehicle.year != nil ? "\(vehicle.year!)" : "")
        _selectedUnit = State(initialValue: vehicle.displayUnitSystem)
        _metricEfficiencyFormat = State(
            initialValue: MetricEfficiencyFormat.stored(for: vehicle.id)
        )
    }

    private var recordCount: Int {
        vehicle.displayRecordCount
    }

    private var unitHasChanged: Bool {
        selectedUnit != vehicle.displayUnitSystem
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Vehicle Details
                Section {
                    TextField("Vehicle Name", text: $name)
                        .font(.appBody)

                    TextField("Make (e.g., Toyota)", text: $make)
                        .font(.appBody)

                    TextField("Model (e.g., Camry)", text: $model)
                        .font(.appBody)

                    TextField("Year (e.g., 2023)", text: $yearString)
                        .font(.appBody)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Vehicle Details")
                        .font(.appCaption)
                }

                // MARK: - Unit System
                Section {
                    ForEach(UnitSystem.allCases, id: \.self) { unit in
                        Button {
                            selectedUnit = unit
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(unit.displayName)
                                        .font(.appBody)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Text(unit.displayDescription(for: metricEfficiencyFormat))
                                        .font(.appFootnote)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if selectedUnit == unit {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.teal)
                                        .font(.title2)
                                }
                            }
                        }
                    }

                    if selectedUnit == .metric {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Fuel Economy")
                                .font(.appBody)
                                .fontWeight(.semibold)

                            Picker("Fuel Economy", selection: $metricEfficiencyFormat) {
                                ForEach(MetricEfficiencyFormat.allCases, id: \.self) { format in
                                    Text(format.unit)
                                        .tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Unit System")
                        .font(.appCaption)
                } footer: {
                    if selectedUnit == .metric {
                        Text("This display preference is stored only for this vehicle on this device.")
                            .font(.appCaption)
                    }
                    if unitHasChanged && recordCount > 0 {
                        Text("Changes display and input units. Stored measurements are preserved.")
                            .font(.appCaption)
                            .foregroundColor(.orange)
                    }
                }

                // MARK: - Data
                Section {
                    Button {
                        showingExportOptions = true
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                            .font(.appBody)
                    }
                    .disabled(vehicle.fuelingRecords?.isEmpty ?? true)

                    Button {
                        showingImportPicker = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                            .font(.appBody)
                    }
                } header: {
                    Text("Data")
                        .font(.appCaption)
                }

                // MARK: - Danger Zone
                Section {
                    Button(role: .destructive) {
                        showingClearHistoryAlert = true
                    } label: {
                        Label("Clear Fueling History", systemImage: "trash")
                            .font(.appBody)
                    }
                    .disabled(vehicle.fuelingRecords?.isEmpty ?? true)
                } header: {
                    Text("Danger Zone")
                        .font(.appCaption)
                } footer: {
                    if recordCount > 0 {
                        Text("This will permanently delete all \(recordCount) fueling record(s). The vehicle itself will be kept.")
                            .font(.appCaption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Vehicle Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await saveAndDismiss() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            // Clear history alerts
            .alert("Clear Fueling History?", isPresented: $showingClearHistoryAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    showingClearHistoryConfirmation = true
                }
            } message: {
                Text("This will delete all \(recordCount) fueling record(s) for this vehicle. The vehicle itself will be kept.")
            }
            .alert("Are You Sure?", isPresented: $showingClearHistoryConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Yes, Delete All Records", role: .destructive) {
                    Task { await clearFuelingHistory() }
                }
            } message: {
                Text("This action cannot be undone. All fueling history for this vehicle will be permanently deleted.")
            }
            .alert("History Cleared", isPresented: $showingClearHistorySuccess) {
                Button("OK") { }
            } message: {
                Text("All fueling records have been deleted.")
            }
            .alert("Unable to Save", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveErrorMessage)
            }
            .alert("Unable to Delete", isPresented: $showingClearHistoryError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your changes could not be saved. No data was changed. Please try again.")
            }
            // CSV sheets
            .sheet(isPresented: $showingExportOptions) {
                ExportCSVView(vehicle: vehicle)
            }
            .sheet(isPresented: $showingImportPicker) {
                ImportCSVView(vehicle: vehicle)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Actions

    private func saveAndDismiss() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // Save vehicle detail edits
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedMake = trimmedMake.isEmpty ? nil : trimmedMake
        let updatedModel = trimmedModel.isEmpty ? nil : trimmedModel
        let updatedYear = Int(yearString)
        let proposed = VehicleSettingsValues(
            name: trimmedName, make: updatedMake, model: updatedModel,
            year: updatedYear, displayUnit: selectedUnit)
        do {
            try await VehiclePersistenceService(writer: writer).update(
                vehicleID: vehicle.id, update: VehicleSettingsUpdate(original: originalSettings, proposed: proposed))
            if selectedUnit == .metric { metricEfficiencyFormat.store(for: vehicle.id) }
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
        }
    }

    private func clearFuelingHistory() async {
        guard !(vehicle.fuelingRecords?.isEmpty ?? true) else { return }

        do {
            try await cloudSyncService.withLocalPushesSuspended {
                try await VehiclePersistenceService(writer: writer).clearFuelingHistory(
                    vehicleID: vehicle.id)
            }

            showingClearHistorySuccess = true
            Task {
                await cloudSyncService.pushPendingLocalChanges()
            }
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "VehicleSettings")
                .error("Failed to clear fueling history: \(error)")
            showingClearHistoryError = true
        }
    }
}

#Preview {
    let schema = Schema(versionedSchema: SchemaV6.self)
    let container = try! ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    let writer = OwnedModelStore(container: container)
    return VehicleSettingsView(vehicle: Vehicle(name: "Test Car"))
        .modelContainer(container)
        .environmentObject(CloudSyncService(writer: writer))
        .environmentObject(writer)
}
