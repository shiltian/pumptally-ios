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

// MARK: - Schema V1 (original schema, no modifiedAt)

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
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

// MARK: - Schema V2 (adds modifiedAt: Date?)
// References the top-level Vehicle and FuelingRecord classes directly so that
// SwiftData instantiates the same types the rest of the app uses at runtime.

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PumpTally.Vehicle.self, PumpTally.FuelingRecord.self]
    }
}

// MARK: - Schema V3 (adds the CloudKit journal and record metadata)

enum SchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PumpTally.Vehicle.self, PumpTally.FuelingRecord.self, SyncChange.self, CloudRecordMetadata.self, PendingRemoteChange.self]
    }
}

// MARK: - Migration Plan

enum PumpTallyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
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
}
