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

    // MARK: - Published State

    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
        }
    }

    @Published var initialSyncCompleted: Bool {
        didSet {
            UserDefaults.standard.set(initialSyncCompleted, forKey: Keys.initialSyncCompleted)
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

        var displayText: String {
            switch self {
            case .idle: return String(localized: "Not Syncing")
            case .syncing: return String(localized: "Syncing...")
            case .synced: return String(localized: "Synced")
            case .error(let msg): return String(localized: "Error: \(msg)")
            case .unavailable: return String(localized: "iCloud Unavailable")
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

    init() {
        self.iCloudSyncEnabled = UserDefaults.standard.bool(forKey: Keys.iCloudSyncEnabled)
        self.initialSyncCompleted = UserDefaults.standard.bool(forKey: Keys.initialSyncCompleted)
    }

    // MARK: - Server Change Token

    /// The last known server change token for incremental sync
    var serverChangeToken: CKServerChangeToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.serverChangeToken) else {
                return nil
            }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
            } catch {
                Self.logger.error("Failed to decode server change token: \(error)")
                return nil
            }
        }
        set {
            if let token = newValue {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
                    UserDefaults.standard.set(data, forKey: Keys.serverChangeToken)
                } catch {
                    Self.logger.error("Failed to encode server change token: \(error)")
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.serverChangeToken)
            }
        }
    }

    /// CKSyncEngine's opaque Codable state must survive process termination.
    var syncEngineState: CKSyncEngine.State.Serialization? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.syncEngineState) else {
                return nil
            }
            do {
                return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            } catch {
                Self.logger.error("Failed to decode CloudKit sync engine state: \(error)")
                return nil
            }
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.syncEngineState)
                return
            }
            do {
                let data = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(data, forKey: Keys.syncEngineState)
            } catch {
                Self.logger.error("Failed to encode CloudKit sync engine state: \(error)")
            }
        }
    }

    var syncEngineBootstrapComplete: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.syncEngineBootstrapComplete) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.syncEngineBootstrapComplete) }
    }

    // MARK: - State Management

    /// Reset all sync state (when disabling sync)
    func resetSyncState() {
        initialSyncCompleted = false
        serverChangeToken = nil
        syncEngineState = nil
        syncEngineBootstrapComplete = false
        syncStatus = .idle
    }

    /// Mark sync as enabled and initial sync complete
    func markInitialSyncComplete() {
        initialSyncCompleted = true
        syncStatus = .synced
    }
}

/// The durable outbox for local changes destined for the private CloudKit zone.
@MainActor
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
        try context.save()
    }
}
