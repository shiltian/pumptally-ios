import SwiftData
import SwiftUI
import os

/// Editing and sync settings become available only after local initialization
/// succeeds. Retry uses the same lifecycle as the initial launch.
struct ApplicationStartupView<Content: View>: View {
    @ObservedObject var lifecycle: ApplicationLifecycleCoordinator
    private let content: () -> Content

    init(lifecycle: ApplicationLifecycleCoordinator, @ViewBuilder content: @escaping () -> Content) {
        self.lifecycle = lifecycle
        self.content = content
    }

    var body: some View {
        Group {
            switch lifecycle.startup {
            case .notStarted, .initializing:
                ProgressView("Preparing your data…")
                    .accessibilityIdentifier("startup.preparing")
            case .failed(let message):
                ApplicationStartupFailureView(message: message) {
                    Task { await lifecycle.start() }
                }
            case .ready:
                content()
            }
        }
        .task { await lifecycle.start() }
    }
}

private struct ApplicationStartupFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Prepare Your Data", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("startup.retry")
        }
    }
}

struct CSVImportFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    static func stage(_ source: URL) async throws -> CSVImportFile {
        try await Task.detached(priority: .userInitiated) { try copy(source) }.value
    }

    nonisolated private static func copy(_ source: URL) throws -> CSVImportFile {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return CSVImportFile(url: destination)
    }
}

/// Each window owns its document request. Item-based presentation delivers the
/// prepared URL with the sheet instead of coordinating a Boolean with a URL.
struct ApplicationRootView: View {
    @ObservedObject var loader: ApplicationEnvironmentLoader
    @State private var incomingFile: CSVImportFile?
    @State private var preparedImport: CSVImportFile?
    @State private var importError: String?

    private static let logger = Logger(subsystem: "me.tianshilei.fuelio", category: "CSVImport")

    var body: some View {
        Group {
            switch loader.state {
            case .notStarted, .opening:
                ProgressView("Preparing your data…")
                    .accessibilityIdentifier("startup.preparing")
            case .failed(let message):
                ApplicationStartupFailureView(message: message, retry: loader.open)
            case .ready(let environment):
                ApplicationStartupView(lifecycle: environment.lifecycle) {
                    ContentView(importedFile: $preparedImport)
                }
                .environmentObject(environment.cloudSyncService)
                .environmentObject(environment.writer)
                .modelContainer(environment.modelContainer)
            }
        }
        .task { loader.open() }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "csv" else { return }
            incomingFile = CSVImportFile(url: url)
        }
        .task(id: incomingFile?.id) {
            guard let file = incomingFile else { return }
            do {
                let prepared = try await CSVImportFile.stage(file.url)
                try Task.checkCancellation()
                preparedImport = prepared
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("Failed to prepare CSV import: \(error)")
                importError = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard case .ready(let environment) = loader.state else { return }
            Task { await environment.lifecycle.didBecomeActive() }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

}
