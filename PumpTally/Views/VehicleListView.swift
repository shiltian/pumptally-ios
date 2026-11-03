import SwiftUI
import SwiftData

struct VehicleListView: View {
    let vehicles: [Vehicle]
    @Binding var showingAddVehicle: Bool

    @EnvironmentObject private var writer: OwnedModelStore
    @State private var showingDeleteAlert = false
    @State private var showingDeleteError = false
    @State private var vehicleToDelete: UUID?
    @State private var showingSettings = false

    var body: some View {
        List {
            ForEach(vehicles) { vehicle in
                NavigationLink(value: vehicle.id) {
                    VehicleRowView(vehicle: vehicle)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        vehicleToDelete = vehicle.id
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("My Vehicles")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("app.settings")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAddVehicle = true }) {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Delete Vehicle", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                vehicleToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let vehicle = vehicleToDelete {
                    Task { await deleteVehicle(vehicle) }
                }
            }
        } message: {
            Text("Are you sure you want to delete this vehicle and all its fueling records? This action cannot be undone.")
        }
        .alert("Unable to Delete", isPresented: $showingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes could not be saved. No data was changed. Please try again.")
        }
    }

    private func deleteVehicle(_ vehicleID: UUID) async {
        do {
            try await VehiclePersistenceService(writer: writer).delete(vehicleID: vehicleID)
            withAnimation {
                vehicleToDelete = nil
            }
        } catch {
            vehicleToDelete = nil
            showingDeleteError = true
        }
    }
}

struct VehicleRowView: View {
    let vehicle: Vehicle

    // Use cached record count for performance
    private var recordCount: Int {
        vehicle.displayRecordCount
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient.brandSubdued
                    )
                    .frame(width: 50, height: 50)

                Image(systemName: "car.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.displayName)
                    .font(.appHeadline)
                    .fontWeight(.semibold)

                if let lastRecord = vehicle.lastRecord {
                    Text("Last fill: \(lastRecord.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("No records yet")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if recordCount > 0 {
                Text("\(recordCount)")
                    .font(.appSubheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8)
    }
}

struct VehicleDetailView: View {
    let vehicle: Vehicle
    @Query private var records: [FuelingRecord]

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        let vehicleID = vehicle.id
        _records = Query(filter: #Predicate<FuelingRecord> { $0.vehicle.id == vehicleID })
    }

    @State private var showingAddRecord = false
    @State private var pendingSummary: FuelingSummaryData?
    @State private var activeSummary: FuelingSummaryData?
    @State private var showingVehicleSettings = false

    var body: some View {
        TabView {
            DashboardView(vehicle: vehicle, records: records)
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                }

            HistoryView(vehicle: vehicle, records: records)
                .tabItem {
                    Label("History", systemImage: "list.bullet.rectangle")
                }
        }
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showingAddRecord = true }) {
                        Label("Add Fueling", systemImage: "plus")
                    }

                    Divider()

                    Button(action: { showingVehicleSettings = true }) {
                        Label("Vehicle Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAddRecord = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.brandDiagonal)
                }
                .accessibilityIdentifier("fueling.add")
            }
        }
        .sheet(isPresented: $showingAddRecord, onDismiss: {
            // Present the summary popup only AFTER the add-record sheet has fully
            // dismissed. A small delay ensures SwiftUI completes the sheet
            // transition before presenting the next one.
            if let summary = pendingSummary {
                pendingSummary = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    activeSummary = summary
                }
            }
        }) {
            AddRecordView(vehicle: vehicle, records: records) { record in
                pendingSummary = FuelingSummaryData(
                    record: record,
                    unitSystem: vehicle.displayUnitSystem,
                    metricEfficiencyFormat: .stored(for: vehicle.id)
                )
            }
        }
        .sheet(item: $activeSummary) { summary in
            FuelingSummaryPopup(data: summary)
        }
        .sheet(isPresented: $showingVehicleSettings) {
            VehicleSettingsView(vehicle: vehicle)
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
    return NavigationStack {
        VehicleListView(
            vehicles: [],
            showingAddVehicle: .constant(false)
        )
    }
    .modelContainer(container)
    .environmentObject(writer)
}
