import SwiftUI
import SwiftData
import os

struct SettingsView: View {
    private enum DeleteOutcome: Int, Identifiable {
        case success
        case failure

        var id: Int { rawValue }
    }

    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudSyncService: CloudSyncService

    @Query private var vehicles: [Vehicle]
    @Query(filter: #Predicate<CloudRecoveryReceipt> { $0.phaseRaw != "completed" && $0.phaseRaw != "superseded" })
    private var pendingReplacements: [CloudRecoveryReceipt]
    @StateObject private var syncRecovery = SyncRecoveryModel()

    private var recoverySource: SyncRecoveryModel.Source {
        SyncRecoveryModel.Source(
            revision: syncRecovery.revision, isSyncing: stateManager.syncStatus.isInProgress)
    }

    private var totalRecordCount: Int {
        vehicles.reduce(0) { $0 + $1.displayRecordCount }
    }

    @State private var showingDeleteAllAlert = false
    @State private var showingDeleteAllConfirmation = false
    @State private var deleteOutcome: DeleteOutcome?

    // iCloud Sync state
    @State private var initialSyncProposal: InitialSyncProposal?
    @State private var showingToggleOffAlert = false
    @State private var showingICloudError = false
    @State private var iCloudErrorMessage = ""


    private var stateManager: SyncStateManager {
        cloudSyncService.stateManager
    }

    // App info
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version).\(build)"
    }

    @ViewBuilder
    private var iCloudSyncSection: some View {
        Section {
            Toggle(isOn: Binding(
                    get: { stateManager.iCloudSyncEnabled },
                set: { newValue in
                    if newValue {
                        handleToggleOn()
                    } else {
                        showingToggleOffAlert = true
                    }
                }
            )) {
                HStack {
                    Image(systemName: "icloud.fill")
                        .foregroundColor(.blue)
                    Text("iCloud Sync")
                        .font(.appBody)
                }
            }
            .disabled(stateManager.syncStatus.isInProgress || !pendingReplacements.isEmpty)
            .accessibilityIdentifier("settings.sync")

            HStack {
                Text("Status")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if stateManager.syncStatus.isInProgress {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 4)
                }
                Text(stateManager.syncStatus.displayText)
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
            }
            if !pendingReplacements.isEmpty {
                Text("Your saved replacement data has been kept on this device.")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sync.recovery.paused")
            }
        } header: {
            Text("iCloud")
                .font(.appCaption)
        } footer: {
            Text("Sync your fueling data across all your devices using iCloud.")
                .font(.appCaption)
        }
    }

    @ViewBuilder
    private var syncRecoverySection: some View {
        let assessment = syncRecovery.assessment
        if pendingReplacements.isEmpty && !stateManager.syncStatus.isInProgress
            && (!assessment.unitConfirmations.isEmpty || assessment.legacyDeletionCount > 0
                || !assessment.diagnostics.isEmpty || syncRecovery.loadError != nil)
        {
            Section("Sync Needs Attention") {
                if syncRecovery.loadError == nil {
                    if !assessment.unitConfirmations.isEmpty {
                        NavigationLink("Confirm Measurement Units", value: SyncRecoveryDestination.measurementUnits)
                            .accessibilityIdentifier("sync.recovery.units")
                    }
                    if assessment.legacyDeletionCount > 0 {
                        NavigationLink("Review Previous Deletions", value: SyncRecoveryDestination.previousDeletions)
                            .accessibilityIdentifier("sync.recovery.deletions")
                    }
                }
                if !assessment.diagnostics.isEmpty || syncRecovery.loadError != nil {
                    NavigationLink("View Sync Diagnostics", value: SyncRecoveryDestination.diagnostics)
                        .accessibilityIdentifier("sync.recovery.diagnostics")
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                iCloudSyncSection
                syncRecoverySection

                // Data Statistics Section
                Section {
                    InfoRow(label: "Vehicles", value: "\(vehicles.count)")
                    InfoRow(label: "Fueling Records", value: "\(totalRecordCount)")
                } header: {
                    Text("Local Data")
                        .font(.appCaption)
                }

                // iCloud Sync Details (only when sync is enabled)
                if stateManager.iCloudSyncEnabled {
                    Section {
                        NavigationLink {
                            iCloudSyncDetailView()
                        } label: {
                            HStack {
                                Image(systemName: "icloud.and.arrow.up.fill")
                                    .foregroundColor(.blue)
                                Text("iCloud Sync Details")
                                    .font(.appBody)
                            }
                        }
                    }
                }

                // Danger Zone Section
                Section {
                    Button(role: .destructive) {
                        showingDeleteAllAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.red)
                            Text("Delete All Data")
                                .font(.appBody)
                        }
                    }
                    .disabled(vehicles.isEmpty && totalRecordCount == 0)
                } header: {
                    Text("Danger Zone")
                        .font(.appCaption)
                } footer: {
                    Text("This will permanently delete all vehicles and fueling records. This action cannot be undone.")
                        .font(.appCaption)
                }

                Section {
                    InfoRow(label: "Version", value: appVersion)
                } header: {
                    Text("App Information")
                        .font(.appCaption)
                } footer: {
                    Text("\u{00A9} 2026 Shilei Tian")
                        .font(.appCaption)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SyncRecoveryDestination.self) { destination in
                switch destination {
                case .measurementUnits: SyncMeasurementReviewView(recovery: syncRecovery)
                case .previousDeletions: SyncDeletionReviewView(recovery: syncRecovery)
                case .diagnostics: SyncDiagnosticsView(recovery: syncRecovery)
                }
            }
            .task(id: recoverySource) {
                await syncRecovery.reload(in: modelContext, revision: recoverySource.revision)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            // Use the same native alert presentation as the other confirmations.
            .alert(
                "iCloud Data Found",
                isPresented: Binding(
                    get: { initialSyncProposal != nil },
                    set: { if !$0 { initialSyncProposal = nil } }
                ), presenting: initialSyncProposal
            ) { proposal in
                Button("Use iCloud Data") { performInitialSync(strategy: .useCloud, proposal: proposal) }
                Button("Merge Both") { performInitialSync(strategy: .merge, proposal: proposal) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(
                    "iCloud already contains fueling data. You can merge both copies. Using the iCloud copy replaces the local copy on this device."
                )
            }
            // Toggle off alert
            .alert("Disable iCloud Sync?", isPresented: $showingToggleOffAlert) {
                Button("Keep Local Data") {
                    handleToggleOff(removeLocalData: false)
                }
                Button("Remove Local Data", role: .destructive) {
                    handleToggleOff(removeLocalData: true)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Do you want to keep or remove the local data on this device?")
            }
            // iCloud error
            .alert("iCloud Error", isPresented: $showingICloudError) {
                Button("OK") { }
            } message: {
                Text(iCloudErrorMessage)
            }
            // Delete all data alerts
            .alert("Delete All Data?", isPresented: $showingDeleteAllAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    showingDeleteAllConfirmation = true
                }
            } message: {
                Text("This will permanently delete \(vehicles.count) vehicle(s) and \(totalRecordCount) fueling record(s).")
            }
            .alert("Are You Sure?", isPresented: $showingDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Yes, Delete Everything", role: .destructive) {
                    Task { await deleteAllData() }
                }
            } message: {
                Text("This action cannot be undone. All your data will be permanently deleted.")
            }
            .alert(item: $deleteOutcome) { outcome in
                switch outcome {
                case .success:
                    return Alert(
                        title: Text("Data Deleted"),
                        message: Text("All data has been successfully deleted."),
                        dismissButton: .default(Text("OK")) {
                            dismiss()
                        }
                    )
                case .failure:
                    return Alert(
                        title: Text("Unable to Delete"),
                        message: Text("Your changes could not be saved. No data was changed. Please try again."),
                        dismissButton: .cancel(Text("OK"))
                    )
                }
            }
        }
    }

    // MARK: - iCloud Sync Handlers

    private func handleToggleOn() {
        Task {
            do {
                let proposal = try await cloudSyncService.prepareInitialSync()
                if proposal.hasCloudData {
                    initialSyncProposal = proposal
                } else {
                    await enableSync(strategy: .merge, proposal: proposal)
                }
            } catch { presentSyncError(error) }
        }
    }

    private func performInitialSync(strategy: InitialSyncStrategy, proposal: InitialSyncProposal) {
        Task { await enableSync(strategy: strategy, proposal: proposal) }
    }

    private func enableSync(strategy: InitialSyncStrategy, proposal: InitialSyncProposal) async {
        do {
            try await cloudSyncService.enableSync(strategy: strategy, proposal: proposal)
        } catch { presentSyncError(error) }
    }

    private func presentSyncError(_ error: Error) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "Settings")
            .error("iCloud activation failed: \(error)")
        iCloudErrorMessage = error.localizedDescription
        showingICloudError = true
    }

    private func handleToggleOff(removeLocalData: Bool) {
        Task {
            do {
                try await cloudSyncService.disable(removeLocalData ? .removeLocalCopy : .keepLocalData)
                if removeLocalData { dismiss() }
            } catch {
                iCloudErrorMessage = error.localizedDescription
                showingICloudError = true
            }
        }
    }

    private func deleteAllData() async {
        do {
            try await VehiclePersistenceService(writer: writer).deleteAllData()
            deleteOutcome = .success
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "Settings")
                .error("Failed to delete all data: \(error)")
            deleteOutcome = .failure
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
    return SettingsView()
        .modelContainer(container)
        .environmentObject(CloudSyncService(writer: writer))
        .environmentObject(writer)
}
