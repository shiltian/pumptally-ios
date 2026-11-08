import Combine
import Foundation
import SwiftData
import os

/// Only immutable review values leave this fresh, read-only native context.
actor SyncRecoveryReader: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    private init(container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    static func read<Result: Sendable>(
        container: ModelContainer,
        _ operation: @escaping @Sendable (isolated SyncRecoveryReader) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let reader = SyncRecoveryReader(container: container)
            return try await reader.perform(operation)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform<Result: Sendable>(
        _ operation: @Sendable (isolated SyncRecoveryReader) throws -> Result
    ) rethrows -> Result { try operation(self) }
}

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
            try await SyncRecoveryReader.read(container: container) {
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
        saveObserver = NotificationCenter.default.publisher(for: ModelContext.didSave)
            .merge(with: NotificationCenter.default.publisher(for: ModelStoreChange.didCommit))
            .filter { Self.isRelevant($0, container: container) }
            .map { [generation = saveGeneration] _ in generation.withLock { $0 &+= 1 } }
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.revision &+= 1 }
    }

    /// Context inspection is synchronous on the saving executor, before only
    /// a value invalidation is sent to MainActor. Checkpoints do not rerun review.
    nonisolated private static func isRelevant(_ notification: Notification, container: ModelContainer) -> Bool {
        if let entities = ModelStoreChange.entities(in: notification, container: container) {
            return !entities.isDisjoint(with: ["PendingRemoteChange", "SyncChange", "Vehicle", "FuelingRecord"])
        }
        guard let context = notification.object as? ModelContext, context.container === container else { return false }
        let invalidationKey = ModelContext.NotificationKey.invalidatedAllIdentifiers
        if let value = notification.userInfo?[invalidationKey.rawValue] ?? notification.userInfo?[invalidationKey] {
            if let all = value as? Bool {
                if all { return true }
            } else if let ids = value as? [PersistentIdentifier] {
                if !ids.isEmpty { return true }
            } else {
                return true
            }
        }
        let entities: Set<String> = ["PendingRemoteChange", "SyncChange", "Vehicle", "FuelingRecord"]
        var recognized = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            guard let value = notification.userInfo?[key.rawValue] ?? notification.userInfo?[key] else { continue }
            let ids: [PersistentIdentifier]
            if let array = value as? [PersistentIdentifier] {
                ids = array
            } else if let set = value as? Set<PersistentIdentifier> {
                ids = Array(set)
            } else {
                return true
            }
            recognized = true
            if ids.contains(where: { entities.contains($0.entityName) }) { return true }
        }
        return !recognized
    }
}
