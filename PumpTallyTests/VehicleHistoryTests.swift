import CloudKit
import Combine
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
struct VehicleHistoryFixture {
    let container: ModelContainer
    let vehicleID: UUID
    let values: [UUID: FuelingRecordValues]

    init(count: Int, unrelated: Int = 0) throws {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("History-\(UUID()).store")
        container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "History fixture")
        context.insert(vehicle)
        vehicleID = vehicle.id
        var originals: [UUID: FuelingRecordValues] = [:]
        for index in 0..<count {
            let record = FuelingRecord(
                date: Date(timeIntervalSince1970: 1_000_000 + Double(index / 2) * 86_400),
                odometer: 1000.123456789 + Double(index / 2) * 300,
                pricePerFuelUnit: Double(3 + index % 5), fuelAmount: 10.123456789,
                totalCost: 35.123456789 + Double(index % 7), notes: "Record \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
            context.insert(record)
            originals[record.id] = FuelingRecordValues(record: record)
        }
        StatisticsCacheService.refresh(for: vehicle)
        if unrelated > 0 {
            let other = Vehicle(name: "Unrelated vehicle")
            context.insert(other)
            for index in 0..<unrelated {
                context.insert(
                    FuelingRecord(
                        odometer: Double(index), pricePerFuelUnit: 9,
                        fuelAmount: 1, totalCost: 9, notes: "Unrelated", vehicle: other))
            }
        }
        try context.save()
        values = originals
    }

    func source() async throws -> VehicleHistorySource {
        let id = vehicleID
        return try await VehicleHistoryReader.read(container: container) { reader in
            try reader.read(vehicleID: id)
        }
    }
}

@MainActor
final class VehicleHistoryTests: XCTestCase {
    private let query = VehicleHistoryRepository.Query(searchText: "", sortOrder: .dateDescending)

    func testNativeReadIsScopedReadOnlyAndLeavesMainActorAvailable() async throws {
        let fixture = try VehicleHistoryFixture(count: 800, unrelated: 3200)
        let responded = OSAllocatedUnfairLock(initialState: false)
        let id = fixture.vehicleID
        let source = try await VehicleHistoryReader.read(container: fixture.container) { reader in
            XCTAssertFalse(Thread.isMainThread)
            try observeOnMainActor { responded.withLock { $0 = true } }
            let value = try reader.read(vehicleID: id)
            XCTAssertFalse(reader.modelContext.hasChanges)
            return value
        }
        XCTAssertTrue(responded.withLock { $0 })
        XCTAssertEqual(source.records.count, 800)
        XCTAssertEqual(Set(source.records.map(\.id)), Set(fixture.values.keys))
        for record in source.records {
            let expected = try XCTUnwrap(fixture.values[record.id])
            XCTAssertEqual(record.values, expected)
            XCTAssertEqual(record.values.odometer.bitPattern, expected.odometer.bitPattern)
            XCTAssertEqual(record.values.pricePerFuelUnit.bitPattern, expected.pricePerFuelUnit.bitPattern)
            XCTAssertEqual(record.values.fuelAmount.bitPattern, expected.fuelAmount.bitPattern)
            XCTAssertEqual(record.values.totalCost.bitPattern, expected.totalCost.bitPattern)
        }
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
        XCTAssertFalse(fixture.container.mainContext.hasChanges)
    }

    func testPagesAreBoundedCompleteAndReuseTheSourceAndSearchIndex() async throws {
        let fixture = try VehicleHistoryFixture(count: 106, unrelated: 100)
        let repository = VehicleHistoryRepository(container: fixture.container, vehicleID: fixture.vehicleID)
        let data = try await repository.refresh(revision: 0, format: .defaultFormat)
        var rows: [FuelingHistoryRecord] = []
        for offset in stride(from: 0, to: 106, by: VehicleHistoryPage.size) {
            let result = try await repository.page(version: data.version, query: query, offset: offset)
            let page = try XCTUnwrap(result)
            XCTAssertLessThanOrEqual(page.records.count, 50)
            XCTAssertEqual(page.totalCount, 106)
            rows.append(contentsOf: page.records)
        }
        XCTAssertEqual(rows.count, 106)
        XCTAssertEqual(Set(rows.map(\.id)), Set(fixture.values.keys))
        let expected = fixture.values.sorted {
            OdometerChronologyValidator.areInIncreasingOrder(
                lhsDate: $1.value.date, lhsOdometer: $1.value.odometer, lhsID: $1.key,
                rhsDate: $0.value.date, rhsOdometer: $0.value.odometer, rhsID: $0.key)
        }.map(\.key)
        XCTAssertEqual(rows.map(\.id), expected)
        let searchResult = try await repository.page(
            version: data.version, query: .init(searchText: "RECORD 105", sortOrder: .costHighest), offset: 0)
        let searched = try XCTUnwrap(searchResult)
        XCTAssertEqual(searched.records.map(\.values.notes), ["Record 105"])
        let loads = await repository.sourceLoads
        let preparations = await repository.chartPreparations
        let evaluations = await repository.queryEvaluations
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(evaluations, 2)
    }

