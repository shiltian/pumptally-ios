import Foundation

/// Serializes explicit CloudKit mutations across suspension points.
/// CKSyncEngine owns automatic sync scheduling and retry.
///
/// CloudSyncService is main-actor isolated, but actor isolation alone does not
/// prevent async methods from interleaving at suspension points. This
/// coordinator provides an explicit, FIFO critical section across those awaits.
@MainActor
final class SyncOperationCoordinator {
    private var isLocked = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs one operation after every previously submitted operation finishes.
    func runExclusive<T>(
        _ operation: @MainActor () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            lockWaiters.append(continuation)
        }
    }

    private func release() {
        guard !lockWaiters.isEmpty else {
            isLocked = false
            return
        }

        let next = lockWaiters.removeFirst()
        next.resume()
    }
}
