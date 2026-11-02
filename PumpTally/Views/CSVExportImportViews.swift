import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - CSV File Document

/// A simple `FileDocument` wrapper for CSV content, used with `.fileExporter`.
/// This bypasses the share sheet entirely, avoiding LaunchServices warnings.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
}

// MARK: - Export/Import Views

struct ExportCSVView: View {
    let vehicle: Vehicle
    @Environment(\.dismiss) private var dismiss
    @State private var csvDocument: CSVDocument?
    @State private var showingExporter = false
    @State private var showingSuccess = false
    @State private var isPreparingExport = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "CSVExport"
    )

    private var defaultFileName: String {
        "\(vehicle.displayName.replacingOccurrences(of: " ", with: "_"))_fuel_records"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "doc.text")
                    .font(.system(size: 60))
                    .foregroundColor(.teal)

                Text("Export Fueling Data")
                    .font(.appTitle)
                    .fontWeight(.bold)

                Text("Export \(vehicle.displayRecordCount) records as a CSV file")
                    .font(.appBody)
                    .foregroundColor(.secondary)

                Button(action: prepareExport) {
                    if isPreparingExport {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Label("Save to Files", systemImage: "folder")
                            .font(.appButton)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(LinearGradient.brandHorizontal)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(isPreparingExport || vehicle.displayRecordCount == 0)
                .padding(.horizontal, 40)

                Spacer()
            }
            .padding(.top, 60)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: csvDocument,
                contentType: .commaSeparatedText,
                defaultFilename: defaultFileName
            ) { result in
                switch result {
                case .success:
                    showingSuccess = true
                case .failure(let error):
                    Self.logger.error("Export error: \(error)")
                }
            }
            .alert("Export Successful", isPresented: $showingSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("CSV file saved successfully.")
            }
        }
    }

    private func prepareExport() {
        isPreparingExport = true
        let snapshots = (vehicle.fuelingRecords ?? []).map(CSVService.RecordSnapshot.init(record:))

        Task {
            let content = await Task.detached(priority: .userInitiated) {
                CSVService.exportRecords(snapshots)
            }.value

            csvDocument = CSVDocument(content: content)
            showingExporter = true
            isPreparingExport = false
        }
    }
}

struct ImportCSVView: View {
    let vehicle: Vehicle
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false
    @State private var selectedFile: CSVImportFile?
    @State private var pendingImportedCount: Int?
    @State private var isImporting = false
    @State private var importedCount = 0
    @State private var showingSuccess = false
    @State private var errorMessage: String?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "CSVImport"
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 60))
                    .foregroundColor(.teal)

                Text("Import Fueling Data")
                    .font(.appTitle)
                    .fontWeight(.bold)

                Text("Select a CSV file to import fueling records")
                    .font(.appBody)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: { showingFilePicker = true }) {
                    Label("Choose File", systemImage: "folder")
                        .font(.appButton)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(LinearGradient.brandHorizontal)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 40)

                if let error = errorMessage {
                    Text(error)
                        .font(.appSubheadline)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                Spacer()
            }
            .padding(.top, 60)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.commaSeparatedText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(
                item: $selectedFile,
                onDismiss: {
                    if let count = pendingImportedCount {
                        importedCount = count
                        pendingImportedCount = nil
                        showingSuccess = true
                    }
                }
            ) { file in
                CSVImportView(fileURL: file.url, vehicles: [vehicle]) { count in
                    pendingImportedCount = count
                }
            }
            .alert("Import Successful", isPresented: $showingSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Successfully imported \(importedCount) records.")
            }
        }
        .disabled(isImporting)
        .interactiveDismissDisabled(isImporting)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard !isImporting else { return }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            isImporting = true
            Task {
                defer { isImporting = false }
                do {
                    selectedFile = try await CSVImportFile.stage(url)
                } catch {
                    Self.logger.error("Failed to stage CSV file: \(error)")
                    errorMessage = String(localized: "Unable to open the selected file. Please try again.")
                }
            }

        case .failure(let error):
            Self.logger.error("File picker failed: \(error)")
            errorMessage = String(localized: "Unable to open the selected file. Please try again.")
        }
    }
}