    func testNotesAndFormatChangesReuseChartsAndSourceWhileStalePagesAreRejected() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let repository = VehicleHistoryRepository(container: fixture.container, vehicleID: fixture.vehicleID)
        let before = try await repository.refresh(revision: 0, format: .defaultFormat)
        let id = try XCTUnwrap(fixture.values.keys.first)
        try await OwnedModelStore(container: fixture.container).transaction { actor in
            let record = try XCTUnwrap(
                actor.modelContext.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
            record.notes = "New searchable note"
        }
        let after = try await repository.refresh(revision: 1, format: .defaultFormat)
        XCTAssertNotEqual(after.version, before.version)
        let stale = try await repository.page(version: before.version, query: query, offset: 0)
        XCTAssertNil(stale)
        let page = try await repository.page(
            version: after.version,
            query: .init(searchText: "New searchable note", sortOrder: .dateDescending), offset: 0)
        XCTAssertEqual(page?.records.map(\.id), [id])
        let preparations = await repository.chartPreparations
        XCTAssertEqual(preparations, 1)
        _ = try await repository.refresh(revision: 1, format: MetricEfficiencyFormat.allCases.last!)
        let loads = await repository.sourceLoads
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(before.chartData.priceData, after.chartData.priceData)
    }

    func testNativeSaveNotificationsRefreshRemotePriceSwapWithoutCacheTimestampChanges() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let model = VehicleHistoryModel(container: fixture.container, vehicleID: fixture.vehicleID)
        await model.reload(revision: model.revision, format: .defaultFormat)
        let before = try XCTUnwrap(model.presentation)
        let context = ModelContext(fixture.container)
        let vehicle = try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>()).first)
        let timestamp = vehicle.cacheLastUpdated
        let records = try context.fetch(FetchDescriptor<FuelingRecord>()).sorted {
            $0.pricePerFuelUnit < $1.pricePerFuelUnit
        }
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let incoming = try records.prefix(2).enumerated().map { index, record in
            let remote = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            remote[CloudRecordCodec.CloudFieldKey.FuelingRecord.pricePerFuelUnit] = index == 0 ? 4.0 : 3.0
            remote[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 2_000_000)
            return try CloudMeasurementPayload.confirmedLegacyRecord(remote, unit: .imperial)
        }
        try await OwnedModelStore(container: fixture.container).transaction { actor in
            _ = try CloudReconciliationService(codec: codec).stageRemoteChanges(
                changedRecords: incoming, deletedRecordIDs: [], context: actor.modelContext)
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.revision > 0 }, object: nil)
        await fulfillment(of: [changed], timeout: 5)
        await model.reload(revision: model.revision, format: .defaultFormat)
        let after = try XCTUnwrap(model.presentation)
        let reader = ModelContext(fixture.container)
        XCTAssertEqual(try reader.fetch(FetchDescriptor<Vehicle>()).first?.cacheLastUpdated, timestamp)
        XCTAssertNotEqual(after.chartData.priceData, before.chartData.priceData)
        XCTAssertEqual(after.chartData.priceAverage, before.chartData.priceAverage)
        let prices = Dictionary(uniqueKeysWithValues: after.chartData.priceData.map { ($0.id, $0.value) })
        XCTAssertEqual(prices[records[0].id], 4)
        XCTAssertEqual(prices[records[1].id], 3)
    }

    func testJournalAndOtherContainerSavesDoNotInvalidateTheReadModel() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let model = VehicleHistoryModel(container: fixture.container, vehicleID: fixture.vehicleID)
        await model.reload(revision: 0, format: .defaultFormat)
        let invalidation = expectation(description: "Irrelevant saves must not reload history")
        invalidation.isInverted = true
        let subscription = model.$revision.dropFirst().sink { _ in invalidation.fulfill() }
        defer { subscription.cancel() }
        try await OwnedModelStore(container: fixture.container).transaction { actor in
            let record = try XCTUnwrap(actor.modelContext.fetch(FetchDescriptor<FuelingRecord>()).first)
            try SyncChangeJournal.enqueue(record, in: actor.modelContext)
        }
        _ = try VehicleHistoryFixture(count: 1)
        await fulfillment(of: [invalidation], timeout: 0.3)
        XCTAssertEqual(model.revision, 0)
    }

    func testNativeInsertAndDeleteRefreshCountsLatestRecordAndPages() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let model = VehicleHistoryModel(container: fixture.container, vehicleID: fixture.vehicleID)
        await model.reload(revision: 0, format: .defaultFormat)
        let service = FuelingRecordPersistenceService(writer: OwnedModelStore(container: fixture.container))
        let saved = try await service.create(
            values: FuelingRecordValues(
                date: Date(timeIntervalSince1970: 2_000_000), odometer: 3000.123456789,
                pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789, totalCost: 35.123456789,
                fillUpType: .full, notes: "Newest saved record"), storageUnit: .imperial, vehicleID: fixture.vehicleID)
        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.revision > 0 }, object: nil)
        await fulfillment(of: [inserted], timeout: 5)
        await model.reload(revision: model.revision, format: .defaultFormat)
        XCTAssertEqual(model.presentation?.recordCount, 4)
        XCTAssertEqual(model.presentation?.latestRecord?.id, saved.id)
        let revision = model.revision
        try await service.delete(recordID: saved.id)
        let deleted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in model.revision > revision }, object: nil)
        await fulfillment(of: [deleted], timeout: 5)
        await model.reload(revision: model.revision, format: .defaultFormat)
        let data = try XCTUnwrap(model.presentation)
        XCTAssertEqual(data.recordCount, 3)
        XCTAssertNotEqual(data.latestRecord?.id, saved.id)
        let page = await model.page(version: data.version, query: query, offset: 0)
        XCTAssertEqual(Set(page!.records.map(\.id)), Set(fixture.values.keys))
    }

    func testDisplayUnitsRefreshSearchAndChartsWithoutRewritingStoredValues() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let repository = VehicleHistoryRepository(container: fixture.container, vehicleID: fixture.vehicleID)
        let imperial = try await repository.refresh(revision: 0, format: .defaultFormat)
        let id = fixture.vehicleID
        try await OwnedModelStore(container: fixture.container).transaction { actor in
            let vehicle = try XCTUnwrap(
                actor.modelContext.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })).first)
            vehicle.displayUnitSystem = .metric
        }
        let metric = try await repository.refresh(revision: 1, format: .defaultFormat)
        XCTAssertEqual(metric.chartData.unitSystem, .metric)
        XCTAssertEqual(
            metric.chartData.priceAverage,
            UnitSystem.metric.priceValue(imperial.chartData.priceAverage, from: .imperial), accuracy: 0.0000001)
        let source = try await fixture.source()
        for record in source.records { XCTAssertEqual(record.values, fixture.values[record.id]) }
        let first = try XCTUnwrap(source.records.first)
        let odo = String(format: "%.0f", UnitSystem.metric.distanceValue(first.values.odometer, from: .imperial))
        let page = try await repository.page(
            version: metric.version, query: .init(searchText: odo, sortOrder: .dateAscending), offset: 0)
        XCTAssertTrue(page?.records.contains(where: { $0.id == first.id }) == true)
        for format in MetricEfficiencyFormat.allCases {
            let formatted = try await repository.refresh(revision: 1, format: format)
            XCTAssertEqual(formatted.version, metric.version)
            XCTAssertEqual(formatted.chartData.metricEfficiencyFormat, format)
        }
        let loads = await repository.sourceLoads
        XCTAssertEqual(loads, 2)
    }

    private actor Gate {
        let source: VehicleHistorySource
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<VehicleHistorySource, Never>?
        var calls = 0
        var nextSource: VehicleHistorySource?
        init(source: VehicleHistorySource, entered: XCTestExpectation) {
            self.source = source
            self.entered = entered
        }
        func load() async -> VehicleHistorySource {
            calls += 1
            if calls > 1 { return nextSource ?? source }
            return await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func release() {
            continuation?.resume(returning: source)
            continuation = nil
        }
        func replaceNextSource(_ value: VehicleHistorySource) { nextSource = value }
    }

    func testSaveDuringReadRejectsTheOldGenerationAndRefetchesBeforePublishing() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let entered = expectation(description: "Read suspended before publication")
        let gate = Gate(source: try await fixture.source(), entered: entered)
        let repository = VehicleHistoryRepository { await gate.load() }
        let model = VehicleHistoryModel(
            container: fixture.container, vehicleID: fixture.vehicleID, repository: repository)
        let pending = Task { await model.reload(revision: 0, format: .defaultFormat) }
        await fulfillment(of: [entered], timeout: 5)
        let id = try XCTUnwrap(fixture.values.keys.first)
        try await OwnedModelStore(container: fixture.container).transaction { actor in
            let row = try XCTUnwrap(
                actor.modelContext.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
            row.notes = "Saved during the read"
        }
        await gate.replaceNextSource(try await fixture.source())
        await gate.release()
        await pending.value
        XCTAssertNil(model.presentation)
        let invalidated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.revision > 0 }, object: nil)
        await fulfillment(of: [invalidated], timeout: 5)
        await model.reload(revision: model.revision, format: .defaultFormat)
        let data = try XCTUnwrap(model.presentation)
        let page = await model.page(
            version: data.version,
            query: .init(searchText: "Saved during the read", sortOrder: .dateDescending), offset: 0)
        XCTAssertEqual(page?.records.map(\.id), [id])
        let loads = await repository.sourceLoads
        XCTAssertEqual(loads, 2)
    }

    func testSupersededReadCannotOverwriteNewerPresentation() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let entered = expectation(description: "First read suspended")
        let gate = Gate(source: try await fixture.source(), entered: entered)
        let repository = VehicleHistoryRepository { await gate.load() }
        let model = VehicleHistoryModel(
            container: fixture.container, vehicleID: fixture.vehicleID, repository: repository)
        let older = Task { await model.reload(revision: 0, format: .defaultFormat) }
        await fulfillment(of: [entered], timeout: 5)
        model.retry()
        await model.reload(revision: model.revision, format: .defaultFormat)
        let version = try XCTUnwrap(model.presentation?.version)
        await gate.release()
        await older.value
        XCTAssertEqual(model.presentation?.version, version)
        XCTAssertFalse(model.failed)
        let loads = await repository.sourceLoads
        XCTAssertEqual(loads, 1)
    }

    func testCancelledReadCanRetryWithoutPublishingOrCachingPartialData() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let entered = expectation(description: "Read suspended")
        let gate = Gate(source: try await fixture.source(), entered: entered)
        let repository = VehicleHistoryRepository { await gate.load() }
        let model = VehicleHistoryModel(
            container: fixture.container, vehicleID: fixture.vehicleID, repository: repository)
        let task = Task { await model.reload(revision: 0, format: .defaultFormat) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertNil(model.presentation)
        XCTAssertFalse(model.failed)
        await model.reload(revision: 0, format: .defaultFormat)
        XCTAssertEqual(model.presentation?.recordCount, 3)
        let loads = await repository.sourceLoads
        XCTAssertEqual(loads, 1)
    }

    func testReadFailureIsVisibleAndRetryUsesTheSameSource() async throws {
        let fixture = try VehicleHistoryFixture(count: 3)
        let source = try await fixture.source()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let repository = VehicleHistoryRepository {
            let attempt = attempts.withLock {
                $0 += 1
                return $0
            }
            if attempt == 1 { throw CocoaError(.fileReadNoPermission) }
            return source
        }
        let model = VehicleHistoryModel(
            container: fixture.container, vehicleID: fixture.vehicleID, repository: repository)
        await model.reload(revision: 0, format: .defaultFormat)
        XCTAssertTrue(model.failed)
        XCTAssertNil(model.presentation)
        model.retry()
        await model.reload(revision: model.revision, format: .defaultFormat)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.presentation?.recordCount, 3)
    }
}
