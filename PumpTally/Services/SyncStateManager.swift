import Foundation
import CloudKit
import SwiftData
import os

/// Manages iCloud sync state and preferences using UserDefaults/AppStorage
final class SyncStateManager: ObservableObject {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "SyncState"
    )

    private let defaults: UserDefaults

    // MARK: - Published State

    @Published var iCloudSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
        }
    }

    @Published var initialSyncCompleted: Bool {
        didSet {
            defaults.set(initialSyncCompleted, forKey: Keys.initialSyncCompleted)
        }
    }

    @Published var syncStatus: SyncStatus = .idle

    // MARK: - Sync Status Enum

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case synced
        case error(String)
        case unavailable
        case reviewRequired

        var displayText: String {
            switch self {
            case .idle: return String(localized: "Not Syncing")
            case .syncing: return String(localized: "Syncing...")
            case .synced: return String(localized: "Synced")
            case .error(let msg): return String(localized: "Error: \(msg)")
            case .unavailable: return String(localized: "iCloud Unavailable")
            case .reviewRequired: return String(localized: "Sync Needs Attention")
            }
        }

        var isInProgress: Bool {
            if case .syncing = self { return true }
            return false
        }
    }

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let initialSyncCompleted = "initialSyncCompleted"
        static let serverChangeToken = "serverChangeToken"
        static let syncEngineState = "syncEngineState"
        static let syncEngineBootstrapComplete = "syncEngineBootstrapComplete"
    }

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.iCloudSyncEnabled = defaults.bool(forKey: Keys.iCloudSyncEnabled)
        self.initialSyncCompleted = defaults.bool(forKey: Keys.initialSyncCompleted)
    }

    /// Old tokens have no verifiable account/store identity. V4 performs a
    /// nondestructive reconciliation instead of importing an unsafe checkpoint.
    func retireLegacyCheckpoint() {
        for key in [Keys.serverChangeToken, Keys.syncEngineState, Keys.syncEngineBootstrapComplete] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - State Management

    /// Reset all sync state (when disabling sync)
    func resetSyncState() {
        initialSyncCompleted = false
        retireLegacyCheckpoint()
        syncStatus = .idle
    }


}

/// The durable outbox for local changes destined for the private CloudKit zone.
enum SyncChangeJournal {
    enum RecordType: String {
        case vehicle = "Vehicle"
        case fuelingRecord = "FuelingRecord"
    }

    enum Operation: String {
        case save
        case delete
    }

    static func enqueue(
        recordName: String,
        recordType: RecordType,
        operation: Operation,
        in context: ModelContext
    ) throws {
        let key = "\(recordType.rawValue):\(recordName)"
        var descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.operationRaw = operation.rawValue
            existing.originRaw = "local"
            existing.generation = UUID().uuidString
            existing.createdAt = Date()
        } else {
            context.insert(SyncChange(
                recordName: recordName,
                recordTypeRaw: recordType.rawValue,
                operationRaw: operation.rawValue
            ))
        }
    }

    static func enqueue(
        _ vehicle: Vehicle,
        operation: Operation = .save,
        in context: ModelContext
    ) throws {
        try enqueue(
            recordName: vehicle.id.uuidString,
            recordType: .vehicle,
            operation: operation,
            in: context
        )
    }

    static func enqueue(
        _ record: FuelingRecord,
        operation: Operation = .save,
        in context: ModelContext
    ) throws {
        try enqueue(
            recordName: record.id.uuidString,
            recordType: .fuelingRecord,
            operation: operation,
            in: context
        )
    }

    static func remove(key: String, generation: String, in context: ModelContext) throws {
        var descriptor = FetchDescriptor<SyncChange>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try context.fetch(descriptor).first,
              entry.generation == generation else { return }
        context.delete(entry)
    }
}
