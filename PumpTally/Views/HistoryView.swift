import SwiftData
import SwiftUI

enum HistorySortOrder: String, CaseIterable, Sendable {
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"
    case costHighest = "Highest Cost"
    case costLowest = "Lowest Cost"

    var displayName: String {
        switch self {
        case .dateDescending: return String(localized: "Newest First")
        case .dateAscending: return String(localized: "Oldest First")
        case .costHighest: return String(localized: "Highest Cost")
        case .costLowest: return String(localized: "Lowest Cost")
        }
    }
}

struct HistoryRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let date: Date
    let totalCost: Double
    let odometer: Double
    let notes: String?

    @MainActor
    init(record: FuelingRecord) {
        id = record.id
        date = record.date
        totalCost = record.totalCost
        odometer = record.vehicle.displayUnitSystem.distanceValue(record.odometer, from: record.vehicle.unitSystem)
        notes = record.notes
    }

    init(id: UUID, date: Date, totalCost: Double, odometer: Double, notes: String?) {
        self.id = id
        self.date = date
        self.totalCost = totalCost
        self.odometer = odometer
        self.notes = notes
    }
}

enum HistoryRecordsQuery {
    static func recordIDs(
        from records: [HistoryRecordSnapshot],
        searchText: String,
        sortOrder: HistorySortOrder
    ) -> [UUID] {
        let query = searchText.lowercased()
        let filtered: [HistoryRecordSnapshot]

        if query.isEmpty {
            filtered = records
        } else {
            filtered = records.filter { record in
                if let notes = record.notes, notes.localizedCaseInsensitiveContains(query) {
                    return true
                }
                if String(format: "%.2f", record.totalCost).contains(query) {
                    return true
                }
                return String(format: "%.0f", record.odometer).contains(query)
            }
        }

        return filtered.sorted { lhs, rhs in
            switch sortOrder {
            case .dateDescending:
                return areInChronologicalOrder(rhs, lhs)
            case .dateAscending:
                return areInChronologicalOrder(lhs, rhs)
            case .costHighest:
                if lhs.totalCost != rhs.totalCost { return lhs.totalCost > rhs.totalCost }
                return areInChronologicalOrder(rhs, lhs)
            case .costLowest:
                if lhs.totalCost != rhs.totalCost { return lhs.totalCost < rhs.totalCost }
                return areInChronologicalOrder(lhs, rhs)
            }
        }.map(\.id)
    }

    private static func areInChronologicalOrder(
        _ lhs: HistoryRecordSnapshot,
        _ rhs: HistoryRecordSnapshot
    ) -> Bool {
        OdometerChronologyValidator.areInIncreasingOrder(
            lhsDate: lhs.date,
            lhsOdometer: lhs.odometer,
            lhsID: lhs.id,
            rhsDate: rhs.date,
            rhsOdometer: rhs.odometer,
            rhsID: rhs.id
        )
    }
}

struct HistoryView: View {
    let vehicle: Vehicle
    let records: [FuelingRecord]

    @EnvironmentObject private var writer: OwnedModelStore
    @AppStorage private var metricEfficiencyFormatRaw: String
    @State private var recordToEdit: FuelingRecordEditSelection?
    @State private var showingDeleteAlert = false
    @State private var showingDeleteError = false
    @State private var recordToDelete: UUID?
    @State private var searchText = ""
    @State private var sortOrder: HistorySortOrder = .dateDescending
    @State private var displayedRecordIDs: [UUID] = []

    init(vehicle: Vehicle, records: [FuelingRecord]) {
        self.vehicle = vehicle
        self.records = records
        _metricEfficiencyFormatRaw = AppStorage(
            wrappedValue: MetricEfficiencyFormat.defaultFormat.rawValue,
            MetricEfficiencyFormat.storageKey(for: vehicle.id)
        )
    }

    private var metricEfficiencyFormat: MetricEfficiencyFormat {
        MetricEfficiencyFormat(rawValue: metricEfficiencyFormatRaw) ?? .defaultFormat
    }

    private var hasRecords: Bool {
        !records.isEmpty
    }

    private struct QueryKey: Equatable, Sendable {
        let records: [HistoryRecordSnapshot]
        let searchText: String
        let sortOrder: HistorySortOrder
    }

    private var queryKey: QueryKey {
        QueryKey(
            records: records.map(HistoryRecordSnapshot.init(record:)), searchText: searchText, sortOrder: sortOrder)
    }

