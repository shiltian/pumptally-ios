import Combine
import SwiftData

@MainActor
protocol ApplicationSync: AnyObject {
    var stateManager: SyncStateManager { get }
    func checkiCloudAvailability() async -> Bool
    func startMonitoring() async
    func synchronizeNow() async
}

extension CloudSyncService: ApplicationSync {}

/// Shared by every composition root. Only dependency construction differs
/// between the shipping app and the isolated test application.
@MainActor
final class ApplicationLifecycleCoordinator: ObservableObject {
    enum Startup: Equatable {
        case notStarted, initializing, ready
        case failed(String)
    }
    @Published private(set) var startup = Startup.notStarted
    private let container: ModelContainer
    private let syncService: any ApplicationSync
    private let initializeStore: @MainActor (ModelContainer) async throws -> Void

    init(
        writer: OwnedModelStore,
        syncService: any ApplicationSync,
        initializeStore: (@MainActor (ModelContainer) async throws -> Void)? = nil
    ) {
        self.container = writer.container
        self.syncService = syncService
        self.initializeStore =
            initializeStore ?? { _ in
                _ = try await StatisticsCachePersistenceService(writer: writer).rebuildIfNeeded()
            }
    }

    func start() async {
        switch startup {
        case .initializing, .ready: return
        case .notStarted, .failed: break
        }
        startup = .initializing
        do {
            try await initializeStore(container)
            try Task.checkCancellation()
        } catch is CancellationError {
            startup = .notStarted
            return
        } catch {
            startup = .failed(error.localizedDescription)
            syncService.stateManager.syncStatus = .error(error.localizedDescription)
            return
        }
        startup = .ready
        let state = syncService.stateManager
        state.syncStatus = .idle
        if state.iCloudSyncEnabled && !state.initialSyncCompleted {
            state.iCloudSyncEnabled = false
            state.syncStatus = .idle
            return
        }
        await synchronizeCloudChanges()
    }

    func didBecomeActive() async {
        guard startup == .ready else { return }
        await synchronizeCloudChanges()
    }

    private func synchronizeCloudChanges() async {
        let state = syncService.stateManager
        guard state.iCloudSyncEnabled && state.initialSyncCompleted,
            await syncService.checkiCloudAvailability(),
            state.iCloudSyncEnabled && state.initialSyncCompleted
        else { return }
        await syncService.startMonitoring()
        await syncService.synchronizeNow()
    }
}
