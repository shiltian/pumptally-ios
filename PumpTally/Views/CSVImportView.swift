import SwiftData
import SwiftUI
import os

struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss

    let fileURL: URL
    let vehicles: [Vehicle]
    let onImport: @MainActor (Int) -> Void
    @EnvironmentObject private var writer: OwnedModelStore
    @EnvironmentObject private var cloudSyncService: CloudSyncService
    @State private var sourceUnit: UnitSystem?
    @State private var preparation: Preparation = .idle
    @State private var duplicateDecision: CSVImportDuplicateDecision?

    private enum Preparation {
        case idle, preparing
        case ready(Request, CSVImportPlan)
        case failed(String)
    }

    private struct Request: Hashable {
        let vehicleID: UUID
        let sourceUnit: UnitSystem
        let recordIDs: [UUID]
    }

    private var request: Request? {
        guard let selectedVehicleID, let sourceUnit, !parsedRecords.isEmpty else { return nil }
        return Request(vehicleID: selectedVehicleID, sourceUnit: sourceUnit, recordIDs: parsedRecords.map(\.id))
    }

    private var plan: CSVImportPlan? {
        if case .ready(let prepared, let plan) = preparation, prepared == request { return plan }
        return nil
    }

    @State private var csvContent: String = ""
    @State private var parsedRecords: [CSVImportRecordSnapshot] = []
    @State private var selectedVehicleID: UUID?
    @State private var isImporting = false
    @State private var isLoading = true
    @State private var parseError: String?
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var previewLines: [String] = []
    private var importSummary: ImportSummary {
        ImportSummary(records: plan?.selectedRecords(duplicateDecision ?? .importAll) ?? parsedRecords)
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "CSVImport"
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Loading CSV file...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = parseError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("Error Reading File")
                            .font(.appTitle3)
                            .fontWeight(.semibold)

                        Text(error)
                            .font(.appSubheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // File Info Section
                            fileInfoSection

                            // Preview Section
                            previewSection

                            // Vehicle Selection Section
                            if !vehicles.isEmpty {
                                vehicleSelectionSection
                            } else {
                                noVehicleWarning
                            }

                            sourceUnitsSection
                            importSummarySection
                            reviewSection
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await importSelectedRecords() } }
                        .accessibilityIdentifier("csv.import")
                        .disabled(
                            plan == nil || (plan?.possibleDuplicateIDs.isEmpty == false && duplicateDecision == nil))
                }
            }
            .task { await loadAndParseCSV() }
            .task(id: request) { await prepareImport() }
            .onChange(of: vehicles.map(\.id), initial: true) { _, ids in
                if selectedVehicleID == nil { selectedVehicleID = ids.first }
            }
            .alert("Import Failed", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? String(localized: "Unable to import the selected records."))
            }
        }
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
    }

    // MARK: - View Components

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("File Information", systemImage: "doc.text")
                .font(.appBody)
                .fontWeight(.semibold)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileURL.lastPathComponent)
                        .font(.appSubheadline)
                        .fontWeight(.medium)

                    Text("\(parsedRecords.count) records found")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .opacity(parsedRecords.isEmpty ? 0 : 1)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Data Preview", systemImage: "eye")
                .font(.appBody)
                .fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(previewLines.indices.prefix(6), id: \.self) { index in
                        Text(previewLines[index])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if previewLines.count > 6 {
                        Text("... and \(previewLines.count - 6) more rows")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                .padding()
            }
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private var vehicleSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Select Vehicle", systemImage: "car")
                .font(.appBody)
                .fontWeight(.semibold)

            Text("Choose which vehicle to import the records to:")
                .font(.appCaption)
                .foregroundColor(.secondary)

            ForEach(vehicles) { vehicle in
                Button {
                    selectedVehicleID = vehicle.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vehicle.name)
                                .font(.appSubheadline)
                                .fontWeight(.medium)

                            if let make = vehicle.make, let model = vehicle.model {
                                Text("\(make) \(model)")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if selectedVehicleID == vehicle.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.teal)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selectedVehicleID == vehicle.id ? Color.teal.opacity(0.1) : Color(.systemGray6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selectedVehicleID == vehicle.id ? Color.teal : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var noVehicleWarning: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundColor(.orange)

            Text("No Vehicles Found")
                .font(.appBody)
                .fontWeight(.semibold)

            Text("Please add a vehicle first before importing records.")
                .font(.appSubheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    private var importSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import Summary", systemImage: "list.bullet.clipboard")
                .font(.appBody)
                .fontWeight(.semibold)

            let summary = importSummary
            if summary.totalRecords > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    SummaryRow(label: "Total Records", value: "\(summary.totalRecords)")

                    if let firstDate = summary.firstDate,
                        let lastDate = summary.lastDate
                    {
                        SummaryRow(label: "Date Range", value: "\(formatDate(firstDate)) - \(formatDate(lastDate))")
                    }

                    SummaryRow(
                        label: "Total Fuel",
                        value: summary.totalFuel.formatted(.number.precision(.fractionLength(2)))
                            + " " + (plan?.revision.storageUnit.fuelUnit ?? sourceUnit?.fuelUnit ?? ""))

                    SummaryRow(label: "Total Cost", value: String(format: "$%.2f", summary.totalCost))
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
        }
    }

    private var sourceUnitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Units in This CSV").font(.appBody).fontWeight(.semibold)
            Text("CSV files do not include measurement units. Choose the units used by the original records.")
                .font(.appCaption).foregroundStyle(.secondary)
            Picker("CSV Units", selection: $sourceUnit) {
                Text("Choose Units").tag(UnitSystem?.none)
                Text("Miles and US Gallons").tag(UnitSystem?.some(.imperial))
                Text("Kilometers and Liters").tag(UnitSystem?.some(.metric))
            }
            .accessibilityIdentifier("csv.units")
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder private var reviewSection: some View {
        switch preparation {
        case .idle: EmptyView()
        case .preparing: ProgressView("Reviewing Import…")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Review Again") { Task { await prepareImport() } }
        case .ready(_, let plan):
            Text(
                "Measurements will be stored in \(plan.revision.storageUnit.distanceUnit) and \(plan.revision.storageUnit.fuelUnit)."
            )
            .font(.appCaption).foregroundStyle(.secondary)
            if let duplicateDecision {
                Text("\(plan.selectedRecords(duplicateDecision).count) records will be imported.").font(.appCaption)
            }
            if !plan.possibleDuplicateIDs.isEmpty {
                Text("\(plan.possibleDuplicateIDs.count) possible duplicate rows").font(.headline)
                Text(
                    "These rows match existing records or earlier rows in this file. CSV files do not contain record IDs, so matching rows may still be separate fill-ups."
                )
                .font(.appCaption).foregroundStyle(.secondary)
                Picker("Possible Duplicates", selection: $duplicateDecision) {
                    Text("Choose an Action").tag(CSVImportDuplicateDecision?.none)
                    Text("Skip Possible Duplicates").tag(CSVImportDuplicateDecision?.some(.skipPossibleDuplicates))
                    Text("Import All Rows").tag(CSVImportDuplicateDecision?.some(.importAll))
                }.accessibilityIdentifier("csv.duplicates").pickerStyle(.menu)
                ForEach(plan.records.filter { plan.possibleDuplicateIDs.contains($0.id) }.prefix(10)) { row in
                    Text(
                        "Row \(row.lineNumber): \(formatDate(row.date)), \(row.odometer.formatted()) \(plan.revision.storageUnit.distanceUnit)"
                    )
                    .font(.appCaption)
                }
            }
        }
    }

    private func prepareImport() async {
        guard let request else { preparation = .idle; return }
        preparation = .preparing
        duplicateDecision = nil
        do {
            let plan = try await FuelingRecordPersistenceService(writer: writer).prepareImport(
                parsedRecords, vehicleID: request.vehicleID, sourceUnit: request.sourceUnit)
            try Task.checkCancellation()
            preparation = .ready(request, plan)
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            preparation = .failed(error.localizedDescription)
        }
    }

    private func importSelectedRecords() async {
        guard !isImporting, let plan else { return }
        guard plan.possibleDuplicateIDs.isEmpty || duplicateDecision != nil else { return }
        let decision = duplicateDecision ?? .importAll
        isImporting = true
        defer { isImporting = false }
        do {
            let ids = try await cloudSyncService.withLocalPushesSuspended {
                try await FuelingRecordPersistenceService(writer: writer).importRecords(
                    plan: plan, duplicates: decision)
            }
            onImport(ids.count)
            Task { await cloudSyncService.pushPendingLocalChanges() }
            dismiss()
        } catch {
            Self.logger.error("Failed to save CSV import: \(error)")
            importError =
                (error as? CSVImportError)?.localizedDescription
                ?? CSVImportError.persistenceFailed.localizedDescription
            showingImportError = true
            // A stale decision must be reviewed again before it can be submitted.
            if let error = error as? CSVImportError, error == .stalePlan {
                preparation = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Helper Methods

    private func loadAndParseCSV() async {
        let url = fileURL

        do {
            let parsed = try await Task.detached(priority: .userInitiated) {
                let content = try String(contentsOf: url, encoding: .utf8)
                let records = try CSVImportService.parse(content)
                return (content: content, records: records)
            }.value
            try Task.checkCancellation()
            csvContent = parsed.content

            // Store preview lines
            previewLines = csvContent.components(separatedBy: .newlines).filter { !$0.isEmpty }

            parsedRecords = parsed.records

            isLoading = false
        } catch let error as CSVImportError {
            parseError = error.localizedDescription
            isLoading = false
        } catch {
            Self.logger.error("Failed to read CSV file: \(error)")
            parseError = String(localized: "Unable to read the selected file. Please make sure it is a valid CSV file.")
            isLoading = false
        }
    }

    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    private func formatDate(_ date: Date) -> String {
        Self.mediumDateFormatter.string(from: date)
    }
}

private struct ImportSummary {
    let totalRecords: Int
    let firstDate: Date?
    let lastDate: Date?
    let totalFuel: Double
    let totalCost: Double

    init(records: [CSVImportRecordSnapshot]) {
        totalRecords = records.count
        firstDate = records.map(\.date).min()
        lastDate = records.map(\.date).max()
        totalFuel = records.reduce(0) { $0 + $1.fuelAmount }
        totalCost = records.reduce(0) { $0 + $1.totalCost }
    }
}

// MARK: - Supporting Views

private struct SummaryRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.appSubheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.appSubheadline)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    CSVImportView(
        fileURL: URL(fileURLWithPath: "/example.csv"),
        vehicles: [],
        onImport: { _ in }
    )
}
