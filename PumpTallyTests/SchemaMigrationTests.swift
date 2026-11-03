import XCTest
import SwiftData
@testable import PumpTally

/// Tests that verify schema definitions, migration plan correctness, and data
/// integrity across all supported schema versions.
///
/// Background: A previous attempt to add a non-optional `Date` field via
/// unversioned automatic migration silently zeroed-out existing `Double` fields
/// (odometer, fuelAmount, pricePerFuelUnit, totalCost) on a subset of records.
/// That corruption was irreversible once `modelContext.save()` ran.  These tests
/// exist to prevent any similar regression.
@MainActor
final class SchemaMigrationTests: XCTestCase {

    func testIndependentV4StorePreserves800RecordsAndCheckpointThroughV5AndReopen() throws {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV4", withExtension: "store", subdirectory: "Fixtures"))
        let url = tempStoreURL()
        // Keep the isolated file until native SQLite handles are released.
        try FileManager.default.copyItem(at: fixture, to: url)
        func bits(_ values: [Double?]) -> [String] {
            values.map { $0.map { String($0.bitPattern) } ?? "nil" }
        }
        var expected: [UUID: [String]] = [:]
        var vehicleBits: [UUID: [String]] = [:]
        var journal: [String] = []
        do {
            let schema = Schema(versionedSchema: SchemaV4.self)
            let original = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(original)
            for r in try context.fetch(FetchDescriptor<SchemaV4.FuelingRecord>()) {
                expected[r.id] =
                    bits([
                        r.odometer, r.pricePerFuelUnit, r.fuelAmount, r.totalCost,
                        r.cachedPreviousOdometer, r.cachedDistanceDriven, r.cachedEfficiency, r.cachedCostPerDistance,
                        r.date.timeIntervalSinceReferenceDate, r.createdAt.timeIntervalSinceReferenceDate,
                        r.modifiedAt?.timeIntervalSinceReferenceDate,
                    ]) + [r.vehicle.id.uuidString, r.fillUpTypeRaw, r.notes ?? "nil"]
            }
            for v in try context.fetch(FetchDescriptor<SchemaV4.Vehicle>()) {
                vehicleBits[v.id] =
                    bits([
                        v.cachedTotalSpent, v.cachedTotalDistance, v.cachedTotalFuel,
                        v.cachedAverageEfficiency, v.cachedAverageCostPerDistance, v.cachedAverageFillUpCost,
                        v.cachedAveragePricePerFuelUnit, v.cachedBestEfficiency, v.cachedWorstEfficiency,
                        v.cachedHighestPricePerFuelUnit, v.cachedLowestPricePerFuelUnit,
                        v.cacheLastUpdated?.timeIntervalSinceReferenceDate, v.createdAt.timeIntervalSinceReferenceDate,
                        v.modifiedAt?.timeIntervalSinceReferenceDate,
                    ]) + [
                        v.name, v.make ?? "nil", v.model ?? "nil",
                        String(describing: v.year), v.unitSystemRaw, v.displayUnitSystemRaw ?? "nil",
                        String(describing: v.cachedRecordCount),
                    ]
            }
            let entry = try XCTUnwrap(context.fetch(FetchDescriptor<SchemaV4.SyncChange>()).first)
            journal = [entry.key, entry.recordName, entry.operationRaw, entry.generation, entry.originRaw ?? "nil"]
        }
        XCTAssertEqual(expected.count, 800)
        XCTAssertEqual(vehicleBits.count, 2)
        for _ in 0..<2 {
            let schema = Schema(versionedSchema: SchemaV5.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            let records = try context.fetch(FetchDescriptor<FuelingRecord>())
            XCTAssertEqual(records.count, expected.count)
            for r in records {
                XCTAssertEqual(
                    bits([
                        r.odometer, r.pricePerFuelUnit, r.fuelAmount, r.totalCost,
                        r.cachedPreviousOdometer, r.cachedDistanceDriven, r.cachedEfficiency, r.cachedCostPerDistance,
                        r.date.timeIntervalSinceReferenceDate, r.createdAt.timeIntervalSinceReferenceDate,
                        r.modifiedAt?.timeIntervalSinceReferenceDate,
                    ]) + [r.vehicle.id.uuidString, r.fillUpTypeRaw, r.notes ?? "nil"], expected[r.id])
            }
            for v in try context.fetch(FetchDescriptor<Vehicle>()) {
                XCTAssertEqual(
                    bits([
                        v.cachedTotalSpent, v.cachedTotalDistance, v.cachedTotalFuel,
                        v.cachedAverageEfficiency, v.cachedAverageCostPerDistance, v.cachedAverageFillUpCost,
                        v.cachedAveragePricePerFuelUnit, v.cachedBestEfficiency, v.cachedWorstEfficiency,
                        v.cachedHighestPricePerFuelUnit, v.cachedLowestPricePerFuelUnit,
                        v.cacheLastUpdated?.timeIntervalSinceReferenceDate, v.createdAt.timeIntervalSinceReferenceDate,
                        v.modifiedAt?.timeIntervalSinceReferenceDate,
                    ]) + [
                        v.name, v.make ?? "nil", v.model ?? "nil",
                        String(describing: v.year), v.unitSystemRaw, v.displayUnitSystemRaw ?? "nil",
                        String(describing: v.cachedRecordCount),
                    ], vehicleBits[v.id])
            }
            let entry = try XCTUnwrap(context.fetch(FetchDescriptor<SyncChange>()).first)
            XCTAssertEqual(
                [entry.key, entry.recordName, entry.operationRaw, entry.generation, entry.originRaw ?? "nil"], journal)
            let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<SyncCheckpoint>()).first)
            XCTAssertEqual(checkpoint.accountID, "v4-fixture-account")
            XCTAssertEqual(checkpoint.bootstrapCompleted, true)
            XCTAssertEqual(checkpoint.detached, false)
            XCTAssertNil(checkpoint.cloudGeneration)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CloudRecoveryReceipt>()), 0)
            try context.save()
        }
    }

    func testOriginalV3FixturePreserves800RecordsAcrossMigrationAndReopen() throws {
        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        try FileManager.default.copyItem(at: fixture, to: url)
        var expected: [UUID: [UInt64]] = [:]
        var vehicleIDs = Set<UUID>()
        do {
            let schema = Schema(versionedSchema: SchemaV3.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let original = try ModelContainer(for: schema, configurations: [configuration])
            let context = original.mainContext
            for vehicle in try context.fetch(FetchDescriptor<SchemaV3.Vehicle>()) { vehicleIDs.insert(vehicle.id) }
            for record in try context.fetch(FetchDescriptor<SchemaV3.FuelingRecord>()) {
                expected[record.id] = [
                    record.odometer.bitPattern, record.pricePerFuelUnit.bitPattern,
                    record.fuelAmount.bitPattern, record.totalCost.bitPattern, record.cachedEfficiency!.bitPattern,
                ]
            }
        }
        XCTAssertEqual(expected.count, 800)
        for _ in 0..<2 {
            let schema = Schema(versionedSchema: SchemaV5.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let migrated = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
            let context = migrated.mainContext
            let records = try context.fetch(FetchDescriptor<FuelingRecord>())
            XCTAssertEqual(records.count, 800)
            XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Vehicle>()).map(\.id)), vehicleIDs)
            for record in records {
                XCTAssertEqual(
                    [
                        record.odometer.bitPattern, record.pricePerFuelUnit.bitPattern,
                        record.fuelAmount.bitPattern, record.totalCost.bitPattern, record.cachedEfficiency!.bitPattern,
                    ], expected[record.id])
                XCTAssertTrue(vehicleIDs.contains(record.vehicle.id))
                XCTAssertNotNil(record.notes)
                XCTAssertNil(record.vehicle.displayUnitSystemRaw)
            }
            let legacyDeletion = try XCTUnwrap(context.fetch(FetchDescriptor<SyncChange>()).first)
            XCTAssertEqual(legacyDeletion.operationRaw, "delete")
            XCTAssertNil(legacyDeletion.originRaw, "Migration must not manufacture deletion authorization")
            try context.save()
        }
    }

    // MARK: - Helpers

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Create a V1 store at `url`, populate it with known data, and close it.
    /// Returns the exact values inserted so callers can assert against them.
    @discardableResult
    private func populateV1Store(
        at url: URL,
        vehicleCount: Int = 1,
        recordsPerVehicle: Int = 3
    ) throws -> [TestRecord] {
        let v1Schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v1Schema, configurations: [config])
        let context = container.mainContext

        var expected: [TestRecord] = []

        for vi in 0..<vehicleCount {
            let vehicle = SchemaV1.Vehicle(name: "Car \(vi)")
            vehicle.make = "Make\(vi)"
            vehicle.model = "Model\(vi)"
            vehicle.year = 2020 + vi
            vehicle.unitSystemRaw = vi % 2 == 0 ? "imperial" : "metric"
            context.insert(vehicle)

            for ri in 0..<recordsPerVehicle {
                let record = SchemaV1.FuelingRecord(vehicle: vehicle)
                let odometer   = 10000.0 + Double(vi * 1000 + ri * 300) + 0.7
                let price      = 3.0 + Double(ri) * 0.123
                let fuel       = 8.0 + Double(ri) * 1.5
                let cost       = price * fuel

                record.odometer          = odometer
                record.pricePerFuelUnit  = price
                record.fuelAmount        = fuel
                record.totalCost         = cost
                record.fillUpTypeRaw     = ri == 1 ? "partial" : "full"
                record.notes             = ri == 0 ? "Note \(vi)-\(ri)" : nil
                context.insert(record)

                expected.append(TestRecord(
                    vehicleName: "Car \(vi)",
                    odometer: odometer,
                    pricePerFuelUnit: price,
                    fuelAmount: fuel,
                    totalCost: cost,
                    fillUpTypeRaw: ri == 1 ? "partial" : "full",
                    notes: ri == 0 ? "Note \(vi)-\(ri)" : nil
                ))
            }
        }

        try context.save()
        return expected
    }

    private struct TestRecord {
        let vehicleName: String
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpTypeRaw: String
        let notes: String?
    }

    // MARK: - Schema Version Identifier Tests

    func testSchemaV1VersionIdentifier() {
        XCTAssertEqual(SchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func testSchemaV2VersionIdentifier() {
        XCTAssertEqual(SchemaV2.versionIdentifier, Schema.Version(2, 0, 0))
    }

    // MARK: - Schema Model Registration Tests

    func testSchemaV1RegistersTwoModels() {
        XCTAssertEqual(SchemaV1.models.count, 2)
    }

    func testSchemaV2RegistersTwoModels() {
        XCTAssertEqual(SchemaV2.models.count, 2)
    }

    /// The latest schema version MUST reference the top-level runtime classes so
    /// SwiftData instantiates the types the rest of the app expects.  Using nested
    /// `@Model` copies here causes a fatal cast error at runtime.
    func testCurrentSchemaReferencesTopLevelRuntimeTypes() throws {
        let models = SchemaV5.models
        XCTAssertTrue(
            models.contains(where: { $0 == PumpTally.Vehicle.self }),
            "Current schema must reference PumpTally.Vehicle, not a nested copy"
        )
        XCTAssertTrue(
            models.contains(where: { $0 == PumpTally.FuelingRecord.self }),
            "Current schema must reference PumpTally.FuelingRecord, not a nested copy"
        )
    }

    /// Older schema versions must use their own nested types (historical snapshots)
    /// so the migration plan can diff between versions.
    func testSchemaV1ReferencesNestedTypes() {
        let models = SchemaV1.models
        XCTAssertTrue(models.contains(where: { $0 == SchemaV1.Vehicle.self }))
        XCTAssertTrue(models.contains(where: { $0 == SchemaV1.FuelingRecord.self }))
    }

    /// V1 nested types must be different from the top-level runtime types.
    func testV1NestedTypesAreDistinctFromTopLevelTypes() {
        XCTAssertFalse(
            SchemaV1.Vehicle.self == PumpTally.Vehicle.self as any PersistentModel.Type,
            "SchemaV1.Vehicle should be a distinct type from PumpTally.Vehicle"
        )
        XCTAssertFalse(
            SchemaV1.FuelingRecord.self == PumpTally.FuelingRecord.self as any PersistentModel.Type,
            "SchemaV1.FuelingRecord should be a distinct type from PumpTally.FuelingRecord"
        )
    }

    // MARK: - Migration Plan Structure Tests

    func testMigrationPlanContainsAllSchemaVersions() {
        let schemas = PumpTallyMigrationPlan.schemas
        XCTAssertEqual(schemas.count, 5, "Migration plan should list V1 through V5")
    }

    func testMigrationPlanSchemasAreOrdered() {
        let schemas = PumpTallyMigrationPlan.schemas
        XCTAssertTrue(
            schemas[0] == SchemaV1.self,
            "First schema should be V1"
        )
        XCTAssertTrue(
            schemas[1] == SchemaV2.self,
            "Second schema should be V2"
        )
        XCTAssertTrue(schemas[2] == SchemaV3.self, "Third schema should be V3")
    }

    func testMigrationPlanHasFourStages() throws {
        XCTAssertEqual(PumpTallyMigrationPlan.stages.count, 4)
    }

    // MARK: - V1 Store Tests

    func testV1StoreCanBeCreatedAndReadBack() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let v1Schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: v1Schema, configurations: [config])
        let context = container.mainContext

        let vehicle = SchemaV1.Vehicle(name: "Test Car")
        vehicle.make = "Honda"
        vehicle.year = 2023
        context.insert(vehicle)

        let record = SchemaV1.FuelingRecord(vehicle: vehicle)
        record.odometer = 45678.9
        record.pricePerFuelUnit = 3.899
        record.fuelAmount = 12.345
        record.totalCost = 48.13
        context.insert(record)

        try context.save()

        let vehicles = try context.fetch(FetchDescriptor<SchemaV1.Vehicle>())
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles[0].name, "Test Car")
        XCTAssertEqual(vehicles[0].make, "Honda")
        XCTAssertEqual(vehicles[0].year, 2023)

        let records = try context.fetch(FetchDescriptor<SchemaV1.FuelingRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].odometer, 45678.9)
        XCTAssertEqual(records[0].pricePerFuelUnit, 3.899)
        XCTAssertEqual(records[0].fuelAmount, 12.345)
        XCTAssertEqual(records[0].totalCost, 48.13)
    }

    // MARK: - V1 → V3 Migration Integrity Tests

    /// Core migration test: open a V1 store with V3 schema + migration plan and
    /// verify every Double field is EXACTLY preserved across both stages.
    func testV1ToCurrentMigrationPreservesAllDoubleFields() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        // Known values chosen to expose floating-point issues
        let knownOdometer: Double          = 87654.321
        let knownPricePerFuelUnit: Double  = 3.459
        let knownFuelAmount: Double        = 10.573
        let knownTotalCost: Double         = 36.57

        // --- V1: create and populate ---
        do {
            let v1Schema = Schema(versionedSchema: SchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV1.Vehicle(name: "Daily Driver")
            vehicle.make = "Toyota"
            vehicle.model = "Camry"
            vehicle.year = 2022
            context.insert(vehicle)

            let record = SchemaV1.FuelingRecord(vehicle: vehicle)
            record.odometer         = knownOdometer
            record.pricePerFuelUnit = knownPricePerFuelUnit
            record.fuelAmount       = knownFuelAmount
            record.totalCost        = knownTotalCost
            record.fillUpTypeRaw    = "full"
            record.notes            = "Premium gas"
            context.insert(record)

            try context.save()
        }
        // V1 container deallocated

        // --- V3: reopen with migration plan ---
        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        // Verify Vehicle
        let vehicles = try v2Context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.count, 1)
        let vehicle = vehicles[0]
        XCTAssertEqual(vehicle.name, "Daily Driver")
        XCTAssertEqual(vehicle.make, "Toyota")
        XCTAssertEqual(vehicle.model, "Camry")
        XCTAssertEqual(vehicle.year, 2022)

        // Verify FuelingRecord -- every Double MUST match exactly
        let records = try v2Context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(records.count, 1)
        let record = records[0]

        XCTAssertEqual(record.odometer, knownOdometer,
                       "Odometer must survive migration unchanged")
        XCTAssertEqual(record.pricePerFuelUnit, knownPricePerFuelUnit,
                       "Price per fuel unit must survive migration unchanged")
        XCTAssertEqual(record.fuelAmount, knownFuelAmount,
                       "Fuel amount must survive migration unchanged")
        XCTAssertEqual(record.totalCost, knownTotalCost,
                       "Total cost must survive migration unchanged")

        XCTAssertEqual(record.fillUpTypeRaw, "full")
        XCTAssertEqual(record.notes, "Premium gas")
    }

    /// The V2 schema adds `modifiedAt: Date?`.  After migrating a V1 store the
    /// new column must be nil -- never a fabricated default.
    func testV1ToCurrentMigrationSetsModifiedAtToNil() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        do {
            let v1Schema = Schema(versionedSchema: SchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV1.Vehicle(name: "Test")
            context.insert(vehicle)

            let record = SchemaV1.FuelingRecord(vehicle: vehicle)
            record.odometer = 1000
            context.insert(record)

            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let vehicles = try v2Context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertNil(vehicles.first?.modifiedAt,
                     "Vehicle.modifiedAt must be nil after V1→V3 migration")

        let records = try v2Context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertNil(records.first?.modifiedAt,
                     "FuelingRecord.modifiedAt must be nil after V1→V3 migration")
    }

    /// Verify that String, Int?, and Date fields also survive migration.
    func testV1ToCurrentMigrationPreservesNonDoubleFields() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedCreatedAt = Date(timeIntervalSince1970: 1_690_000_000)

        do {
            let v1Schema = Schema(versionedSchema: SchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV1.Vehicle(name: "Metric Car")
            vehicle.unitSystemRaw = "metric"
            vehicle.year = 2019
            vehicle.createdAt = fixedCreatedAt
            context.insert(vehicle)

            let record = SchemaV1.FuelingRecord(vehicle: vehicle)
            record.odometer = 5000
            record.date = fixedDate
            record.createdAt = fixedCreatedAt
            record.fillUpTypeRaw = "partial"
            record.notes = "Snowy day, premium only"
            context.insert(record)

            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let vehicle = try v2Context.fetch(FetchDescriptor<Vehicle>()).first!
        XCTAssertEqual(vehicle.name, "Metric Car")
        XCTAssertEqual(vehicle.unitSystemRaw, "metric")
        XCTAssertEqual(vehicle.year, 2019)
        XCTAssertEqual(vehicle.createdAt, fixedCreatedAt)

        let record = try v2Context.fetch(FetchDescriptor<FuelingRecord>()).first!
        XCTAssertEqual(record.date, fixedDate)
        XCTAssertEqual(record.createdAt, fixedCreatedAt)
        XCTAssertEqual(record.fillUpTypeRaw, "partial")
        XCTAssertEqual(record.notes, "Snowy day, premium only")
    }

    // MARK: - Corruption Regression Tests

    /// Regression: A previous migration silently zeroed-out Double fields on
    /// some records while leaving others intact.  This test populates a V1 store
    /// with multiple vehicles and records (diverse nonzero Doubles) then verifies
    /// that NONE of them became zero after migration.
    func testMigrationNeverZerosOutNonZeroDoubleFields() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let expected = try populateV1Store(at: url, vehicleCount: 3, recordsPerVehicle: 5)

        // Reopen with V3
        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let migratedRecords = try v2Context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(migratedRecords.count, expected.count,
                       "Record count must match after migration")

        for record in migratedRecords {
            XCTAssertNotEqual(record.odometer, 0,
                              "Odometer was nonzero in V1 — must not be zeroed by migration")
            XCTAssertNotEqual(record.fuelAmount, 0,
                              "Fuel amount was nonzero in V1 — must not be zeroed by migration")
            XCTAssertNotEqual(record.pricePerFuelUnit, 0,
                              "Price was nonzero in V1 — must not be zeroed by migration")
            XCTAssertNotEqual(record.totalCost, 0,
                              "Total cost was nonzero in V1 — must not be zeroed by migration")
        }
    }

    /// Verify exact value fidelity for every record across migration.
    func testMigrationPreservesExactDoubleValuesForAllRecords() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let expected = try populateV1Store(at: url, vehicleCount: 2, recordsPerVehicle: 4)

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let migratedRecords = try v2Context.fetch(FetchDescriptor<FuelingRecord>())

        // Build a lookup by odometer (unique per TestRecord in our helper)
        let migratedByOdometer = Dictionary(
            uniqueKeysWithValues: migratedRecords.map { ($0.odometer, $0) }
        )

        for exp in expected {
            guard let actual = migratedByOdometer[exp.odometer] else {
                XCTFail("Missing record with odometer \(exp.odometer) after migration")
                continue
            }
            XCTAssertEqual(actual.pricePerFuelUnit, exp.pricePerFuelUnit, accuracy: 1e-10,
                           "pricePerFuelUnit mismatch for odometer \(exp.odometer)")
            XCTAssertEqual(actual.fuelAmount, exp.fuelAmount, accuracy: 1e-10,
                           "fuelAmount mismatch for odometer \(exp.odometer)")
            XCTAssertEqual(actual.totalCost, exp.totalCost, accuracy: 1e-10,
                           "totalCost mismatch for odometer \(exp.odometer)")
            XCTAssertEqual(actual.fillUpTypeRaw, exp.fillUpTypeRaw)
            XCTAssertEqual(actual.notes, exp.notes)
        }
    }

    /// The V2-added optional fields on Vehicle (cache fields etc.) must survive
    /// round-trip without disturbing existing data.
    func testMigrationPreservesVehicleCacheFields() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        do {
            let v1Schema = Schema(versionedSchema: SchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV1.Vehicle(name: "Cached")
            vehicle.cachedTotalSpent = 1234.56
            vehicle.cachedTotalDistance = 9876.5
            vehicle.cachedTotalFuel = 321.0
            vehicle.cachedRecordCount = 42
            context.insert(vehicle)

            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let vehicle = try v2Context.fetch(FetchDescriptor<Vehicle>()).first!
        XCTAssertEqual(vehicle.cachedTotalSpent, 1234.56)
        XCTAssertEqual(vehicle.cachedTotalDistance, 9876.5)
        XCTAssertEqual(vehicle.cachedTotalFuel, 321.0)
        XCTAssertEqual(vehicle.cachedRecordCount, 42)
    }

    // MARK: - V2 → V3 Migration Tests

    /// Existing production users can have a V2 store. Verify the schema bump
    /// adds the sync journal without rewriting any stored fueling values.
    func testV2ToCurrentMigrationPreservesExistingDataAndStartsWithEmptyJournal() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let vehicleID = UUID()
        let recordID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let expectedValues = (odometer: 87_654.321, price: 3.459, fuel: 10.573, cost: 36.57)

        do {
            let currentSchema = Schema(versionedSchema: SchemaV2.self)
            let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: currentSchema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV2.Vehicle(name: "V2 Vehicle")
            vehicle.id = vehicleID
            vehicle.createdAt = modifiedAt
            vehicle.modifiedAt = modifiedAt
            context.insert(vehicle)

            let record = SchemaV2.FuelingRecord(vehicle: vehicle)
            record.id = recordID
            record.date = modifiedAt
            record.odometer = expectedValues.odometer
            record.pricePerFuelUnit = expectedValues.price
            record.fuelAmount = expectedValues.fuel
            record.totalCost = expectedValues.cost
            record.createdAt = modifiedAt
            record.modifiedAt = modifiedAt
            context.insert(record)
            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let v3Config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v3Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [v3Config]
        )
        let context = v3Container.mainContext

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.map(\.id), [vehicleID])
        XCTAssertEqual(vehicles.first?.name, "V2 Vehicle")
        XCTAssertEqual(vehicles.first?.modifiedAt, modifiedAt)

        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(records.map(\.id), [recordID])
        XCTAssertEqual(records.first?.odometer, expectedValues.odometer)
        XCTAssertEqual(records.first?.pricePerFuelUnit, expectedValues.price)
        XCTAssertEqual(records.first?.fuelAmount, expectedValues.fuel)
        XCTAssertEqual(records.first?.totalCost, expectedValues.cost)
        XCTAssertEqual(records.first?.modifiedAt, modifiedAt)
        XCTAssertEqual(records.first?.vehicle.id, vehicleID)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncChange>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CloudRecordMetadata>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingRemoteChange>()).isEmpty)
    }

    // MARK: - V3 Fresh Store Tests

    /// Ensure the current production ModelContainer configuration works for a
    /// fresh install (no pre-existing store).
    func testCurrentFreshStoreWorksWithMigrationPlan() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext

        let vehicle = Vehicle(name: "Brand New")
        vehicle.modifiedAt = Date()
        context.insert(vehicle)

        let record = FuelingRecord(
            odometer: 100,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10,
            totalCost: 35,
            vehicle: vehicle
        )
        record.modifiedAt = Date()
        context.insert(record)

        try context.save()

        let fetched = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNotNil(fetched[0].modifiedAt)
        XCTAssertEqual(fetched[0].odometer, 100)
    }

    /// Relationship integrity: after migration, records are still linked to their
    /// vehicle and cascade delete still works conceptually (we just verify the
    /// relationship navigation).
    func testV1ToCurrentMigrationPreservesRelationships() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        do {
            let v1Schema = Schema(versionedSchema: SchemaV1.self)
            let config = ModelConfiguration(schema: v1Schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: v1Schema, configurations: [config])
            let context = container.mainContext

            let vehicle = SchemaV1.Vehicle(name: "Linked")
            context.insert(vehicle)

            for i in 0..<3 {
                let record = SchemaV1.FuelingRecord(vehicle: vehicle)
                record.odometer = Double(1000 * (i + 1))
                context.insert(record)
            }

            try context.save()
        }

        let currentSchema = Schema(versionedSchema: SchemaV5.self)
        let config = ModelConfiguration(schema: currentSchema, url: url, cloudKitDatabase: .none)
        let v2Container = try ModelContainer(
            for: currentSchema,
            migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [config]
        )
        let v2Context = v2Container.mainContext

        let vehicles = try v2Context.fetch(FetchDescriptor<Vehicle>())
        XCTAssertEqual(vehicles.count, 1)
        let vehicle = vehicles[0]

        XCTAssertEqual(vehicle.fuelingRecords?.count, 3,
                       "Vehicle → FuelingRecord relationship must survive migration")

        let records = try v2Context.fetch(FetchDescriptor<FuelingRecord>())
        for record in records {
            XCTAssertEqual(record.vehicle.id, vehicle.id,
                           "FuelingRecord → Vehicle back-reference must survive migration")
        }
    }
}
