import CloudKit
import Foundation
import SwiftData

enum InitialSyncStrategy: Sendable {
    case merge
    case useCloud
    case replaceCloud
}

/// A confirmation belongs to one account and one open store. It never enables
/// sync or authorizes a later account's data to replace this device's records.
struct InitialSyncProposal: Sendable {
    let accountID: String
    let containerID: ObjectIdentifier
    let cloudRecordIDs: Set<CKRecord.ID>
    let localChanges: [String: String]
    let deletionsToReview: Int
    var cloudGeneration: String = CloudSyncControl.baselineGeneration

    var hasCloudData: Bool { !cloudRecordIDs.isEmpty }

    static func localState(in context: ModelContext) throws -> (changes: [String: String], deletionsToReview: Int) {
        let journal = try context.fetch(FetchDescriptor<SyncChange>())
        let detached = try SyncPersistenceStore.isDetached(in: context)
        return (
            generations(of: journal),
            journal.filter { SyncChangeJournal.needsDeletionReview($0, detached: detached) }.count
        )
    }

    static func localChanges(in context: ModelContext) throws -> [String: String] {
        try generations(of: context.fetch(FetchDescriptor<SyncChange>()))
    }

    private static func generations(of journal: [SyncChange]) -> [String: String] {
        journal.reduce(into: [:]) { result, change in
            result[change.key] = change.generation
        }
    }
}

enum InitialSyncError: LocalizedError {
    case unavailableAccount
    case alreadyEnabled
    case differentStore
    case localDataChanged
    case cloudDataChanged

    var errorDescription: String? {
        switch self {
        case .unavailableAccount:
            return String(localized: "Please sign in to iCloud in Settings to use this feature.")
        case .alreadyEnabled:
            return String(localized: "iCloud sync is already enabled.")
        case .differentStore:
            return String(localized: "The local store changed. Enable iCloud sync again to review your choices.")
        case .localDataChanged:
            return String(
                localized: "Local data changed while choosing a sync source. Review the latest data and try again.")
        case .cloudDataChanged:
            return String(
                localized: "iCloud data changed while choosing a sync source. Review the latest data and try again.")
        }
    }
}
