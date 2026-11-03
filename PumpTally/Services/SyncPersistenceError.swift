import Foundation

enum SyncPersistenceError: LocalizedError, Equatable {
    case recoveryRequired
    case unsynchronizedChanges
    case accountChanged
    case accountDataNeedsReview

    var errorDescription: String? {
        switch self {
        case .recoveryRequired:
            return String(localized: "Sync paused because changes could not be saved. Retry when storage is available.")
        case .unsynchronizedChanges:
            return String(
                localized:
                    "This device has unsynchronized changes. Sync them before removing the local copy, or keep local data."
            )
        case .accountChanged:
            return String(
                localized: "The iCloud account changed. Enable sync again to choose how to reconcile your data.")
        case .accountDataNeedsReview:
            return String(
                localized:
                    "Changes from the previous iCloud account need review before enabling sync with another account.")
        }
    }
}
