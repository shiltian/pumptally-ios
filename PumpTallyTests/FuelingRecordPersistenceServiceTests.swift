import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
private final class PersistenceFixture {
    let container: ModelContainer
    let url: URL
    let vehicleID: UUID
    let otherVehicleID: UUID
    let recordIDs: [UUID]

    init(recordCount: Int = 2) throws {
        // SwiftData can retain SQLite handles past XCTest teardown. These
        // isolated stores stay in the test application's temporary directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("store")
        let schema = Schema(versionedSchema: SchemaV6.self)
        container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        let vehicle = Vehicle(name: "Original", make: "Make", model: "Model", year: 2020)
        let other = Vehicle(name: "Unrelated", unitSystem: .metric)
        context.insert(vehicle)
        context.insert(other)
        var ids: [UUID] = []
        for index in 0..<recordCount {
            let record = FuelingRecord(
                date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                odometer: 1000.123456789 + Double(index) * 300, pricePerFuelUnit: 3.459876543,
                fuelAmount: 10.123456789, totalCost: 35.123456789, notes: "Original \(index)", vehicle: vehicle)
            context.insert(record)
            ids.append(record.id)
        }
        context.insert(
            FuelingRecord(odometer: 500, pricePerFuelUnit: 1.5, fuelAmount: 20, totalCost: 30, vehicle: other))
        context.processPendingChanges()
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        StatisticsCacheService.recalculateAllStatistics(for: other)
        try context.save()
        vehicleID = vehicle.id
        otherVehicleID = other.id
        recordIDs = ids
    }

    var context: ModelContext { ModelContext(container) }

    nonisolated func vehicle(_ context: ModelContext) throws -> Vehicle {
        let id = vehicleID
        return try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })).first)
    }

    nonisolated func record(_ context: ModelContext) throws -> FuelingRecord {
        let id = try XCTUnwrap(recordIDs.last)
        return try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    var values: FuelingRecordValues {
        FuelingRecordValues(
            date: Date(timeIntervalSince1970: 3_000_000), odometer: 1700.123456789,
            pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789, totalCost: 35.123456789, fillUpType: .full,
            notes: "New")
    }

    func update() throws -> FuelingRecordUpdate {
        let context = context
        let original = try FuelingRecordValues(record: record(context))
        var proposed = original
        proposed.odometer += 100
        proposed.totalCost = 45
        return FuelingRecordUpdate(original: original, proposed: proposed, storageUnit: .imperial)
    }

    func importRows() throws -> [CSVImportRecordSnapshot] {
        try CSVImportService.parse(
            "date,odometer,price,fuel,cost,fillUpType,notes\n2024-01-15,2000,3,10,30,full,First\n2024-02-15,2300,3,10,30,full,Second"
        )
    }

    func fingerprint() throws -> [String: [String: String]] { try persistenceFingerprint(container) }
}

