import Foundation

/// Fetch and send outcomes have independent lifetimes. Completing one cannot
/// erase the other's failure, and empty queues cannot manufacture fetch success.
struct SyncActivity: CustomStringConvertible {
    enum Operation { case fetch, send }
    private enum Outcome {
        case idle, running, succeeded
        case failed(Error)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .running: return "running"
            case .succeeded: return "succeeded"
            case .failed: return "failed"
            }
        }
    }
    private var fetch = Outcome.idle
    private var send = Outcome.idle

    var description: String { "fetch=\(fetch.description) send=\(send.description)" }

    mutating func started(_ operation: Operation) { set(.running, for: operation) }

    mutating func finished(_ operation: Operation) {
        let outcome = operation == .fetch ? fetch : send
        if case .running = outcome { set(.succeeded, for: operation) }
    }

    mutating func failed(_ operation: Operation, error: Error) { set(.failed(error), for: operation) }

    func status(hasPendingWork: Bool, needsReview: Bool) -> SyncStateManager.SyncStatus {
        for outcome in [fetch, send] {
            if case .failed(let error) = outcome { return .error(error.localizedDescription) }
        }
        for outcome in [fetch, send] {
            if case .running = outcome { return .syncing }
        }
        if needsReview { return .reviewRequired }
        if hasPendingWork { return .syncing }
        if case .succeeded = fetch { return .synced }
        return .idle
    }

    private mutating func set(_ outcome: Outcome, for operation: Operation) {
        switch operation {
        case .fetch: fetch = outcome
        case .send: send = outcome
        }
    }
}