    var body: some View {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let displayedRecords = displayedRecordIDs.compactMap { recordsByID[$0] }
        Group {
            if !hasRecords {
                EmptyHistoryView()
            } else {
                List {
                    // Sort picker section
                    Section {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(HistorySortOrder.allCases, id: \.self) { order in
                                Text(order.displayName)
                                    .tag(order)
                            }
                        }
                        .font(.appSubheadline)
                    }

                    // Records section - use cached previousOdometer
                    Section {
                        ForEach(displayedRecords) { record in
                            FuelingRecordRow(
                                record: record,
                                previousOdometer: vehicle.displayUnitSystem.distanceValue(
                                    record.getPreviousOdometer(), from: vehicle.unitSystem),
                                efficiencyRaw: vehicle.displayUnitSystem.efficiencyValue(
                                    record.cachedEfficiency ?? 0, from: vehicle.unitSystem),
                                unitSystem: vehicle.displayUnitSystem,
                                metricEfficiencyFormat: metricEfficiencyFormat
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                recordToEdit = FuelingRecordEditSelection(record: record)
                            }
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
                    } header: {
                        Text("\(displayedRecords.count) records")
                            .font(.appCaption)
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "Search records")
            }
        }
        .task(id: queryKey) {
            await refreshDisplayedRecords(for: queryKey)
        }
        .sheet(item: $recordToEdit) { record in
            EditRecordView(selection: record, vehicle: vehicle, records: records)
        }
        .alert("Delete Record", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                recordToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let record = recordToDelete {
                    Task { await deleteRecord(record) }
                }
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

    @MainActor
    private func refreshDisplayedRecords(for key: QueryKey) async {
        // Debounce active searches. SwiftUI cancels this task when another
        // character, sort order, or data revision produces a new key.
        if !key.searchText.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }

        let snapshots = key.records
        let sortedIDs = await Task.detached(priority: .userInitiated) {
            HistoryRecordsQuery.recordIDs(
                from: snapshots,
                searchText: key.searchText,
                sortOrder: key.sortOrder
            )
        }.value

        guard !Task.isCancelled, key == queryKey else { return }
        displayedRecordIDs = sortedIDs
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
    let record: FuelingRecord
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
        unitSystem.distanceValue(record.getDistanceDriven(), from: record.vehicle.unitSystem)
    }

    private var hasEfficiency: Bool {
        efficiencyRaw > 0
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header with date and cost
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.appBody)
                        .fontWeight(.semibold)

                    Text(record.date.formatted(date: .omitted, time: .shortened))
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(record.totalCost.currencyFormatted)
                    .font(.appTitle3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }

            // Details row
            HStack(spacing: 16) {
                DetailChip(
                    icon: "fuelpump.fill",
                    value:
                        "\(unitSystem.fuelValue(record.fuelAmount, from: record.vehicle.unitSystem).formatted(.number.precision(.fractionLength(2)))) \(unitSystem.fuelUnit)",
                    color: .green
                )

                DetailChip(
                    icon: "dollarsign",
                    value:
                        "\(unitSystem.priceValue(record.pricePerFuelUnit, from: record.vehicle.unitSystem).formatted(.number.precision(.fractionLength(3))))\(unitSystem.pricePerFuelShort)",
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
                        "\(previousOdometer.formatted(.number.precision(.fractionLength(0)))) \u{2192} \(unitSystem.distanceValue(record.odometer, from: record.vehicle.unitSystem).formatted(.number.precision(.fractionLength(0)))) \(unitSystem.distanceUnit)"
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
                        "\(unitSystem.distanceValue(record.odometer, from: record.vehicle.unitSystem).formatted(.number.precision(.fractionLength(0)))) \(unitSystem.distanceUnit)"
                    )
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Show fill-up type badge for non-full fill-ups
                if !record.isFullFillUp {
                    FillUpTypeBadge(fillUpType: record.fillUpType)
                }
            }

            // Notes if present
            if let notes = record.notes, !notes.isEmpty {
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
    let schema = Schema(versionedSchema: SchemaV4.self)
    let container = try! ModelContainer(
        for: schema,
        configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    let writer = OwnedModelStore(container: container)
    return NavigationStack {
        HistoryView(vehicle: Vehicle(name: "Test Car"), records: [])
    }
    .modelContainer(container)
    .environmentObject(writer)
}