/// Independent, bit-exact assertions for saved business values and caches.
@MainActor
private func persistenceFingerprint(_ container: ModelContainer) throws -> [String: [String: String]] {
    let context = ModelContext(container)
    func bits(_ fields: [(String, Double?)]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.map { String($0.bitPattern) } ?? "nil") })
    }
    var result: [String: [String: String]] = [:]
    for v in try context.fetch(FetchDescriptor<Vehicle>()) {
        result["Vehicle:\(v.id)"] = [
            "name": v.name, "make": v.make ?? "nil", "model": v.model ?? "nil", "year": String(describing: v.year),
            "storageUnit": v.unitSystemRaw, "displayUnit": v.displayUnitSystemRaw ?? "nil",
            "count": String(describing: v.cachedRecordCount),
        ].merging(
            bits([
                ("createdAt", v.createdAt.timeIntervalSince1970), ("modifiedAt", v.modifiedAt?.timeIntervalSince1970),
                ("cacheDate", v.cacheLastUpdated?.timeIntervalSince1970),
                ("spent", v.cachedTotalSpent), ("distance", v.cachedTotalDistance), ("fuel", v.cachedTotalFuel),
                ("efficiency", v.cachedAverageEfficiency),
                ("costPerDistance", v.cachedAverageCostPerDistance), ("fillCost", v.cachedAverageFillUpCost),
                ("price", v.cachedAveragePricePerFuelUnit),
                ("best", v.cachedBestEfficiency), ("worst", v.cachedWorstEfficiency),
                ("highestPrice", v.cachedHighestPricePerFuelUnit), ("lowestPrice", v.cachedLowestPricePerFuelUnit),
            ]), uniquingKeysWith: { _, rhs in rhs })
    }
    for r in try context.fetch(FetchDescriptor<FuelingRecord>()) {
        result["Record:\(r.id)"] = [
            "owner": r.vehicle.id.uuidString, "notes": r.notes ?? "nil", "fillType": r.fillUpTypeRaw,
        ].merging(
            bits([
                ("date", r.date.timeIntervalSince1970), ("createdAt", r.createdAt.timeIntervalSince1970),
                ("modifiedAt", r.modifiedAt?.timeIntervalSince1970),
                ("odometer", r.odometer), ("price", r.pricePerFuelUnit), ("fuel", r.fuelAmount), ("cost", r.totalCost),
                ("previousOdometer", r.cachedPreviousOdometer), ("distance", r.cachedDistanceDriven),
                ("efficiency", r.cachedEfficiency), ("costPerDistance", r.cachedCostPerDistance),
            ]), uniquingKeysWith: { _, rhs in rhs })
    }
    for entry in try context.fetch(FetchDescriptor<SyncChange>()) {
        result["Journal:\(entry.key)"] = [
            "generation": entry.generation, "operation": entry.operationRaw, "origin": entry.originRaw ?? "nil",
            "createdAt": String(entry.createdAt.timeIntervalSince1970.bitPattern),
        ]
    }
    return result
}

