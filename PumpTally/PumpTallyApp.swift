import SwiftUI
import SwiftData
import os

@main
struct PumpTallyApp: App {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "App"
    )

    @StateObject private var cloudSyncService: CloudSyncService
    private let environment: ApplicationEnvironment

    init() {
        do {
            let environment = try AppBootstrap.makeEnvironment()
            self.environment = environment
            _cloudSyncService = StateObject(wrappedValue: environment.cloudSyncService)
        } catch {
            Self.logger.fault("Could not create application environment: \(error)")
            fatalError("Could not create application environment: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ApplicationRootView(environment: environment)
                .environmentObject(cloudSyncService)
                .environmentObject(environment.writer)
        }
        .modelContainer(environment.modelContainer)
    }

}
