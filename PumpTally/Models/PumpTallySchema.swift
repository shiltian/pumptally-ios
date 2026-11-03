import Foundation
import SwiftData

/// A durable save or delete that has not yet been acknowledged by CloudKit.
@Model
final class SyncChange {
    @Attribute(.unique) var key: String
    var recordName: String
    var recordTypeRaw: String
    var operationRaw: String
    var generation: String
    var createdAt: Date
    var originRaw: String?

    init(recordName: String, recordTypeRaw: String, operationRaw: String) {
        self.recordName = recordName
        self.recordTypeRaw = recordTypeRaw
        self.operationRaw = operationRaw
        self.key = "\(recordTypeRaw):\(recordName)"
        self.generation = UUID().uuidString
        self.createdAt = Date()
        self.originRaw = "local"
    }
}

/// CloudKit system fields (including the change tag) needed for conditional
/// saves after the local record has synced at least once.
@Model
final class CloudRecordMetadata {
    @Attribute(.unique) var key: String
    var systemFieldsData: Data

    init(key: String, systemFieldsData: Data) {
        self.key = key
        self.systemFieldsData = systemFieldsData
    }
}

/// A fetched CloudKit change awaiting application. This is a durable inbox for
/// modifications and deletions, including children whose owner has not arrived
/// yet, so engine state can advance without losing an uncommitted remote change.
@Model
final class PendingRemoteChange {
    @Attribute(.unique) var key: String
    var recordData: Data

    init(key: String, recordData: Data) {
        self.key = key
        self.recordData = recordData
    }
}

/// A local-only checkpoint. It is committed in the same store as the inbox.
@Model
final class SyncCheckpoint {
    @Attribute(.unique) var key: String
    var accountID: String?
    var engineState: Data?
    var bootstrapCompleted: Bool?
    var detached: Bool?
    var cloudGeneration: String?

    init(key: String) { self.key = key }
}

// Frozen historical snapshots. Do not edit their stored fields.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Vehicle.self, FuelingRecord.self]
    }

    @Model
    final class Vehicle {
        var id: UUID = UUID()
        var name: String = ""
        var make: String?
        var model: String?
        var year: Int?
        var createdAt: Date = Date()
        var unitSystemRaw: String = "imperial"

        @Relationship(deleteRule: .cascade, inverse: \FuelingRecord.vehicle)
        var fuelingRecords: [FuelingRecord]?

        var cachedTotalSpent: Double?
        var cachedTotalDistance: Double?
        var cachedTotalFuel: Double?
        var cachedAverageEfficiency: Double?
        var cachedAverageCostPerDistance: Double?
        var cachedAverageFillUpCost: Double?
        var cachedAveragePricePerFuelUnit: Double?
        var cachedBestEfficiency: Double?
        var cachedWorstEfficiency: Double?
        var cachedHighestPricePerFuelUnit: Double?
        var cachedLowestPricePerFuelUnit: Double?
        var cachedRecordCount: Int?
        var cacheLastUpdated: Date?

        init(name: String = "") {
            self.name = name
        }
    }

    @Model
    final class FuelingRecord {
        var id: UUID = UUID()
        var date: Date = Date()
        var odometer: Double = 0
        var pricePerFuelUnit: Double = 0
        var fuelAmount: Double = 0
        var totalCost: Double = 0
        var fillUpTypeRaw: String = "full"
        var notes: String?
        var createdAt: Date = Date()
        var vehicle: Vehicle

        var cachedPreviousOdometer: Double?
        var cachedDistanceDriven: Double?
        var cachedEfficiency: Double?
        var cachedCostPerDistance: Double?

        init(vehicle: Vehicle) {
            self.vehicle = vehicle
        }
    }
}

enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Vehicle.self, FuelingRecord.self]
    }

    @Model
    final class Vehicle {
        var id: UUID = UUID()
        var name: String = ""
        var make: String?
        var model: String?
        var year: Int?
        var createdAt: Date = Date()
        var modifiedAt: Date?
        var unitSystemRaw: String = "imperial"

        @Relationship(deleteRule: .cascade, inverse: \FuelingRecord.vehicle)
        var fuelingRecords: [FuelingRecord]?

        var cachedTotalSpent: Double?
        var cachedTotalDistance: Double?
        var cachedTotalFuel: Double?
        var cachedAverageEfficiency: Double?
        var cachedAverageCostPerDistance: Double?
        var cachedAverageFillUpCost: Double?
        var cachedAveragePricePerFuelUnit: Double?
        var cachedBestEfficiency: Double?
        var cachedWorstEfficiency: Double?
        var cachedHighestPricePerFuelUnit: Double?
        var cachedLowestPricePerFuelUnit: Double?
        var cachedRecordCount: Int?
        var cacheLastUpdated: Date?

        init(name: String = "") {
            self.name = name
        }
    }

    @Model
    final class FuelingRecord {
        var id: UUID = UUID()
        var date: Date = Date()
        var odometer: Double = 0
        var pricePerFuelUnit: Double = 0
        var fuelAmount: Double = 0
        var totalCost: Double = 0
        var fillUpTypeRaw: String = "full"
        var notes: String?
        var createdAt: Date = Date()
        var modifiedAt: Date?
        var vehicle: Vehicle

        var cachedPreviousOdometer: Double?
        var cachedDistanceDriven: Double?
        var cachedEfficiency: Double?
        var cachedCostPerDistance: Double?

        init(vehicle: Vehicle) {
            self.vehicle = vehicle
        }
    }
}

enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self]
    }

    @Model
    final class Vehicle {
        var id: UUID = UUID()
        var name: String = ""
        var make: String?
        var model: String?
        var year: Int?
        var createdAt: Date = Date()
        var modifiedAt: Date?
        var unitSystemRaw: String = "imperial"

        @Relationship(deleteRule: .cascade, inverse: \FuelingRecord.vehicle)
        var fuelingRecords: [FuelingRecord]?

        var cachedTotalSpent: Double?
        var cachedTotalDistance: Double?
        var cachedTotalFuel: Double?
        var cachedAverageEfficiency: Double?
        var cachedAverageCostPerDistance: Double?
        var cachedAverageFillUpCost: Double?
        var cachedAveragePricePerFuelUnit: Double?
        var cachedBestEfficiency: Double?
        var cachedWorstEfficiency: Double?
        var cachedHighestPricePerFuelUnit: Double?
        var cachedLowestPricePerFuelUnit: Double?
        var cachedRecordCount: Int?
        var cacheLastUpdated: Date?

        init(name: String = "") {
            self.name = name
        }
    }

    @Model
    final class FuelingRecord {
        var id: UUID = UUID()
        var date: Date = Date()
        var odometer: Double = 0
        var pricePerFuelUnit: Double = 0
        var fuelAmount: Double = 0
        var totalCost: Double = 0
        var fillUpTypeRaw: String = "full"
        var notes: String?
        var createdAt: Date = Date()
        var modifiedAt: Date?
        var vehicle: Vehicle

        var cachedPreviousOdometer: Double?
        var cachedDistanceDriven: Double?
        var cachedEfficiency: Double?
        var cachedCostPerDistance: Double?

        init(vehicle: Vehicle) {
            self.vehicle = vehicle
        }
    }

    @Model
    final class SyncChange {
        @Attribute(.unique) var key: String
        var recordName: String
        var recordTypeRaw: String
        var operationRaw: String
        var generation: String
        var createdAt: Date

        init(recordName: String, recordTypeRaw: String, operationRaw: String) {
            self.recordName = recordName
            self.recordTypeRaw = recordTypeRaw
            self.operationRaw = operationRaw
            self.key = "\(recordTypeRaw):\(recordName)"
            self.generation = UUID().uuidString
            self.createdAt = Date()
        }
    }

    /// CloudKit system fields (including the change tag) needed for conditional
    /// saves after the local record has synced at least once.
    @Model
    final class CloudRecordMetadata {
        @Attribute(.unique) var key: String
        var systemFieldsData: Data

        init(key: String, systemFieldsData: Data) {
            self.key = key
            self.systemFieldsData = systemFieldsData
        }
    }

    /// A fetched CloudKit change awaiting application. This is a durable inbox for
    /// modifications and deletions, including children whose owner has not arrived
    /// yet, so engine state can advance without losing an uncommitted remote change.
    @Model
    final class PendingRemoteChange {
        @Attribute(.unique) var key: String
        var recordData: Data

        init(key: String, recordData: Data) {
            self.key = key
            self.recordData = recordData
        }
    }

}