@MainActor
final class FuelingRecordPersistenceServiceTests: XCTestCase {
    func testNumericEditAndDeletionDirtyOnlyTheirDependentIntervals() async throws {
        let fixture = try PersistenceFixture(recordCount: 800)
        let changes = OSAllocatedUnfairLock(initialState: Set<UUID>())
        let service = FuelingRecordPersistenceService(
            container: fixture.container,
            commit: { actor in
                let context = actor.modelContext
                context.processPendingChanges()
                let changedIDs = Set(context.changedModelsArray.compactMap { ($0 as? FuelingRecord)?.id })
                changes.withLock { $0 = changedIDs }
                try context.save()
            })
        let targetID = fixture.recordIDs[400]
        var reader = fixture.context
        var record = try XCTUnwrap(reader.fetch(FetchDescriptor<FuelingRecord>()).first { $0.id == targetID })
        var original = FuelingRecordValues(record: record)
        var changed = original
        changed.pricePerFuelUnit += 1
        _ = try await service.update(
            recordID: targetID, update: FuelingRecordUpdate(original: original, proposed: changed))
        XCTAssertEqual(changes.withLock { $0 }, [targetID])
        reader = fixture.context
        record = try XCTUnwrap(reader.fetch(FetchDescriptor<FuelingRecord>()).first { $0.id == targetID })
        original = FuelingRecordValues(record: record)
        changed = original
        changed.odometer += 10
        _ = try await service.update(
            recordID: targetID, update: FuelingRecordUpdate(original: original, proposed: changed))
        XCTAssertEqual(changes.withLock { $0 }, [targetID, fixture.recordIDs[401]])
        try await service.delete(recordID: targetID)
        XCTAssertTrue(changes.withLock { $0 }.isSubset(of: [targetID, fixture.recordIDs[401]]))
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FuelingRecord>()), 800)
    }

    func testCopiedHistoryBusinessValuesSurviveNumericCacheRefreshAndReopen() async throws {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("statistics-copy.store")
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var expected: [String: [String: String]] = [:]
        func business(_ fingerprint: [String: [String: String]]) -> [String: [String: String]] {
            let fields: Set<String> = [
                "owner", "notes", "fillType", "date", "createdAt", "modifiedAt", "odometer", "price", "fuel", "cost",
            ]
            return fingerprint.filter { $0.key.hasPrefix("Record:") }.mapValues {
                $0.filter { fields.contains($0.key) }
            }
        }
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [config])
            expected = business(try persistenceFingerprint(container))
            let context = ModelContext(container)
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>()).first)
            let before = FuelingRecordValues(record: row)
            var after = before
            after.fuelAmount += 0.123456789
            let id = row.id
            _ = try await FuelingRecordPersistenceService(container: container).update(
                recordID: id,
                update: FuelingRecordUpdate(original: before, proposed: after))
            let actual = business(try persistenceFingerprint(container))
            let key = "Record:\(id)"
            expected[key]?["fuel"] = String(after.fuelAmount.bitPattern)
            expected[key]?["modifiedAt"] = actual[key]?["modifiedAt"]
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.count, 800)
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [config])
        XCTAssertEqual(business(try persistenceFingerprint(reopened)), expected)
    }

    func testCopied800RecordExportCanBeReviewedAndSkippedWithoutAnyStoreChanges() async throws {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("csv-copy.store")
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var expected: [String: [String: String]] = [:]
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 800)
            expected = try persistenceFingerprint(container)
            let service = FuelingRecordPersistenceService(container: container)
            for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) {
                let history = vehicle.fuelingRecords ?? []
                let csv = CSVService.exportRecords(history.map(CSVService.RecordSnapshot.init(record:)))
                let plan = try await service.prepareImport(
                    CSVImportService.parse(csv), vehicleID: vehicle.id, sourceUnit: vehicle.unitSystem)
                XCTAssertEqual(plan.possibleDuplicateIDs.count, history.count)
                let ids = try await service.importRecords(plan: plan, duplicates: .skipPossibleDuplicates)
                XCTAssertTrue(ids.isEmpty)
            }
            XCTAssertEqual(try persistenceFingerprint(container), expected)
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
        XCTAssertEqual(try persistenceFingerprint(reopened), expected)
    }
    private enum Failure: Error { case diskFull }

    func testCopied800RecordHistorySurvivesNotesAndDisplayCommandsAndReopenExactly() async throws {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        // SwiftData can retain SQLite handles past XCTest teardown. These
        // isolated stores stay in the test application's temporary directory.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("copy.store")
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema(versionedSchema: SchemaV6.self)
        var expected: [String: [String: String]] = [:]
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let reader = ModelContext(container)
            XCTAssertEqual(try reader.fetchCount(FetchDescriptor<FuelingRecord>()), 800)
            expected = try persistenceFingerprint(container)
            let record = try XCTUnwrap(
                reader.fetch(FetchDescriptor<FuelingRecord>()).first(where: {
                    expected["Journal:FuelingRecord:\($0.id)"] == nil
                        && expected["Journal:Vehicle:\($0.vehicle.id)"] == nil
                }))
            let owner = record.vehicle
            let original = FuelingRecordValues(record: record)
            var proposed = original
            proposed.notes = "Copied history: notes only"
            try await FuelingRecordPersistenceService(container: container).update(
                recordID: record.id,
                update: FuelingRecordUpdate(original: original, proposed: proposed, storageUnit: owner.unitSystem))
            let settings = VehicleSettingsValues(vehicle: owner)
            var display = settings
            display.displayUnit = settings.displayUnit == .imperial ? .metric : .imperial
            try await VehiclePersistenceService(container: container).update(
                vehicleID: owner.id,
                update: VehicleSettingsUpdate(original: settings, proposed: display))
            let actual = try persistenceFingerprint(container)
            let recordKey = "Record:\(record.id)"
            let vehicleKey = "Vehicle:\(owner.id)"
            XCTAssertNotEqual(actual[recordKey]?["modifiedAt"], expected[recordKey]?["modifiedAt"])
            XCTAssertNotEqual(actual[vehicleKey]?["modifiedAt"], expected[vehicleKey]?["modifiedAt"])
            expected[recordKey]?["notes"] = proposed.notes
            expected[recordKey]?["modifiedAt"] = actual[recordKey]?["modifiedAt"]
            expected[vehicleKey]?["displayUnit"] = display.displayUnit.rawValue
            expected[vehicleKey]?["modifiedAt"] = actual[vehicleKey]?["modifiedAt"]
            let newKeys = Set(actual.keys).subtracting(expected.keys)
            XCTAssertEqual(newKeys, ["Journal:FuelingRecord:\(record.id)", "Journal:Vehicle:\(owner.id)"])
            for key in newKeys {
                XCTAssertEqual(actual[key]?["operation"], "save")
                XCTAssertEqual(actual[key]?["origin"], "local")
                XCTAssertNotNil(UUID(uuidString: actual[key]?["generation"] ?? ""))
                expected[key] = actual[key]
            }
            XCTAssertEqual(actual, expected)
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        XCTAssertEqual(try persistenceFingerprint(reopened), expected)
    }

    func testImportRejectsReplayedOrDuplicateCommandIDsWithoutChangingTheStore() async throws {
        let fixture = try PersistenceFixture()
        let service = FuelingRecordPersistenceService(container: fixture.container)
        let rows = try fixture.importRows()
        do {
            _ =
                try await service.importRecords(
                    [rows[0], rows[0]], vehicleID: fixture.vehicleID, storageUnit: .imperial)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        _ = try await service.importRecords(rows, vehicleID: fixture.vehicleID, storageUnit: .imperial)
        let before = try fixture.fingerprint()
        do {
            _ = try await service.importRecords(rows, vehicleID: fixture.vehicleID, storageUnit: .imperial)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testCreateCommitsRecordCacheAndIntentOnceAndReturnsValues() async throws {
        let fixture = try PersistenceFixture()
        let commits = OSAllocatedUnfairLock(initialState: 0)
        let service = FuelingRecordPersistenceService(
            container: fixture.container,
            commit: { actor in
                let context = actor.modelContext
                commits.withLock { $0 += 1 }
                assertNativeWriterExecutor()
                XCTAssertFalse(context.autosaveEnabled)
                XCTAssertEqual(try fixture.vehicle(context).cachedRecordCount, 3)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
                try context.save()
            })
        let saved = try await service.create(
            values: fixture.values, storageUnit: .imperial, vehicleID: fixture.vehicleID)
        XCTAssertEqual(commits.withLock({ $0 }), 1)
        XCTAssertEqual(saved.values, fixture.values)
        XCTAssertEqual(saved.vehicleID, fixture.vehicleID)
        XCTAssertEqual(saved.previousOdometer, 1300.123456789)
        XCTAssertEqual(saved.distanceDriven, 400, accuracy: 0.000001)
        let context = fixture.context
        XCTAssertEqual(try fixture.vehicle(context).fuelingRecords?.count, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testFirstCreatedRecordIsPartial() async throws {
        let fixture = try PersistenceFixture(recordCount: 0)
        let saved = try await FuelingRecordPersistenceService(container: fixture.container).create(
            values: fixture.values, storageUnit: .imperial, vehicleID: fixture.vehicleID)
        XCTAssertEqual(saved.values.fillUpType, .partial)
        XCTAssertEqual(saved.efficiency, 0)
        XCTAssertEqual(saved.previousOdometer, 0)
    }

    func testEditCommitsTheRecordAndRecomputedHistoryTogether() async throws {
        let fixture = try PersistenceFixture()
        try await FuelingRecordPersistenceService(container: fixture.container).update(
            recordID: fixture.recordIDs.last!, update: fixture.update())
        let context = fixture.context
        XCTAssertEqual(try fixture.record(context).odometer, 1400.123456789)
        XCTAssertEqual(try fixture.record(context).cachedDistanceDriven ?? 0, 400, accuracy: 0.000001)
        XCTAssertEqual(try fixture.vehicle(context).cachedTotalSpent ?? 0, 80.123456789, accuracy: 0.000001)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncChange>()).map(\.operationRaw), ["save"])
    }

    func testDeleteCommitsVerifiedIntentAndRebuildsOnlyTheOwner() async throws {
        let fixture = try PersistenceFixture()
        let original = try fixture.fingerprint()["Vehicle:\(fixture.otherVehicleID)"]
        try await FuelingRecordPersistenceService(container: fixture.container).delete(
            recordID: fixture.recordIDs.last!)
        let context = fixture.context
        XCTAssertEqual(try fixture.vehicle(context).cachedRecordCount, 1)
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<SyncChange>()).first)
        XCTAssertEqual(entry.recordName, fixture.recordIDs.last!.uuidString)
        XCTAssertEqual(entry.operationRaw, "delete")
        XCTAssertEqual(entry.originRaw, "local")
        XCTAssertEqual(try fixture.fingerprint()["Vehicle:\(fixture.otherVehicleID)"], original)
    }

    func testEveryRecordCommandFailureIsAtomicAndRetryUsesFreshContext() async throws {
        for operation in 0..<4 {
            let fixture = try PersistenceFixture()
            let before = try fixture.fingerprint()
            let edit = try fixture.update()
            let imports = try fixture.importRows()
            let fail = OSAllocatedUnfairLock(initialState: true)
            let attempts = OSAllocatedUnfairLock(initialState: 0)
            let service = FuelingRecordPersistenceService(
                container: fixture.container,
                commit: {
                    attempts.withLock { $0 += 1 }
                    if fail.withLock({ $0 }) { throw Failure.diskFull }
                    try $0.modelContext.save()
                })
            func perform() async throws {
                switch operation {
                case 0:
                    _ = try await service.create(
                        values: fixture.values, storageUnit: .imperial, vehicleID: fixture.vehicleID)
                case 1: try await service.update(recordID: fixture.recordIDs.last!, update: edit)
                case 2: try await service.delete(recordID: fixture.recordIDs.last!)
                default:
                    _ = try await service.importRecords(imports, vehicleID: fixture.vehicleID, storageUnit: .imperial)
                }
            }
            do {
                _ = try await perform()
                XCTFail("Expected operation to throw")
            } catch let caughtError {
                _ = caughtError
            }
            XCTAssertEqual(try fixture.fingerprint(), before)
            fail.withLock { $0 = false }
            try await perform()
            XCTAssertNotEqual(try fixture.fingerprint(), before)
            XCTAssertEqual(attempts.withLock({ $0 }), 2)
        }
    }

    func testRealReadOnlyStoreRejectsEveryRecordCommandWithoutChangingData() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        let schema = Schema(versionedSchema: SchemaV6.self)
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: fixture.url, allowsSave: false, cloudKitDatabase: .none)
            ])
        let service = FuelingRecordPersistenceService(container: readOnly)
        do {
            _ =
                try await service.create(values: fixture.values, storageUnit: .imperial, vehicleID: fixture.vehicleID)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.update(recordID: fixture.recordIDs.last!, update: fixture.update())
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.delete(recordID: fixture.recordIDs.last!)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ =
                try await service.importRecords(
                    fixture.importRows(), vehicleID: fixture.vehicleID, storageUnit: .imperial)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testSuccessAndFailureDoNotSaveOrRollbackUnrelatedUIChanges() async throws {
        let fixture = try PersistenceFixture()
        let reader = fixture.container.mainContext
        reader.autosaveEnabled = false
        let visible = try fixture.record(reader)
        visible.notes = "Uncommitted UI draft"
        let failing = FuelingRecordPersistenceService(
            container: fixture.container, commit: { _ in throw Failure.diskFull })
        do {
            _ = try await failing.delete(recordID: fixture.recordIDs.last!)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        _ = try await FuelingRecordPersistenceService(container: fixture.container).create(
            values: fixture.values, storageUnit: .imperial, vehicleID: fixture.vehicleID)
        XCTAssertTrue(reader.hasChanges)
        XCTAssertEqual(visible.notes, "Uncommitted UI draft")
        let context = fixture.context
        XCTAssertEqual(try fixture.record(context).notes, "Original 1")
        reader.rollback()
    }

    func testNoOpSkipsCommitTimestampAndJournal() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        let context = fixture.context
        let values = try FuelingRecordValues(record: fixture.record(context))
        let changed = try await FuelingRecordPersistenceService(
            container: fixture.container, commit: { _ in XCTFail("No-op save") }
        )
        .update(recordID: fixture.recordIDs.last!, update: FuelingRecordUpdate(original: values, proposed: values))
        XCTAssertFalse(changed)
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testInvalidChronologyAndObsoleteStorageBasisAreRejectedBeforeSaving() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        let service = FuelingRecordPersistenceService(
            container: fixture.container, commit: { _ in XCTFail("Invalid input save") })
        var invalid = fixture.values
        invalid.odometer = 500
        do {
            _ = try await service.create(values: invalid, storageUnit: .imperial, vehicleID: fixture.vehicleID)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ =
                try await service.create(values: fixture.values, storageUnit: .metric, vehicleID: fixture.vehicleID)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
    }
}

@MainActor
final class VehiclePersistenceServiceTests: XCTestCase {
    private enum Failure: Error { case diskFull }

    func testVehicleDeletionPreservesEverySurvivingValueFromAnUnloadedGraph() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        try await VehiclePersistenceService(container: fixture.container).delete(vehicleID: fixture.vehicleID)
        let saved = fixture.context
        XCTAssertEqual(try saved.fetch(FetchDescriptor<Vehicle>()).map(\.id), [fixture.otherVehicleID])
        XCTAssertEqual(try saved.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try saved.fetchCount(FetchDescriptor<SyncChange>()), fixture.recordIDs.count + 1)
        let after = try fixture.fingerprint()
        for (key, value) in after where !key.hasPrefix("Journal:") { XCTAssertEqual(value, before[key]) }
    }

    func testFailedLegacyUnitDecisionPreservesMeasurementsAndInboxUntilRetry() async throws {
        let fixture = try PersistenceFixture()
        let context = fixture.context
        let vehicle = try fixture.vehicle(context)
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let incoming = codec.vehicleToCKRecord(vehicle)
        incoming[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] = "metric"
        try await SyncPersistenceStore(container: fixture.container).capture(modifications: [incoming], deletions: [])
        let item = try XCTUnwrap(SyncReviewService.items(in: context).first)
        let original = try fixture.fingerprint()
        let schema = Schema(versionedSchema: SchemaV6.self)
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: fixture.url, allowsSave: false, cloudKitDatabase: .none)
            ])
        do {
            _ = try await SyncReviewService.confirm(
                item, sourceUnit: .metric, writer: OwnedModelStore(container: readOnly))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), original)
        XCTAssertEqual(try SyncReviewService.items(in: context).map(\.archivedPayload), [item.archivedPayload])
        try await SyncReviewService.confirm(
            item, sourceUnit: .metric, writer: OwnedModelStore(container: fixture.container))
        let saved = fixture.context
        XCTAssertEqual(try fixture.vehicle(saved).unitSystem, .metric)
        XCTAssertEqual(try saved.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
        XCTAssertEqual(
            try saved.fetchCount(FetchDescriptor<SyncChange>()), 0, "Unit adoption must not queue bulk uploads")
    }

    func testFailedLegacyDeletionDecisionPreservesItsGenerationAndAllData() async throws {
        let fixture = try PersistenceFixture()
        let context = fixture.context
        let legacy = SyncChange(
            recordName: fixture.vehicleID.uuidString, recordTypeRaw: "Vehicle", operationRaw: "delete")
        legacy.originRaw = nil
        context.insert(legacy)
        let childDecision = SyncChange(
            recordName: fixture.recordIDs[0].uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        childDecision.originRaw = nil
        context.insert(childDecision)
        try context.save()
        let original = try fixture.fingerprint()
        let schema = Schema(versionedSchema: SchemaV6.self)
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: fixture.url, allowsSave: false, cloudKitDatabase: .none)
            ])
        do {
            _ = try await SyncReviewService.resolveLegacyDeletions(
                apply: true, writer: OwnedModelStore(container: readOnly))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), original)
        try await SyncReviewService.resolveLegacyDeletions(
            apply: true, writer: OwnedModelStore(container: fixture.container))
        let saved = fixture.context
        XCTAssertEqual(try saved.fetch(FetchDescriptor<Vehicle>()).map(\.id), [fixture.otherVehicleID])
        let entries = try saved.fetch(FetchDescriptor<SyncChange>())
        XCTAssertEqual(Set(entries.map(\.recordName)), Set((fixture.recordIDs + [fixture.vehicleID]).map(\.uuidString)))
        XCTAssertTrue(entries.allSatisfy { $0.originRaw != nil && $0.operationRaw == "delete" })
    }

    private func update(_ fixture: PersistenceFixture) throws -> VehicleSettingsUpdate {
        let context = fixture.context
        let original = try VehicleSettingsValues(vehicle: fixture.vehicle(context))
        var proposed = original
        proposed.name = "Renamed"
        proposed.displayUnit = .metric
        return VehicleSettingsUpdate(original: original, proposed: proposed)
    }

    func testCreateUsesOneExplicitCommitAndReturnsAnID() async throws {
        let fixture = try PersistenceFixture()
        let commits = OSAllocatedUnfairLock(initialState: 0)
        let id = try await VehiclePersistenceService(
            container: fixture.container,
            commit: {
                commits.withLock { $0 += 1 }
                assertNativeWriterExecutor()
                XCTAssertEqual(try $0.modelContext.fetchCount(FetchDescriptor<SyncChange>()), 1)
                try $0.modelContext.save()
            }
        ).create(values: VehicleSettingsValues(name: "New", displayUnit: .metric), storageUnit: .metric)
        let context = fixture.context
        let vehicle = try XCTUnwrap(
            context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(commits.withLock({ $0 }), 1)
        XCTAssertEqual(vehicle.name, "New")
        XCTAssertEqual(vehicle.unitSystem, .metric)
        XCTAssertEqual(vehicle.displayUnitSystem, .metric)
    }

    func testSettingsChangeDisplayUnitsWithoutRewritingStoredMeasurementsOrCaches() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        try await VehiclePersistenceService(container: fixture.container).update(
            vehicleID: fixture.vehicleID, update: update(fixture))
        let context = fixture.context
        let vehicle = try fixture.vehicle(context)
        XCTAssertEqual(vehicle.name, "Renamed")
        XCTAssertEqual(vehicle.unitSystem, .imperial)
        XCTAssertEqual(vehicle.displayUnitSystem, .metric)
        for id in fixture.recordIDs {
            XCTAssertEqual(try fixture.fingerprint()["Record:\(id)"], before["Record:\(id)"])
        }
        XCTAssertEqual(
            try fixture.fingerprint()["Vehicle:\(fixture.otherVehicleID)"], before["Vehicle:\(fixture.otherVehicleID)"])
    }

    func testClearHistoryDeletesChildrenAndCommitsOnlyTheirIntent() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()["Vehicle:\(fixture.otherVehicleID)"]
        try await VehiclePersistenceService(container: fixture.container).clearFuelingHistory(
            vehicleID: fixture.vehicleID)
        let context = fixture.context
        XCTAssertEqual(try fixture.vehicle(context).fuelingRecords?.count, 0)
        XCTAssertEqual(try fixture.vehicle(context).cachedRecordCount, 0)
        let journal = try context.fetch(FetchDescriptor<SyncChange>())
        XCTAssertEqual(Set(journal.map(\.recordName)), Set(fixture.recordIDs.map(\.uuidString)))
        XCTAssertTrue(journal.allSatisfy { $0.operationRaw == "delete" && $0.originRaw == "local" })
        XCTAssertEqual(try fixture.fingerprint()["Vehicle:\(fixture.otherVehicleID)"], before)
    }

    func testVehicleDeleteCommitsParentAndChildDeletionIntentTogether() async throws {
        let fixture = try PersistenceFixture()
        try await VehiclePersistenceService(container: fixture.container).delete(vehicleID: fixture.vehicleID)
        let context = fixture.context
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vehicle>()).map(\.id), [fixture.otherVehicleID])
        let entries = try context.fetch(FetchDescriptor<SyncChange>())
        XCTAssertEqual(Set(entries.map(\.recordName)), Set((fixture.recordIDs + [fixture.vehicleID]).map(\.uuidString)))
        XCTAssertTrue(entries.allSatisfy { $0.operationRaw == "delete" && $0.originRaw == "local" })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
    }

    func testDeleteAllCommitsEveryDeletionIntentOnce() async throws {
        let fixture = try PersistenceFixture()
        let commits = OSAllocatedUnfairLock(initialState: 0)
        try await VehiclePersistenceService(
            container: fixture.container,
            commit: {
                commits.withLock { $0 += 1 }; try $0.modelContext.save()
            }
        ).deleteAllData()
        let context = fixture.context
        XCTAssertEqual(commits.withLock({ $0 }), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 5)
    }

    func testEveryVehicleCommandFailureIsAtomicAndRetryUsesFreshContext() async throws {
        for operation in 0..<5 {
            let fixture = try PersistenceFixture()
            let before = try fixture.fingerprint()
            let edit = try update(fixture)
            let fail = OSAllocatedUnfairLock(initialState: true)
            let service = VehiclePersistenceService(
                container: fixture.container,
                commit: {
                    if fail.withLock({ $0 }) { throw Failure.diskFull }
                    try $0.modelContext.save()
                })
            func perform() async throws {
                switch operation {
                case 0: _ = try await service.create(values: VehicleSettingsValues(name: "New"), storageUnit: .imperial)
                case 1: try await service.update(vehicleID: fixture.vehicleID, update: edit)
                case 2: try await service.delete(vehicleID: fixture.vehicleID)
                case 3: try await service.clearFuelingHistory(vehicleID: fixture.vehicleID)
                default: try await service.deleteAllData()
                }
            }
            do {
                _ = try await perform()
                XCTFail("Expected operation to throw")
            } catch let caughtError {
                _ = caughtError
            }
            XCTAssertEqual(try fixture.fingerprint(), before)
            fail.withLock { $0 = false }
            try await perform()
            XCTAssertNotEqual(try fixture.fingerprint(), before)
        }
    }

    func testRealReadOnlyStoreRejectsEveryVehicleCommandWithoutChangingData() async throws {
        let fixture = try PersistenceFixture()
        let before = try fixture.fingerprint()
        let schema = Schema(versionedSchema: SchemaV6.self)
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: fixture.url, allowsSave: false, cloudKitDatabase: .none)
            ])
        let service = VehiclePersistenceService(container: readOnly)
        do {
            _ = try await service.create(values: VehicleSettingsValues(name: "New"), storageUnit: .imperial)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.update(vehicleID: fixture.vehicleID, update: update(fixture))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.clearFuelingHistory(vehicleID: fixture.vehicleID)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.delete(vehicleID: fixture.vehicleID)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await service.deleteAllData()
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testNoOpSettingsAndEmptyHistoryDoNotCommit() async throws {
        let fixture = try PersistenceFixture(recordCount: 0)
        let before = try fixture.fingerprint()
        let context = fixture.context
        let original = try VehicleSettingsValues(vehicle: fixture.vehicle(context))
        let service = VehiclePersistenceService(container: fixture.container, commit: { _ in XCTFail("No-op save") })
        let asyncResult17 = try await service.update(
            vehicleID: fixture.vehicleID, update: VehicleSettingsUpdate(original: original, proposed: original))
        XCTAssertFalse(asyncResult17)
        try await service.clearFuelingHistory(vehicleID: fixture.vehicleID)
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testSettingsMergePreservesUneditedFieldsAndRejectsConflictingEdits() async throws {
        let fixture = try PersistenceFixture()
        let reader = fixture.context
        let original = try VehicleSettingsValues(vehicle: fixture.vehicle(reader))
        var remote = original
        remote.make = "Updated elsewhere"
        let service = VehiclePersistenceService(container: fixture.container)
        try await service.update(
            vehicleID: fixture.vehicleID, update: VehicleSettingsUpdate(original: original, proposed: remote))
        var mine = original
        mine.name = "My name"
        try await service.update(
            vehicleID: fixture.vehicleID, update: VehicleSettingsUpdate(original: original, proposed: mine))
        let context = fixture.context
        XCTAssertEqual(try fixture.vehicle(context).make, "Updated elsewhere")
        XCTAssertEqual(try fixture.vehicle(context).name, "My name")
        mine.make = "Conflicting make"
        let before = try fixture.fingerprint()
        do {
            _ =
                try await service.update(
                    vehicleID: fixture.vehicleID, update: VehicleSettingsUpdate(original: original, proposed: mine))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
    }
}
