import Combine
import Foundation
import SwiftData
import os

/// The composition root constructs the shared store and lifecycle dependencies.
@MainActor
struct ApplicationEnvironment {
    let writer: OwnedModelStore
    var modelContainer: ModelContainer { writer.container }
    let cloudSyncService: CloudSyncService
    let lifecycle: ApplicationLifecycleCoordinator
}

/// Owns opening the application's existing store before any model-dependent
/// views or lifecycle work can begin. Retry invokes the same factory again.
@MainActor
final class ApplicationEnvironmentLoader: ObservableObject {
    enum State {
        case notStarted, opening
        case failed(String)
        case ready(ApplicationEnvironment)
    }

    @Published private(set) var state = State.notStarted
    private let makeEnvironment: @MainActor () throws -> ApplicationEnvironment
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio", category: "App")

    init(makeEnvironment: @escaping @MainActor () throws -> ApplicationEnvironment) {
        self.makeEnvironment = makeEnvironment
    }

    func open() {
        switch state {
        case .opening, .ready: return
        case .notStarted, .failed: break
        }
        state = .opening
        do {
            state = .ready(try makeEnvironment())
        } catch {
            Self.logger.error("Could not create application environment: \(error)")
            state = .failed(String(localized: "Your saved data could not be opened. Please try again."))
        }
    }
}
