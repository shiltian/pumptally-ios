import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var cloudSyncService: CloudSyncService
    @Query(sort: \Vehicle.createdAt, order: .reverse) private var vehicles: [Vehicle]

    // Binding from PumpTallyApp for incoming file URLs
    @Binding var importedFileURL: URL?

    @State private var showingAddVehicle = false
    @State private var navigationPath = NavigationPath()
    @State private var hasPerformedInitialNavigation = false

    // CSV Import state
    @State private var showingCSVImport = false
    @State private var importedRecordsCount = 0
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
            .navigationDestination(for: Vehicle.self) { vehicle in
                VehicleDetailView(vehicle: vehicle)
                    .onAppear {
                        // Save this vehicle as the last viewed
                        lastViewedVehicleID = vehicle.id.uuidString
                    }
            }
            .sheet(isPresented: $showingAddVehicle) {
                AddVehicleView()
            }
            .sheet(isPresented: $showingCSVImport, onDismiss: {
                // Clear the imported file URL when sheet is dismissed
                importedFileURL = nil
            }) {
                CSVImportView(
                    fileURL: importedFileURL,
                    vehicles: vehicles,
                    onImport: handleCSVImport
                )
            }
            .onAppear {
                navigateToLastVehicleIfNeeded()
                // Check if there's a pending file to import on appear
                if importedFileURL != nil {
                    showingCSVImport = true
                }
            }
            .onChange(of: vehicles) { oldVehicles, newVehicles in
                // If a new vehicle was added and we were empty before, navigate to it
                guard !hasPerformedInitialNavigation else { return }
                if oldVehicles.isEmpty && !newVehicles.isEmpty {
                    if let first = newVehicles.first {
                        navigationPath.append(first)
                        hasPerformedInitialNavigation = true
                    }
                }
            }
            .onChange(of: importedFileURL) { oldValue, newValue in
                // Show import sheet when a new file URL is set
                if newValue != nil {
                    showingCSVImport = true
                }
            }
        }
        .alert("Import Successful", isPresented: $showingImportSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("\(importedRecordsCount) record(s) imported successfully")
        }
    }

    private func handleCSVImport(
        records: [CSVImportRecordSnapshot],
        targetVehicle: Vehicle
    ) throws {
        do {
            try cloudSyncService.withLocalPushesSuspended {
                _ = try CSVImportService.importRecords(
                    records,
                    into: targetVehicle,
                    context: modelContext
                )
            }

            importedRecordsCount = records.count
            Task {
                await cloudSyncService.pushPendingLocalChanges()
            }
            // Delay showing alert to ensure sheet is fully dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showingImportSuccess = true
            }
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "CSVImport")
                .error("Failed to save imported records: \(error)")
            if let importError = error as? CSVImportError {
                throw importError
            }
            throw CSVImportError.persistenceFailed
        }
    }

    private func navigateToLastVehicleIfNeeded() {
        // Only auto-navigate once on initial app launch
        guard !hasPerformedInitialNavigation else { return }
        guard !vehicles.isEmpty else { return }

        hasPerformedInitialNavigation = true

        // Try to find the last viewed vehicle
        if !lastViewedVehicleID.isEmpty,
           let lastID = UUID(uuidString: lastViewedVehicleID),
           let lastVehicle = vehicles.first(where: { $0.id == lastID }) {
            navigationPath.append(lastVehicle)
        } else if let firstVehicle = vehicles.first {
            // Fallback to the first vehicle if no last viewed or it no longer exists
            navigationPath.append(firstVehicle)
        }
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
    ContentView(importedFileURL: .constant(nil))
        .modelContainer(for: [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self], inMemory: true)
        .environmentObject(CloudSyncService())
}

