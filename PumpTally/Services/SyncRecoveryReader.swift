import Combine
import Foundation
import SwiftData
import os

@MainActor
final class SyncRecoveryModel: ObservableObject {
    struct Source: Equatable {
        let revision: UInt64
        let isSyncing: Bool
    }
    typealias Load = @Sendable (ModelContainer) async throws -> SyncReviewService.Assessment

    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var assessment = SyncReviewService.Assessment()
    @Published private(set) var loadError: String?
    private let load: Load
    private var observedContainer: ModelContainer?
    private var saveObserver: AnyCancellable?
    private var reloadAttempt = UUID()
    private let saveGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(
        load: @escaping Load = { container in
            try await ModelStoreReader.read(container: container) {
                try SyncReviewService.assessment(in: $0.modelContext)
            }
        }
    ) { self.load = load }

    func reload(in context: ModelContext, revision expectedRevision: UInt64? = nil) async {
        let container = context.container
        observe(container)
        let requestedRevision = expectedRevision ?? revision
        let attempt = UUID()
        reloadAttempt = attempt
        let generation = saveGeneration.withLock { $0 }
        do {
            let result = try await load(container)
            guard !Task.isCancelled, reloadAttempt == attempt, revision == requestedRevision,
                saveGeneration.withLock({ $0 }) == generation
            else { return }
            assessment = result
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, reloadAttempt == attempt, revision == requestedRevision,
                saveGeneration.withLock({ $0 }) == generation
            else { return }
            loadError = String(localized: "Recovery information could not be loaded. Try again.")
        }
    }

    private func observe(_ container: ModelContainer) {
        guard observedContainer !== container else { return }
        saveObserver?.cancel()
        observedContainer = container
        saveObserver = ModelStoreChange.publisher(
            in: container, affecting: ["PendingRemoteChange", "SyncChange", "Vehicle", "FuelingRecord"]
        )
            .map { [generation = saveGeneration] _ in generation.withLock { $0 &+= 1 } }
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }
}
