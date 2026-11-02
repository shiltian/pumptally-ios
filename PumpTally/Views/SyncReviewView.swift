import SwiftData
import SwiftUI

enum SyncRecoveryDestination: Hashable {
    case measurementUnits, previousDeletions, diagnostics
}

@MainActor
final class SyncRecoveryModel: ObservableObject {
    struct Source: Equatable {
        let keys: [String]
        let payloads: [Data]
        let deletionGenerations: [String]
        let isSyncing: Bool
    }

    @Published private(set) var assessment = SyncReviewService.Assessment()
    @Published private(set) var loadError: String?

    func reload(in context: ModelContext) {
        do {
            assessment = try SyncReviewService.assessment(in: ModelContext(context.container))
            loadError = nil
        } catch {
            loadError = String(localized: "Recovery information could not be loaded. Try again.")
        }
    }
}

struct SyncMeasurementReviewView: View {
    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.modelContext) private var context
    @ObservedObject var recovery: SyncRecoveryModel
    @State private var selectedUnits: [String: UnitSystem] = [:]
    @State private var confirmation: SyncReviewService.Item?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(recovery.assessment.unitConfirmations) { item in
                Section(item.title) {
                    if item.isVehicle {
                        Text(
                            "An older app changed this vehicle's measurement units. Confirm those units to convert this device's copy while preserving distances and fuel volumes. Incoming fueling records can then be reviewed separately."
                        )
                        if let unit = sourceUnit(for: item) {
                            LabeledContent("Incoming Units", value: unit.displayName)
                        }
                    } else {
                        Text("Confirm the units used for these incoming measurements before they are applied.")
                        if let odometer = item.record["odometer"] as? Double {
                            LabeledContent("Odometer", value: odometer.formatted())
                        }
                        if let fuel = item.record["fuelAmount"] as? Double {
                            LabeledContent("Fuel", value: fuel.formatted())
                        }
                        Picker(
                            "Incoming Units",
                            selection: Binding(
                                get: { selectedUnits[item.id] },
                                set: { selectedUnits[item.id] = $0 }
                            )
                        ) {
                            Text("Choose Units").tag(Optional<UnitSystem>.none)
                            ForEach(UnitSystem.allCases, id: \.self) { unit in
                                Text(unit.displayName).tag(Optional(unit))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("sync.review.units")
                    }
                    Button("Confirm Incoming Units") { confirmation = item }
                        .disabled(sourceUnit(for: item) == nil)
                        .accessibilityIdentifier("sync.review.confirm")
                }
            }
            if recovery.assessment.unitConfirmations.isEmpty { Text("No measurements need confirmation.") }
        }
        .navigationTitle("Confirm Measurement Units")
        .alert(
            "Confirm Incoming Units?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button("Apply") {
                if let unit = sourceUnit(for: item) {
                    perform { try await SyncReviewService.confirm(item, sourceUnit: unit, writer: writer) }
                }
                confirmation = nil
            }
        } message: { _ in
            Text(
                "Apply these changes using the units you selected? Your other records will keep their physical distances and fuel volumes."
            )
        }
        .alert(
            "Unable to Apply",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func sourceUnit(for item: SyncReviewService.Item) -> UnitSystem? {
        if item.isVehicle {
            return (item.record[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] as? String).flatMap(
                UnitSystem.init(rawValue:))
        }
        return selectedUnits[item.id]
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                recovery.reload(in: context)
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SyncDeletionReviewView: View {
    @EnvironmentObject private var writer: OwnedModelStore
    @Environment(\.modelContext) private var context
    @ObservedObject var recovery: SyncRecoveryModel
    @State private var showingDecision = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if recovery.assessment.legacyDeletionCount > 0 {
                Text(
                    "An older app left \(recovery.assessment.legacyDeletionCount) deletion request(s). Confirm whether these should remove data from iCloud."
                )
                Button("Review Previous Deletions") { showingDecision = true }
            } else {
                Text("No previous deletions need review.")
            }
        }
        .navigationTitle("Review Previous Deletions")
        .confirmationDialog(
            "Apply previous deletions to iCloud?", isPresented: $showingDecision, titleVisibility: .visible
        ) {
            Button("Keep iCloud Copies") { resolve(apply: false) }
            Button("Apply Previous Deletions", role: .destructive) { resolve(apply: true) }
        }
        .alert(
            "Unable to Apply",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func resolve(apply: Bool) {
        Task {
            do {
                try await SyncReviewService.resolveLegacyDeletions(apply: apply, writer: writer)
                recovery.reload(in: context)
            } catch { errorMessage = error.localizedDescription }

        }
    }
}

struct SyncDiagnosticsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var cloudSyncService: CloudSyncService
    @ObservedObject var recovery: SyncRecoveryModel

    var body: some View {
        List {
            Section {
                Text(
                    "These incoming changes could not be applied automatically. Your local records and the original incoming data have been kept."
                )
            }
            if let error = recovery.loadError { Text(error) }
            ForEach(recovery.assessment.diagnostics) { issue in
                Section(issue.title) { Text(issue.reason.explanation) }
            }
            Button("Retry Sync") {
                Task {
                    await cloudSyncService.synchronizeNow()
                    recovery.reload(in: context)
                }
            }
            .disabled(cloudSyncService.stateManager.syncStatus.isInProgress)
        }
        .navigationTitle("Sync Diagnostics")
    }
}
