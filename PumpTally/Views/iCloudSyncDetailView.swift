import SwiftUI
import SwiftData

// MARK: - iCloud Sync Detail View

struct iCloudSyncDetailView: View {
    @EnvironmentObject private var cloudSyncService: CloudSyncService

    @Query private var vehicles: [Vehicle]

    private var totalRecordCount: Int {
        vehicles.reduce(0) { $0 + $1.displayRecordCount }
    }

    @State private var cloudCounts: (vehicles: Int, fuelingRecords: Int)?
    @State private var isLoadingCloudCounts = false
    @State private var countsUnavailable = false
    @State private var refreshID = UUID()

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
                cloudCountRow(label: "Vehicles", cloudCount: cloudCounts?.vehicles, localCount: vehicles.count)
                cloudCountRow(
                    label: "Fueling Records", cloudCount: cloudCounts?.fuelingRecords, localCount: totalRecordCount)
            } header: {
                Text("iCloud Data")
                    .font(.appCaption)
            } footer: {
                if countsUnavailable {
                    Text("Unable to load iCloud counts.")
                        .font(.appCaption)
                } else if let cloudCounts,
                    cloudCounts.vehicles != vehicles.count || cloudCounts.fuelingRecords != totalRecordCount
                {
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
                    refreshID = UUID()
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
        .task(id: refreshID) { await loadCloudCounts() }
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

    private func loadCloudCounts() async {
        isLoadingCloudCounts = true
        countsUnavailable = false
        cloudCounts = nil
        defer { if !Task.isCancelled { isLoadingCloudCounts = false } }
        do {
            let counts = try await cloudSyncService.fetchCloudRecordCounts()
            try Task.checkCancellation()
            cloudCounts = counts
        } catch {
            guard !Task.isCancelled else { return }
            countsUnavailable = true
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
