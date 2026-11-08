import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import os

struct ContentView: View {
    @EnvironmentObject private var writer: OwnedModelStore
    @EnvironmentObject private var cloudSyncService: CloudSyncService
    @Query(sort: \Vehicle.createdAt, order: .reverse) private var vehicles: [Vehicle]

    // Binding from PumpTallyApp for incoming file URLs
    @Binding var importedFile: CSVImportFile?

    @State private var showingAddVehicle = false
    @State private var createdVehicleID: UUID?
    @State private var navigationPath: [UUID] = []
    @State private var hasPerformedInitialNavigation = false

    private var vehicleIDs: [UUID] { vehicles.map(\.id) }

    // CSV Import state
    @State private var importedRecordsCount = 0
    @State private var pendingImportedCount: Int?
    @State private var showingImportSuccess = false

    // Store the last viewed vehicle ID
    @AppStorage("lastViewedVehicleID") private var lastViewedVehicleID: String = ""

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if vehicles.isEmpty {
                    EmptyVehicleView(showingAddVehicle: $showingAddVehicle)
                } else {
                    VehicleListView(
                        vehicles: vehicles,
                        showingAddVehicle: $showingAddVehicle
                    )
                }
            }
            .navigationDestination(for: UUID.self) { vehicleID in
                if let vehicle = vehicles.first(where: { $0.id == vehicleID }) {
                    VehicleDetailView(vehicle: vehicle, container: writer.container)
                        .onAppear {
                            if lastViewedVehicleID != vehicleID.uuidString {
                                lastViewedVehicleID = vehicleID.uuidString
                            }
                        }
                }
            }
            .onChange(of: vehicleIDs, initial: true) { _, currentIDs in
                reconcileNavigation(with: currentIDs)
            }
            .sheet(
                isPresented: $showingAddVehicle,
                onDismiss: {
                    if let id = createdVehicleID { navigationPath = [id] }
                    createdVehicleID = nil
                }
            ) {
                AddVehicleView { createdVehicleID = $0 }
            }
            .sheet(
                item: $importedFile,
                onDismiss: {
                    if let count = pendingImportedCount {
                        importedRecordsCount = count
                        pendingImportedCount = nil
                        showingImportSuccess = true
                    }
                }
            ) { file in
                CSVImportView(fileURL: file.url, vehicles: vehicles, onImport: handleCSVImport)
            }
        }
        .alert("Import Successful", isPresented: $showingImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(importedRecordsCount) record(s) imported successfully")
        }
    }

    private func handleCSVImport(count: Int) {
        pendingImportedCount = count
    }

    /// Navigation follows stable IDs rather than the lifetime of SwiftData
    /// instances. A refresh can replace an object without replacing its route.
    private func reconcileNavigation(with currentIDs: [UUID]) {
        let availableIDs = Set(currentIDs)
        let updatedPath: [UUID]
        if hasPerformedInitialNavigation {
            updatedPath = navigationPath.filter { availableIDs.contains($0) }
        } else {
            hasPerformedInitialNavigation = true
            let rememberedID = UUID(uuidString: lastViewedVehicleID)
            let selected = rememberedID.flatMap { availableIDs.contains($0) ? $0 : nil } ?? currentIDs.first
            updatedPath = selected.map { [$0] } ?? []
        }
        if navigationPath != updatedPath { navigationPath = updatedPath }
    }
}

struct EmptyVehicleView: View {
    @Binding var showingAddVehicle: Bool
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "car.fill")
                .font(.system(size: 80))
                .foregroundStyle(LinearGradient.brandDiagonal)

            Text("Welcome to PumpTally")
                .font(.appDisplay)
                .fontWeight(.bold)

            Text("Track your fuel consumption, costs, and efficiency.")
                .font(.appBody)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: { showingAddVehicle = true }) {
                Label("Add Your First Vehicle", systemImage: "plus.circle.fill")
                    .font(.appButton)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(LinearGradient.brandHorizontal)
                    .clipShape(Capsule())
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient.subtleBackground)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
    return ContentView(importedFile: .constant(nil))
        .modelContainer(container)
        .environmentObject(CloudSyncService(writer: writer))
        .environmentObject(writer)
}
