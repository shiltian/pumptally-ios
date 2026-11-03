import SwiftUI
import SwiftData
import os

// MARK: - iCloud Sync Detail View

struct iCloudSyncDetailView: View {
    @EnvironmentObject private var cloudSyncService: CloudSyncService

    @Query private var vehicles: [Vehicle]

    private var totalRecordCount: Int {
        vehicles.reduce(0) { $0 + $1.displayRecordCount }
    }

    @State private var cloudVehicleCount: Int?
    @State private var cloudRecordCount: Int?
    @State private var isLoadingCloudCounts = false
    @State private var showingForceResyncAlert = false
    @State private var isResyncing = false
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        List {
            // Local counts for comparison
            Section {
                InfoRow(label: "Vehicles", value: "\(vehicles.count)")
                InfoRow(label: "Fueling Records", value: "\(totalRecordCount)")
            } header: {
                Text("Local Data")
                    .font(.appCaption)
            }

            // iCloud counts
            Section {
                cloudCountRow(label: "Vehicles", cloudCount: cloudVehicleCount, localCount: vehicles.count)
                cloudCountRow(label: "Fueling Records", cloudCount: cloudRecordCount, localCount: totalRecordCount)
            } header: {
                Text("iCloud Data")
                    .font(.appCaption)
            } footer: {
                if let vc = cloudVehicleCount, let rc = cloudRecordCount,
                   (vc != vehicles.count || rc != totalRecordCount) {
                    Text(
                        "Counts can differ while changes are pending. Replace iCloud data only when this device has the copy you want to keep."
                    )
                        .font(.appCaption)
                        .foregroundColor(.orange)
                }
            }

            // Actions
            Section {
                Button {
                    loadCloudCounts()
                } label: {
                    HStack {
                        Label("Refresh Counts", systemImage: "arrow.clockwise")
                            .font(.appBody)
                        Spacer()
                        if isLoadingCloudCounts {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isLoadingCloudCounts || isResyncing)

                Button {
                    showingForceResyncAlert = true
                } label: {
                    HStack {
                        Label("Replace iCloud Data", systemImage: "arrow.triangle.2.circlepath")
                            .font(.appBody)
                        Spacer()
                        if isResyncing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isResyncing || isLoadingCloudCounts)
            } header: {
                Text("Actions")
                    .font(.appCaption)
            } footer: {
                Text(
                    "Replacement publishes a saved snapshot from this device. Interrupted replacements can resume; later local edits sync afterward."
                )
                    .font(.appCaption)
            }

            // Sync status
            Section {
                InfoRow(label: "Status", value: cloudSyncService.stateManager.syncStatus.displayText)
                InfoRow(label: "Sync Enabled", value: cloudSyncService.stateManager.iCloudSyncEnabled ? String(localized: "Yes") : String(localized: "No"))
                InfoRow(label: "Initial Sync Done", value: cloudSyncService.stateManager.initialSyncCompleted ? String(localized: "Yes") : String(localized: "No"))
            } header: {
                Text("Sync Status")
                    .font(.appCaption)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("iCloud Sync Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Replace iCloud Data?", isPresented: $showingForceResyncAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive) {
                forceResyncFromLocal()
            }
        } message: {
            Text(
                "Use this device's \(vehicles.count) vehicle(s) and \(totalRecordCount) record(s) to replace the iCloud copy? Update or close PumpTally on your other devices until replacement finishes. Older versions cannot coordinate replacement."
            )
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            loadCloudCounts()
        }
    }

    @ViewBuilder
    private func cloudCountRow(label: LocalizedStringKey, cloudCount: Int?, localCount: Int) -> some View {
        HStack {
            Text(label)
                .font(.appBody)
            Spacer()
            if isLoadingCloudCounts {
                ProgressView()
                    .scaleEffect(0.8)
            } else if let count = cloudCount {
                Text("\(count)")
                    .font(.appBody)
                    .foregroundColor(count == localCount ? .secondary : .orange)
            } else {
                Text("--")
                    .font(.appBody)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadCloudCounts() {
        isLoadingCloudCounts = true
        cloudVehicleCount = nil
        cloudRecordCount = nil
        Task {
            let counts = await cloudSyncService.fetchCloudRecordCounts()
            await MainActor.run {
                cloudVehicleCount = counts.vehicles
                cloudRecordCount = counts.fuelingRecords
                isLoadingCloudCounts = false
            }
        }
    }

    private func forceResyncFromLocal() {
        isResyncing = true
        cloudVehicleCount = nil
        cloudRecordCount = nil
        Task {
            do {
                try await cloudSyncService.replaceCloudDataWithLocal()
                let counts = await cloudSyncService.fetchCloudRecordCounts()

                await MainActor.run {
                    cloudVehicleCount = counts.vehicles
                    cloudRecordCount = counts.fuelingRecords
                    isResyncing = false
                }
            } catch {
                await MainActor.run {
                    isResyncing = false
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "iCloudSync")
                        .error("Re-sync failed: \(error)")
                    errorMessage = String(localized: "Unable to re-sync with iCloud. Please check your connection and try again.")
                    showingError = true
                }
            }
        }
    }
}

// MARK: - InfoRow

struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.appBody)
            Spacer()
            Text(value)
                .font(.appBody)
                .foregroundColor(.secondary)
        }
    }
}
