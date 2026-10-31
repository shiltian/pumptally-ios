import SwiftUI
import SwiftData
import os

struct SettingsView: View {
    private enum DeleteOutcome: Int, Identifiable {
        case success
        case failure

        var id: Int { rawValue }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloudSyncService: CloudSyncService

    @Query private var vehicles: [Vehicle]

    private var totalRecordCount: Int {
        vehicles.reduce(0) { $0 + $1.displayRecordCount }
    }

    @State private var showingDeleteAllAlert = false
    @State private var showingDeleteAllConfirmation = false
    @State private var deleteOutcome: DeleteOutcome?

    // iCloud Sync state
    @State private var isSyncToggleOn = false
    @State private var showingConflictOptions = false
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
                get: { isSyncToggleOn },
                set: { newValue in
                    if newValue {
                        isSyncToggleOn = true
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
            .disabled(stateManager.syncStatus.isInProgress)

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
        } header: {
            Text("iCloud")
                .font(.appCaption)
        } footer: {
            Text("Sync your fueling data across all your devices using iCloud.")
                .font(.appCaption)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                iCloudSyncSection

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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            // iCloud conflict resolution action sheet
            .confirmationDialog("iCloud Data Found", isPresented: $showingConflictOptions, titleVisibility: .visible) {
                Button("Use iCloud Data") {
                    performInitialSync(strategy: .overwriteLocal)
                }
                Button("Use Local Data") {
                    performInitialSync(strategy: .overwriteCloud)
                }
                Button("Merge Both") {
                    performInitialSync(strategy: .merge)
                }
                Button("Cancel", role: .cancel) {
                    isSyncToggleOn = false
                }
            } message: {
                Text("iCloud already contains fueling data. How would you like to handle this?")
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
                    deleteAllData()
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
            .onAppear {
                isSyncToggleOn = stateManager.iCloudSyncEnabled
            }
        }
    }

    // MARK: - iCloud Sync Handlers

    private func handleToggleOn() {
        Task {
            // Check iCloud availability
            let available = await cloudSyncService.checkiCloudAvailability()
            guard available else {
                isSyncToggleOn = false
                iCloudErrorMessage = String(localized: "Please sign in to iCloud in Settings to use this feature.")
                showingICloudError = true
                return
            }

            do {
                // "Empty" is a valid result; a CloudKit failure is not. Never
                // choose the upload-local strategy when cloud state is unknown.
                let cloudHasData = try await cloudSyncService.checkCloudHasData()

                if cloudHasData {
                    // Show conflict resolution
                    showingConflictOptions = true
                } else {
                    // No cloud data: upload local and start syncing
                    performInitialSync(strategy: .uploadLocal)
                }
            } catch {
                isSyncToggleOn = false
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "Settings")
                    .error("Unable to determine whether iCloud contains data: \(error)")
                iCloudErrorMessage = String(localized: "Unable to sync with iCloud. Please check your internet connection and iCloud settings, then try again.")
                showingICloudError = true
            }
        }
    }

    private enum InitialSyncStrategy {
        case uploadLocal      // No cloud data -- upload everything
        case overwriteLocal   // User chose "Use iCloud Data"
        case overwriteCloud   // User chose "Use Local Data"
        case merge            // User chose "Merge Both"
    }

    private func performInitialSync(strategy: InitialSyncStrategy) {
        Task {
            do {
                stateManager.iCloudSyncEnabled = true

                switch strategy {
                case .uploadLocal:
                    try await cloudSyncService.uploadAllLocalData(from: modelContext)

                case .overwriteLocal:
                    try await cloudSyncService.downloadAllCloudData(to: modelContext)

                case .overwriteCloud:
                    try await cloudSyncService.replaceCloudDataWithLocal(from: modelContext)

                case .merge:
                    try await cloudSyncService.mergeCloudAndLocal(context: modelContext)
                }

                stateManager.markInitialSyncComplete()

                await cloudSyncService.startMonitoring(container: modelContext.container)
                await cloudSyncService.synchronizeNow()
            } catch {
                stateManager.iCloudSyncEnabled = false
                isSyncToggleOn = false
                stateManager.syncStatus = .error(String(localized: "Sync failed"))
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "Settings")
                    .error("iCloud sync failed: \(error)")
                iCloudErrorMessage = String(localized: "Unable to sync with iCloud. Please check your internet connection and iCloud settings, then try again.")
                showingICloudError = true
            }
        }
    }

    private func handleToggleOff(removeLocalData: Bool) {
        if removeLocalData {
            deleteAllData()
        }

        stateManager.iCloudSyncEnabled = false
        isSyncToggleOn = false
        stateManager.resetSyncState()
        cloudSyncService.stopMonitoring()
    }

    private func deleteAllData() {
        do {
            try VehiclePersistenceService.deleteAllData(context: modelContext)
            deleteOutcome = .success
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "Settings")
                .error("Failed to delete all data: \(error)")
            deleteOutcome = .failure
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self], inMemory: true)
        .environmentObject(CloudSyncService())
}
