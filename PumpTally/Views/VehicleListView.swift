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
    @Query private var latestRecords: [FuelingRecord]

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        let id = vehicle.id
        var descriptor = FetchDescriptor<FuelingRecord>(
            predicate: #Predicate { $0.vehicleRelationship?.id == id },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        _latestRecords = Query(descriptor)
    }

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

                if let lastRecord = latestRecords.first {
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
    @StateObject private var history: VehicleHistoryModel
    @AppStorage private var metricEfficiencyFormatRaw: String
    private enum Tab: Hashable { case dashboard, history }
    @State private var selectedTab = Tab.dashboard

    init(vehicle: Vehicle, container: ModelContainer) {
        self.vehicle = vehicle
        _history = StateObject(wrappedValue: VehicleHistoryModel(container: container, vehicleID: vehicle.id))
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id))
    }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    private struct ReadKey: Equatable {
        let revision: UInt64
        let format: MetricEfficiencyFormat
    }
    private var readKey: ReadKey { ReadKey(revision: history.revision, format: metricEfficiencyFormat) }

    private enum Sheet: Identifiable {
        case addRecord(UUID)
        case summary(FuelingSummaryData)
        case settings(UUID)

        var id: UUID {
            switch self {
            case .addRecord(let id), .settings(let id): return id
            case .summary(let data): return data.id
            }
        }
    }

    @State private var activeSheet: Sheet?
    @State private var pendingSummary: FuelingSummaryData?

    var body: some View {
        let key = readKey
        Group {
            if history.failed {
                ContentUnavailableView {
                    Label("Unable to Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your fueling history could not be loaded. Please try again.")
                } actions: {
                    Button("Try Again", action: history.retry).buttonStyle(.borderedProminent)
                }
            } else if let data = history.presentation {
                TabView(selection: $selectedTab) {
                    DashboardView(vehicle: vehicle, data: data, metricEfficiencyFormat: metricEfficiencyFormat)
                        .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                        .tag(Tab.dashboard)
                    HistoryView(
                        vehicle: vehicle, history: history, metricEfficiencyFormat: metricEfficiencyFormat,
                        searchText: .constant("")
                    )
                    .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                    .tag(Tab.history)
                }
            } else {
                ProgressView("Preparing your data…")
            }
        }
        .task(id: key) { await history.reload(revision: key.revision, format: key.format) }
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    VehicleHistorySearchView(vehicle: vehicle, history: history)
                } label: {
                    Label("Search records", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: presentAddRecord) {
                        Label("Add Fueling", systemImage: "plus")
                    }

                    Divider()

                    Button {
                        pendingSummary = nil
                        activeSheet = .settings(UUID())
                    } label: {
                        Label("Vehicle Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("vehicle.actions")
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: presentAddRecord) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(LinearGradient.brandDiagonal)
                }
                .accessibilityIdentifier("fueling.add")
            }
        }
        .sheet(item: $activeSheet, onDismiss: presentPendingSummary) { destination in
            switch destination {
            case .addRecord(let session):
                FuelingRecordEditorView(vehicle: vehicle) { record in
                    guard case .addRecord(let currentSession) = activeSheet, currentSession == session else { return }
                    pendingSummary = FuelingSummaryData(
                        record: record,
                        unitSystem: vehicle.displayUnitSystem,
                        metricEfficiencyFormat: .stored(for: vehicle.id))
                }
            case .summary(let summary):
                FuelingSummaryPopup(data: summary)
            case .settings:
                VehicleSettingsView(vehicle: vehicle)
            }
        }
        .onDisappear {
            pendingSummary = nil
            activeSheet = nil
        }
    }

    private func presentAddRecord() {
        pendingSummary = nil
        activeSheet = .addRecord(UUID())
    }

    private func presentPendingSummary() {
        let summary = pendingSummary
        pendingSummary = nil
        // SwiftUI calls this after dismissal. Another destination or leaving
        // this vehicle cancels the handoff instead of scheduling a later popup.
        guard activeSheet == nil, let summary else { return }
        activeSheet = .summary(summary)
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
    return NavigationStack {
        VehicleListView(
            vehicles: [],
            showingAddVehicle: .constant(false)
        )
    }
    .modelContainer(container)
    .environmentObject(writer)
}