// Frozen V4 matches the independently generated 800-record store.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            Vehicle.self, FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self,
            SyncCheckpoint.self,
        ]
    }
    @Model
    final class Vehicle {
        var id: UUID = UUID()
        var name: String = ""
        var make: String?
        var model: String?
        var year: Int?
        var createdAt: Date = Date()
        var modifiedAt: Date?

        /// Unit system for this vehicle: "imperial" or "metric"
        var unitSystemRaw: String = "imperial"
        var displayUnitSystemRaw: String?

        @Relationship(deleteRule: .cascade, inverse: \FuelingRecord.vehicle)
        var fuelingRecords: [FuelingRecord]?

        // MARK: - Cached Statistics (for performance)
        // These are pre-computed and stored to avoid recalculating on every view render
        var cachedTotalSpent: Double?
        var cachedTotalDistance: Double?
        var cachedTotalFuel: Double?
        var cachedAverageEfficiency: Double?
        var cachedAverageCostPerDistance: Double?
        var cachedAverageFillUpCost: Double?
        var cachedAveragePricePerFuelUnit: Double?
        var cachedBestEfficiency: Double?
        var cachedWorstEfficiency: Double?
        var cachedHighestPricePerFuelUnit: Double?
        var cachedLowestPricePerFuelUnit: Double?
        var cachedRecordCount: Int?
        var cacheLastUpdated: Date?

        init(name: String = "") { self.name = name }
    }
    @Model
    final class FuelingRecord {
        var id: UUID = UUID()
        var date: Date = Date()
        var odometer: Double = 0
        var pricePerFuelUnit: Double = 0
        var fuelAmount: Double = 0
        var totalCost: Double = 0
        var fillUpTypeRaw: String = "full"  // Stored as String for SwiftData compatibility
        var notes: String?
        var createdAt: Date = Date()
        var modifiedAt: Date?

        var vehicle: Vehicle

        // MARK: - Cached Computed Values (for performance)
        // These are pre-computed and stored to avoid O(n²) lookups
        var cachedPreviousOdometer: Double?
        var cachedDistanceDriven: Double?
        var cachedEfficiency: Double?
        var cachedCostPerDistance: Double?

        init(vehicle: Vehicle) { self.vehicle = vehicle }
    }
    /// A durable save or delete that has not yet been acknowledged by CloudKit.
    @Model
    final class SyncChange {
        @Attribute(.unique) var key: String
        var recordName: String
        var recordTypeRaw: String
        var operationRaw: String
        var generation: String
        var createdAt: Date
        var originRaw: String?

        init(recordName: String, recordTypeRaw: String, operationRaw: String) {
            self.recordName = recordName
            self.recordTypeRaw = recordTypeRaw
            self.operationRaw = operationRaw
            self.key = "\(recordTypeRaw):\(recordName)"
            self.generation = UUID().uuidString
            self.createdAt = Date()
            self.originRaw = "local"
        }
    }

    /// CloudKit system fields (including the change tag) needed for conditional
    /// saves after the local record has synced at least once.
    @Model
    final class CloudRecordMetadata {
        @Attribute(.unique) var key: String
        var systemFieldsData: Data

        init(key: String, systemFieldsData: Data) {
            self.key = key
            self.systemFieldsData = systemFieldsData
        }
    }

    /// A fetched CloudKit change awaiting application. This is a durable inbox for
    /// modifications and deletions, including children whose owner has not arrived
    /// yet, so engine state can advance without losing an uncommitted remote change.
    @Model
    final class PendingRemoteChange {
        @Attribute(.unique) var key: String
        var recordData: Data

        init(key: String, recordData: Data) {
            self.key = key
            self.recordData = recordData
        }
    }

    /// A local-only checkpoint. It is committed in the same store as the inbox.
    @Model
    final class SyncCheckpoint {
        @Attribute(.unique) var key: String
        var accountID: String?
        var engineState: Data?
        var bootstrapCompleted: Bool?
        var detached: Bool?

        init(key: String) { self.key = key }
    }

}

// The latest schema alone references runtime classes.
enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            PumpTally.Vehicle.self, PumpTally.FuelingRecord.self, PumpTally.SyncChange.self,
            PumpTally.CloudRecordMetadata.self, PumpTally.PendingRemoteChange.self,
            PumpTally.SyncCheckpoint.self, CloudRecoveryReceipt.self,
        ]
    }
}

enum PumpTallyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
    }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )

    // V3 adds only new local persistence entities. Use an explicit custom stage
    // to preserve the existing app's policy that non-property schema changes
    // receive a reviewed migration boundary. No V2 data needs transformation.
    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self,
        willMigrate: nil,
        didMigrate: nil
    )
    static let migrateV3toV4 = MigrationStage.custom(
        fromVersion: SchemaV3.self, toVersion: SchemaV4.self,
        willMigrate: nil, didMigrate: nil
    )
    // V5 adds recovery receipts and an optional checkpoint generation. No
    // existing business values or relationships need transformation.
    static let migrateV4toV5 = MigrationStage.custom(
        fromVersion: SchemaV4.self, toVersion: SchemaV5.self, willMigrate: nil, didMigrate: nil
    )

}
