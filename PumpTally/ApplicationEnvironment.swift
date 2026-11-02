import SwiftData

/// The composition root constructs the shared store and lifecycle dependencies.
@MainActor
struct ApplicationEnvironment {
    let writer: OwnedModelStore
    var modelContainer: ModelContainer { writer.container }
    let cloudSyncService: CloudSyncService
    let lifecycle: ApplicationLifecycleCoordinator
}
