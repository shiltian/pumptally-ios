import SwiftUI
import SwiftData

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
                        "Counts can differ while changes are pending."
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
                .disabled(isLoadingCloudCounts)

            } header: {
                Text("Actions")
                    .font(.appCaption)
            } footer: {
                Text(CloudRecoveryError.replacementUnavailable.localizedDescription)
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
