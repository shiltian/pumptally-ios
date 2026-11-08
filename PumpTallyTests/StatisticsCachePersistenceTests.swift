import CloudKit
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class StatisticsCachePersistenceTests: XCTestCase {
    private enum Failure: Error { case diskFull }

    private struct RecordState: Equatable {
        let owner: UUID
        let values: FuelingRecordValues
        let bits: [UInt64?]
    }

    private struct Snapshot: Equatable {
        let records: [UUID: RecordState]
        let vehicles: [UUID: [String?]]
        let journal: [String: [String?]]
    }

    private struct Fixture {
        let container: ModelContainer
        let url: URL
        let owners: [UUID]
        let records: [UUID]
    }

    private func fixture(cached: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cache.store")
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var owners: [UUID] = []
        var records: [UUID] = []
        for index in 0..<2 {
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index))
            let owner = Vehicle(name: "Owner \(index)", createdAt: date)
            context.insert(owner)
            let record = FuelingRecord(
                date: date, odometer: 1000.123456789,
                pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789, totalCost: 35.123456789,
                notes: "Original \(index)", createdAt: date, vehicle: owner)
            context.insert(record)
            owners.append(owner.id)
            records.append(record.id)
        }
        context.processPendingChanges()
        if cached {
            for owner in try context.fetch(FetchDescriptor<Vehicle>()) {
                StatisticsCacheService.recalculateAllStatistics(for: owner)
            }
        }
        let legacy = SyncChange(recordName: UUID().uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        legacy.originRaw = nil
        context.insert(legacy)
        try context.save()
        return Fixture(container: container, url: url, owners: owners, records: records)
    }

    private func snapshot(_ container: ModelContainer) throws -> Snapshot {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FuelingRecord>()).map { r in
            (
                r.id,
                RecordState(
                    owner: r.vehicle.id, values: FuelingRecordValues(record: r),
                    bits: [
                        r.odometer.bitPattern, r.pricePerFuelUnit.bitPattern, r.fuelAmount.bitPattern,
                        r.totalCost.bitPattern,
                        r.date.timeIntervalSince1970.bitPattern, r.createdAt.timeIntervalSince1970.bitPattern,
                        r.modifiedAt?.timeIntervalSince1970.bitPattern,
                    ])
            )
        }
        let vehicles = try context.fetch(FetchDescriptor<Vehicle>()).map { v in
            (
                v.id,
                [
                    v.name, v.make, v.model, v.year.map(String.init), v.unitSystemRaw, v.displayUnitSystemRaw,
                    String(v.createdAt.timeIntervalSince1970.bitPattern),
                    v.modifiedAt.map { String($0.timeIntervalSince1970.bitPattern) },
                ]
            )
        }
        let journal = try context.fetch(FetchDescriptor<SyncChange>()).map { j in
            (
                j.key,
                [
                    j.recordName, j.recordTypeRaw, j.operationRaw, j.originRaw, j.generation,
                    String(j.createdAt.timeIntervalSince1970.bitPattern),
                ]
            )
        }
        return Snapshot(
            records: Dictionary(uniqueKeysWithValues: records), vehicles: Dictionary(uniqueKeysWithValues: vehicles),
            journal: Dictionary(uniqueKeysWithValues: journal))
    }

    private func owner(_ id: UUID, in context: ModelContext) throws -> Vehicle {
        try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })).first)
    }

    private func record(_ id: UUID, in context: ModelContext) throws -> FuelingRecord {
        try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    func testColdRebuildCommitsEachVehicleOnceAndPreservesBusinessDataAndIntent() async throws {
        let fixture = try fixture()
        let before = try snapshot(fixture.container)
        let commits = OSAllocatedUnfairLock(initialState: 0)
        let service = StatisticsCachePersistenceService(
            container: fixture.container,
            commit: {
                XCTAssertFalse($0.modelContext.autosaveEnabled)
                assertNativeWriterExecutor()
                commits.withLock { $0 += 1 }
                try $0.modelContext.save()
            })
        let count = try await service.rebuildIfNeeded()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(commits.withLock({ $0 }), 2)
        XCTAssertEqual(try snapshot(fixture.container), before)
        let context = ModelContext(fixture.container)
        for id in fixture.owners {
            let owner = try owner(id, in: context)
            XCTAssertEqual(owner.cachedRecordCount, 1)
            XCTAssertEqual(owner.cachedTotalSpent, 35.123456789)
            XCTAssertNotNil(owner.cacheLastUpdated)
        }
    }

    func testValidCachesPerformNoSaveAndKeepTheirDates() async throws {
        let fixture = try fixture(cached: true)
        let reader = ModelContext(fixture.container)
        let dates = try reader.fetch(FetchDescriptor<Vehicle>()).map(\.cacheLastUpdated)
        let service = StatisticsCachePersistenceService(
            container: fixture.container, commit: { _ in XCTFail("Valid caches must not save") })
        let count = try await service.rebuildIfNeeded()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(
            try ModelContext(fixture.container).fetch(FetchDescriptor<Vehicle>()).map(\.cacheLastUpdated), dates)
    }

    func testRecordCountMismatchRepairsOnlyTheAffectedVehicle() async throws {
        let fixture = try fixture(cached: true)
        let context = ModelContext(fixture.container)
        let changed = try owner(fixture.owners[0], in: context)
        let otherDate = try owner(fixture.owners[1], in: context).cacheLastUpdated
        changed.cachedRecordCount = 42
        try context.save()
        let count = try await StatisticsCachePersistenceService(container: fixture.container).rebuildIfNeeded()
        XCTAssertEqual(count, 1)
        let saved = ModelContext(fixture.container)
        XCTAssertEqual(try owner(fixture.owners[0], in: saved).cachedRecordCount, 1)
        XCTAssertEqual(try owner(fixture.owners[1], in: saved).cacheLastUpdated, otherDate)
    }

    func testEmptyVehicleGetsAValidZeroRecordCache() async throws {
        let fixture = try fixture()
        let id = try await VehiclePersistenceService(container: fixture.container).create(
            values: VehicleSettingsValues(name: "Empty"), storageUnit: .imperial)
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try owner(id, in: context).cachedRecordCount, 0)
        XCTAssertNotNil(try owner(id, in: context).cacheLastUpdated)
        let service = StatisticsCachePersistenceService(
            container: fixture.container, commit: { _ in XCTFail("Empty vehicle is already initialized") })
        let asyncResult1 = try await service.rebuildIfNeeded(vehicleID: id)
        XCTAssertFalse(asyncResult1)
    }

    func testFailedVehicleRepairRollsBackAndRetrySkipsCompletedVehicles() async throws {
        let fixture = try fixture()
        let before = try snapshot(fixture.container)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let fail = OSAllocatedUnfairLock(initialState: true)
        let service = StatisticsCachePersistenceService(
            container: fixture.container,
            commit: {
                attempts.withLock { $0 += 1 }
                if attempts.withLock({ $0 }) == 2 && fail.withLock({ $0 }) { throw Failure.diskFull }
                try $0.modelContext.save()
            })
        do {
            _ = try await service.rebuildIfNeeded()
            XCTFail("Expected failed save")
        } catch {}
        XCTAssertEqual(try snapshot(fixture.container), before)
        let reader = ModelContext(fixture.container)
        let completed = try owner(fixture.owners[0], in: reader).cacheLastUpdated
        XCTAssertNotNil(completed)
        XCTAssertNil(try owner(fixture.owners[1], in: reader).cacheLastUpdated)
        fail.withLock { $0 = false }
        let count = try await service.rebuildIfNeeded()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(attempts.withLock({ $0 }), 3)
        let saved = ModelContext(fixture.container)
        XCTAssertEqual(try owner(fixture.owners[0], in: saved).cacheLastUpdated, completed)
        XCTAssertEqual(try snapshot(fixture.container), before)
    }

    func testActualReadOnlySaveFailureLeavesCachesAndDataUntouched() async throws {
        let fixture = try fixture()
        let before = try snapshot(fixture.container)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let readOnly = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: fixture.url, allowsSave: false, cloudKitDatabase: .none)
            ])
        do {
            _ = try await StatisticsCachePersistenceService(container: readOnly).rebuildIfNeeded()
            XCTFail("Read-only save must fail.withLock({ $0 })")
        } catch { XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain) }
        let reader = ModelContext(fixture.container)
        XCTAssertNil(try owner(fixture.owners[0], in: reader).cacheLastUpdated)
        XCTAssertEqual(try snapshot(fixture.container), before)
    }

    func testCancelledStartupDoesNotBeginAWrite() async throws {
        let fixture = try fixture()
        let before = try snapshot(fixture.container)
        let service = StatisticsCachePersistenceService(
            container: fixture.container, commit: { _ in XCTFail("Cancelled write") })
        let task = Task { try await service.rebuildIfNeeded() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try snapshot(fixture.container), before)
    }

    func testDeletedWorkItemIsSkippedWithoutSaving() async throws {
        let fixture = try fixture()
        let id = fixture.owners[0]
        try await VehiclePersistenceService(container: fixture.container).delete(vehicleID: id)
        let before = try snapshot(fixture.container)
        let asyncResult2 = try await StatisticsCachePersistenceService(
            container: fixture.container, commit: { _ in XCTFail("Deleted cache write") }
        ).rebuildIfNeeded(vehicleID: id)
        XCTAssertFalse(asyncResult2)
        XCTAssertEqual(try snapshot(fixture.container), before)
    }

    func testCancellationBetweenVehiclesPreservesProgressAndRetryRepairsTheRemainder() async throws {
        let fixture = try fixture()
        let before = try snapshot(fixture.container)
        let commits = OSAllocatedUnfairLock(initialState: 0)
        let caller = OSAllocatedUnfairLock<Task<Int, Error>?>(initialState: nil)
        let service = StatisticsCachePersistenceService(container: fixture.container) {
            try $0.modelContext.save()
            commits.withLock { $0 += 1 }
            if commits.withLock({ $0 }) == 1 { caller.withLock { $0?.cancel() } }
        }
        let task = Task { try await service.rebuildIfNeeded() }
        caller.withLock { $0 = task }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation between transactions")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(commits.withLock({ $0 }), 1)
        let reader = ModelContext(fixture.container)
        let completedDate = try owner(fixture.owners[0], in: reader).cacheLastUpdated
        XCTAssertNotNil(completedDate)
        XCTAssertNil(try owner(fixture.owners[1], in: reader).cacheLastUpdated)
        let repaired = try await service.rebuildIfNeeded()
        XCTAssertEqual(repaired, 1)
        let saved = ModelContext(fixture.container)
        XCTAssertEqual(try owner(fixture.owners[0], in: saved).cacheLastUpdated, completedDate)
        XCTAssertEqual(try snapshot(fixture.container), before)
    }

    func testConcurrentRepairLocalEditAndRemoteApplyKeepCachesAndBusinessValuesConsistent() async throws {
        let fixture = try fixture()
        let reader = ModelContext(fixture.container)
        let first = try record(fixture.records[0], in: reader)
        let original = FuelingRecordValues(record: first)
        var proposed = original
        proposed.totalCost = 45.987654321
        proposed.notes = "Local edit"
        let update = FuelingRecordUpdate(original: original, proposed: proposed, storageUnit: .imperial)
        let second = try record(fixture.records[1], in: reader)
        second.totalCost = 55.987654321
        second.modifiedAt = Date(timeIntervalSince1970: 2_000_000)
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let incoming = codec.fuelingRecordToCKRecord(
            second, vehicleRecordID: codec.vehicleToCKRecord(second.vehicle).recordID)
        reader.rollback()
        let firstID = fixture.records[0]
        let writer = OwnedModelStore(container: fixture.container)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await StatisticsCachePersistenceService(writer: writer).rebuildIfNeeded()
            }
            group.addTask {
                try await FuelingRecordPersistenceService(writer: writer).update(
                    recordID: firstID, update: update)
            }
            group.addTask {
                try await writer.transaction { actor in
                    _ = try CloudReconciliationService(codec: codec).stageRemoteChanges(
                        changedRecords: [incoming], deletedRecordIDs: [], context: actor.modelContext)
                }
            }
            try await group.waitForAll()
        }
        let saved = ModelContext(fixture.container)
        XCTAssertEqual(try record(firstID, in: saved).totalCost, 45.987654321)
        XCTAssertEqual(try record(firstID, in: saved).notes, "Local edit")
        XCTAssertEqual(try record(fixture.records[1], in: saved).totalCost, 55.987654321)
        XCTAssertEqual(try owner(fixture.owners[0], in: saved).cachedTotalSpent, 45.987654321)
        XCTAssertEqual(try owner(fixture.owners[1], in: saved).cachedTotalSpent, 55.987654321)
    }

    func testCopied800RecordHistorySurvivesCacheRepairAndReopenExactly() async throws {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("copy.store")
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema(versionedSchema: SchemaV6.self)
        var expected: Snapshot!
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            expected = try snapshot(container)
            XCTAssertEqual(expected.records.count, 800)
            let context = ModelContext(container)
            for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) { vehicle.cacheLastUpdated = nil }
            try context.save()
            let count = try await StatisticsCachePersistenceService(container: container).rebuildIfNeeded()
            XCTAssertEqual(count, expected.vehicles.count)
            XCTAssertEqual(try snapshot(container), expected)
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        XCTAssertEqual(try snapshot(reopened), expected)
        let reader = ModelContext(reopened)
        for vehicle in try reader.fetch(FetchDescriptor<Vehicle>()) {
            XCTAssertEqual(vehicle.cachedRecordCount, vehicle.fuelingRecords?.count)
            XCTAssertNotNil(vehicle.cacheLastUpdated)
        }
    }
}
