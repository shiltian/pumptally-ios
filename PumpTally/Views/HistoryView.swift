import SwiftData
import SwiftUI

/// Search has its own native navigation destination, leaving the tab contents
/// and their loaded pages in place. Both screens share the same value catalog.
struct VehicleHistorySearchView: View {
    let vehicle: Vehicle
    @ObservedObject var history: VehicleHistoryModel
    @State private var searchText = ""
    @State private var searchPresented = false
    @AppStorage private var metricEfficiencyFormatRaw: String

    init(vehicle: Vehicle, history: VehicleHistoryModel) {
        self.vehicle = vehicle
        self.history = history
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id))
    }

    private struct Key: Equatable {
        let revision: UInt64
        let format: MetricEfficiencyFormat
    }

    var body: some View {
        let format = MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
        let key = Key(revision: history.revision, format: format)
        Group {
            if history.failed {
                ContentUnavailableView {
                    Label("Unable to Load History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your fueling history could not be loaded. Please try again.")
                } actions: {
                    Button("Try Again", action: history.retry).buttonStyle(.borderedProminent)
                }
            } else if history.presentation != nil {
                HistoryView(vehicle: vehicle, history: history, metricEfficiencyFormat: format, searchText: $searchText)
            } else {
                ProgressView("Preparing your data…")
            }
        }
        .navigationTitle("Search records")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText, isPresented: $searchPresented,
            placement: .navigationBarDrawer(displayMode: .always), prompt: "Search records"
        )
        .onAppear { searchPresented = true }
        .task(id: key) { await history.reload(revision: key.revision, format: key.format) }
    }
}

struct HistoryView: View {
    let vehicle: Vehicle
    @ObservedObject var history: VehicleHistoryModel
    let metricEfficiencyFormat: MetricEfficiencyFormat
    @EnvironmentObject private var writer: OwnedModelStore
    @State private var recordToEdit: FuelingRecordEditSelection?
    @State private var showingDeleteAlert = false
    @State private var showingDeleteError = false
    @State private var recordToDelete: UUID?
    @Binding var searchText: String
    @State private var sortOrder: HistorySortOrder = .dateDescending
    @State private var displayedRecords: [FuelingHistoryRecord] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var pageAttempt = UUID()
    @State private var displayedQuery: VehicleHistoryRepository.Query?

    private struct QueryKey: Equatable {
        let version: UUID?
        let query: VehicleHistoryRepository.Query
    }
    private var queryKey: QueryKey {
        QueryKey(
            version: history.presentation?.version,
            query: .init(searchText: searchText, sortOrder: sortOrder))
    }

