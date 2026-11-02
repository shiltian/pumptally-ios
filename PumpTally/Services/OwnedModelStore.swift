import Combine
import SwiftData

/// One sequential consumer owns write ordering across native SwiftData actors.
/// Each request gets a fresh context, including after rollback. Accepted requests
/// finish atomically; cancellation is checked before accepting another request.
@MainActor
final class OwnedModelStore: ObservableObject {
    typealias Commit = @Sendable (isolated ModelStoreActor) throws -> Void
    private typealias Operation = @Sendable () async -> Void
    private let submissions: AsyncStream<Operation>.Continuation
    private let worker: Task<Void, Never>
    let container: ModelContainer
    private let commit: Commit

    init(container: ModelContainer, commit: @escaping Commit = { try $0.modelContext.save() }) {
        self.container = container
        self.commit = commit
        let (operations, submissions) = AsyncStream<Operation>.makeStream()
        self.submissions = submissions
        worker = Task.detached(priority: .utility) {
            for await execute in operations { await execute() }
        }
    }

    deinit { submissions.finish() }

    func transaction<Result: Sendable>(
        commit override: Commit? = nil,
        _ stage: @escaping @Sendable (isolated ModelStoreActor) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let container = container
        let commit = override ?? commit
        return try await enqueue {
            let actor = await ModelStoreActor.make(container: container)
            return try await actor.transaction(commit: commit, stage)
        }
    }

    /// Shutdown drains accepted writes even when its caller was cancelled.
    func drain() async {
        do { _ = try await enqueue { () } } catch { await worker.value }
    }

    private func enqueue<Result: Sendable>(
        _ request: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { response in
            let operation: Operation = {
                do { response.resume(returning: try await request()) } catch { response.resume(throwing: error) }
            }
            switch submissions.yield(operation) {
            case .enqueued: break
            case .dropped, .terminated: response.resume(throwing: CancellationError())
            @unknown default: response.resume(throwing: CancellationError())
            }
        }
    }
}

/// Context and model access stay on SwiftData's own serial executor. Only this
/// file constructs these actors; consumers submit typed persistence commands.
@ModelActor
actor ModelStoreActor {
    static func make(container: ModelContainer) async -> ModelStoreActor {
        await Task.detached(priority: .utility) { ModelStoreActor(modelContainer: container) }.value
    }

    func transaction<Result: Sendable>(
        commit: OwnedModelStore.Commit,
        _ stage: @Sendable (isolated ModelStoreActor) throws -> Result
    ) throws -> Result {
        modelContext.autosaveEnabled = false
        do {
            let result = try stage(self)
            if modelContext.hasChanges { try commit(self) }
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
