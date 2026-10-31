import SwiftUI
import SwiftData

struct AddVehicleView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var make = ""
    @State private var model = ""
    @State private var yearString = ""
    @State private var unitSystem: UnitSystem = .imperial
    @State private var metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat
    @State private var showingSaveError = false

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Vehicle Name", text: $name)
                        .font(.appBody)
                } header: {
                    Text("Required")
                        .font(.appCaption)
                } footer: {
                    Text("Give your vehicle a nickname (e.g., \"My Tesla\", \"Family SUV\")")
                        .font(.appCaption)
                }

                Section {
                    TextField("Make (e.g., Toyota)", text: $make)
                        .font(.appBody)

                    TextField("Model (e.g., Camry)", text: $model)
                        .font(.appBody)

                    TextField("Year (e.g., 2023)", text: $yearString)
                        .font(.appBody)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Optional Details")
                        .font(.appCaption)
                }

                Section {
                    Picker("Unit System", selection: $unitSystem) {
                        ForEach(UnitSystem.allCases, id: \.self) { unit in
                            VStack(alignment: .leading) {
                                Text(unit.displayName)
                            }
                            .tag(unit)
                        }
                    }
                    .font(.appBody)
                    .pickerStyle(.menu)

                    if unitSystem == .metric {
                        Picker("Fuel Economy", selection: $metricEfficiencyFormat) {
                            ForEach(MetricEfficiencyFormat.allCases, id: \.self) { format in
                                Text(format.unit)
                                    .tag(format)
                            }
                        }
                        .font(.appBody)
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Units")
                        .font(.appCaption)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(unitSystem.displayDescription(for: metricEfficiencyFormat))
                        if unitSystem == .metric {
                            Text("This display preference is stored only for this vehicle on this device.")
                        }
                    }
                    .font(.appCaption)
                }
            }
            .navigationTitle("Add Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveVehicle()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
            .alert("Unable to Save", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your changes could not be saved. No data was changed. Please try again.")
            }
        }
    }

    private func saveVehicle() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let vehicle = try VehiclePersistenceService.insert(context: modelContext) {
                let vehicle = Vehicle(
                    name: trimmedName,
                    make: trimmedMake.isEmpty ? nil : trimmedMake,
                    model: trimmedModel.isEmpty ? nil : trimmedModel,
                    year: Int(yearString),
                    unitSystem: unitSystem
                )
                vehicle.modifiedAt = Date()
                return vehicle
            }

            if unitSystem == .metric {
                metricEfficiencyFormat.store(for: vehicle.id)
            }
            dismiss()
        } catch {
            showingSaveError = true
        }
    }
}

#Preview {
    AddVehicleView()
        .modelContainer(for: [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self], inMemory: true)
}