    var body: some View {
        let key = queryKey
        Group {
            if history.presentation?.recordCount == 0 {
                EmptyHistoryView()
            } else {
                List {
                    Section {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(HistorySortOrder.allCases, id: \.self) { order in
                                Text(order.displayName).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("history.sort")
                        .font(.appSubheadline)
                    }
                    Section {
                        ForEach(displayedRecords) { record in
                            FuelingRecordRow(
                                record: record,
                                previousOdometer: vehicle.displayUnitSystem.distanceValue(
                                    record.previousOdometer, from: record.storageUnit),
                                efficiencyRaw: vehicle.displayUnitSystem.efficiencyValue(
                                    record.cachedEfficiency ?? 0, from: record.storageUnit),
                                unitSystem: vehicle.displayUnitSystem,
                                metricEfficiencyFormat: metricEfficiencyFormat
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { recordToEdit = FuelingRecordEditSelection(record: record) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    recordToDelete = record.id
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    recordToEdit = FuelingRecordEditSelection(record: record)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if displayedRecords.count < totalCount {
                            Button("Load More") {
                                let key = queryKey
                                let offset = displayedRecords.count
                                Task { await loadPage(for: key, offset: offset) }
                            }
                            .accessibilityIdentifier("history.loadMore")
                        }
                    } header: {
                        Text("\(totalCount) records").font(.appCaption)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .task(id: key) { await loadPage(for: key, offset: 0) }
        .sheet(item: $recordToEdit) { record in
            FuelingRecordEditorView(vehicle: vehicle, selection: record)
        }
        .alert("Delete Record", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { recordToDelete = nil }
            Button("Delete", role: .destructive) {
                if let record = recordToDelete { Task { await deleteRecord(record) } }
            }
        } message: {
            Text("Are you sure you want to delete this fueling record? This action cannot be undone.")
        }
        .alert("Unable to Delete", isPresented: $showingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The record could not be deleted. No data was changed. Please try again.")
        }
    }

    private func loadPage(for key: QueryKey, offset: Int) async {
        if offset > 0 && isLoading { return }
        let attempt = UUID()
        pageAttempt = attempt
        isLoading = true
        let restoringCount =
            displayedQuery == key.query ? max(VehicleHistoryPage.size, displayedRecords.count) : VehicleHistoryPage.size
        if offset == 0 && displayedQuery != key.query { displayedRecords = []; totalCount = 0 }
        defer { if pageAttempt == attempt { isLoading = false } }
        guard let version = key.version else { return }
        if offset == 0 && !key.query.searchText.isEmpty {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        var records: [FuelingHistoryRecord] = []
        var matchedCount = 0
        repeat {
            guard let page = await history.page(version: version, query: key.query, offset: offset + records.count),
                !Task.isCancelled, key == queryKey, pageAttempt == attempt
            else { return }
            records.append(contentsOf: page.records)
            matchedCount = page.totalCount
            if page.records.isEmpty { break }
        } while offset == 0 && records.count < restoringCount && records.count < matchedCount
        if offset == 0 { displayedRecords = records } else { displayedRecords.append(contentsOf: records) }
        displayedQuery = key.query
        totalCount = matchedCount
    }

    private func deleteRecord(_ recordID: UUID) async {
        do {
            try await FuelingRecordPersistenceService(writer: writer).delete(recordID: recordID)
            recordToDelete = nil
        } catch {
            recordToDelete = nil
            showingDeleteError = true
        }
    }
}

struct FuelingRecordRow: View {
    let record: FuelingHistoryRecord
    let previousOdometer: Double
    let efficiencyRaw: Double
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    private var efficiencyDisplay: Double {
        unitSystem.efficiencyDisplayValue(
            from: efficiencyRaw,
            metricFormat: metricEfficiencyFormat
        )
    }

    private var distanceDriven: Double {
        unitSystem.distanceValue(record.distanceDriven, from: record.storageUnit)
    }

    private var hasEfficiency: Bool {
        efficiencyRaw > 0
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header with date and cost
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.values.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.appBody)
                        .fontWeight(.semibold)

                    Text(record.values.date.formatted(date: .omitted, time: .shortened))
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(record.values.totalCost.currencyFormatted)
                    .font(.appTitle3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }

            // Details row
            HStack(spacing: 16) {
                DetailChip(
                    icon: "fuelpump.fill",
                    value:
                        "\(unitSystem.fuelValue(record.values.fuelAmount, from: record.storageUnit).formatted(.number.precision(.fractionLength(2)))) \(unitSystem.fuelUnit)",
                    color: .green
                )

                DetailChip(
                    icon: "dollarsign",
                    value:
                        "\(unitSystem.priceValue(record.values.pricePerFuelUnit, from: record.storageUnit).formatted(.number.precision(.fractionLength(3))))\(unitSystem.pricePerFuelShort)",
                    color: .orange
                )

                // Only show efficiency for full fill-ups with valid previous record
                if hasEfficiency {
                    DetailChip(
                        icon: "gauge",
                        value:
                            "\(efficiencyDisplay.formatted(.number.precision(.fractionLength(1)))) \(unitSystem.efficiencyUnit(for: metricEfficiencyFormat))",
                        color: .purple
                    )
                }

                Spacer()
            }

            // Odometer info
            HStack {
                Image(systemName: "speedometer")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if previousOdometer > 0 {
                    Text(
                        "\(previousOdometer.formatted(.number.precision(.fractionLength(0)))) \u{2192} \(unitSystem.distanceValue(record.values.odometer, from: record.storageUnit).formatted(.number.precision(.fractionLength(0)))) \(unitSystem.distanceUnit)"
                    )
                    .font(.appCaption)
                    .foregroundColor(.secondary)

                    Text(
                        "(\(distanceDriven.formatted(.number.precision(.fractionLength(0)))) \(unitSystem.distanceName.lowercased()))"
                    )
                    .font(.appCaption)
                    .foregroundColor(.secondary.opacity(0.8))
                } else {
                    Text(
                        "\(unitSystem.distanceValue(record.values.odometer, from: record.storageUnit).formatted(.number.precision(.fractionLength(0)))) \(unitSystem.distanceUnit)"
                    )
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Show fill-up type badge for non-full fill-ups
                if record.values.fillUpType != .full {
                    FillUpTypeBadge(fillUpType: record.values.fillUpType)
                }
            }

            // Notes if present
            if let notes = record.values.notes, !notes.isEmpty {
                HStack {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(notes)
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct DetailChip: View {
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)

            Text(value)
                .font(.appCaption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct FillUpTypeBadge: View {
    let fillUpType: FillUpType

    private var label: String {
        switch fillUpType {
        case .full: return String(localized: "Full")
        case .partial: return String(localized: "Partial")
        case .reset: return String(localized: "Missed")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fillUpType.icon)
                .font(.caption2)
            Text(label)
                .font(.appCaption2)
        }
        .foregroundColor(fillUpType.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(fillUpType.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Fueling History")
                .font(.appTitle3)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            Text("Your fueling records will appear here")
                .font(.appSubheadline)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    let schema = Schema(versionedSchema: SchemaV5.self)
    let container = try! ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    let vehicle = Vehicle(name: "Test Car")
    container.mainContext.insert(vehicle)
    try! container.mainContext.save()
    let writer = OwnedModelStore(container: container)
    let history = VehicleHistoryModel(container: container, vehicleID: vehicle.id)
    return NavigationStack {
        HistoryView(
            vehicle: vehicle, history: history,
            metricEfficiencyFormat: .defaultFormat, searchText: .constant("")
        )
        .task { await history.reload(revision: history.revision, format: .defaultFormat) }
    }
    .modelContainer(container)
    .environmentObject(writer)
}
