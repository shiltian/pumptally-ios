import XCTest
import SwiftData
@testable import PumpTally

@MainActor
final class FuelingRecordPersistenceServiceTests: XCTestCase {

    private enum TestError: Error {
        case commitFailed
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeSavedVehicle(in context: ModelContext) throws -> Vehicle {
        let vehicle = Vehicle(name: "Test Car")
        context.insert(vehicle)
        try context.save()
        return vehicle
    }

    private func insertRecord(
        odometer: Double = 100,
        into vehicle: Vehicle,
        context: ModelContext
    ) throws -> FuelingRecord {
        try FuelingRecordPersistenceService.insert(into: vehicle, context: context) {
            FuelingRecord(
                odometer: odometer,
                pricePerFuelUnit: 3,
                fuelAmount: 10,
                totalCost: 30,
                vehicle: vehicle
            )
        }
    }

    func testInsertProcessesInverseRelationshipAndCommitsCachesOnce() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        var commitCount = 0

        let record = try FuelingRecordPersistenceService.insert(
            into: vehicle,
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        ) {
            FuelingRecord(
                odometer: 100,
                pricePerFuelUnit: 3,
                fuelAmount: 10,
                totalCost: 30,
                vehicle: vehicle
            )
        }

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [record.id])
        XCTAssertEqual(vehicle.cachedRecordCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testDeleteProcessesInverseRelationshipBeforeCacheRecalculation() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        let record = try insertRecord(into: vehicle, context: context)

        try FuelingRecordPersistenceService.delete(record, from: vehicle, context: context)

        XCTAssertTrue((vehicle.fuelingRecords ?? []).isEmpty)
        XCTAssertEqual(vehicle.cachedRecordCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testEditCommitsRecordAndCacheChangesTogether() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        let first = try insertRecord(odometer: 100, into: vehicle, context: context)
        let second = try insertRecord(odometer: 200, into: vehicle, context: context)

        try FuelingRecordPersistenceService.saveEdits(
            to: second,
            in: vehicle,
            context: context
        ) {
            second.odometer = 250
            second.totalCost = 45
        }

        XCTAssertEqual(first.cachedDistanceDriven, 0)
        XCTAssertEqual(second.odometer, 250)
        XCTAssertEqual(second.cachedDistanceDriven, 150)
        XCTAssertEqual(vehicle.cachedTotalSpent, 75)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedInsertRollsBackRecordAndCaches() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)

        XCTAssertThrowsError(
            try FuelingRecordPersistenceService.insert(
                into: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            ) {
                FuelingRecord(
                    odometer: 100,
                    pricePerFuelUnit: 3,
                    fuelAmount: 10,
                    totalCost: 30,
                    vehicle: vehicle
                )
            }
        )

        XCTAssertTrue((vehicle.fuelingRecords ?? []).isEmpty)
        XCTAssertNil(vehicle.cachedRecordCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testBatchInsertCommitsEveryRecordAndCachesOnce() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        var commitCount = 0

        let records = try FuelingRecordPersistenceService.insertBatch(
            into: vehicle,
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        ) {
            [100.0, 200.0, 300.0].map { odometer in
                FuelingRecord(
                    odometer: odometer,
                    pricePerFuelUnit: 3,
                    fuelAmount: 10,
                    totalCost: 30,
                    vehicle: vehicle
                )
            }
        }

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(vehicle.fuelingRecords?.count, 3)
        XCTAssertEqual(vehicle.cachedRecordCount, 3)
        XCTAssertEqual(vehicle.cachedTotalDistance, 200)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 3)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedBatchInsertRollsBackEveryRecordAndCache() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        _ = try insertRecord(odometer: 50, into: vehicle, context: context)
        let originalRecordCount = vehicle.cachedRecordCount
        let originalDistance = vehicle.cachedTotalDistance

        XCTAssertThrowsError(
            try FuelingRecordPersistenceService.insertBatch(
                into: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            ) {
                [100.0, 200.0, 300.0].map { odometer in
                    FuelingRecord(
                        odometer: odometer,
                        pricePerFuelUnit: 3,
                        fuelAmount: 10,
                        totalCost: 30,
                        vehicle: vehicle
                    )
                }
            }
        )

        XCTAssertEqual(vehicle.fuelingRecords?.map(\.odometer), [50])
        XCTAssertEqual(vehicle.cachedRecordCount, originalRecordCount)
        XCTAssertEqual(vehicle.cachedTotalDistance, originalDistance)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedEditRollsBackRecordAndCaches() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        let first = try insertRecord(odometer: 100, into: vehicle, context: context)
        let second = try insertRecord(odometer: 200, into: vehicle, context: context)
        let originalTotalDistance = vehicle.cachedTotalDistance

        XCTAssertThrowsError(
            try FuelingRecordPersistenceService.saveEdits(
                to: second,
                in: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            ) {
                second.odometer = 300
                second.totalCost = 99
            }
        )

        XCTAssertEqual(first.cachedDistanceDriven, 0)
        XCTAssertEqual(second.odometer, 200)
        XCTAssertEqual(second.totalCost, 30)
        XCTAssertEqual(vehicle.cachedTotalDistance, originalTotalDistance)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedDeleteRestoresRecordAndCaches() throws {
        let context = try makeContext()
        let vehicle = try makeSavedVehicle(in: context)
        let record = try insertRecord(into: vehicle, context: context)

        XCTAssertThrowsError(
            try FuelingRecordPersistenceService.delete(
                record,
                from: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [record.id])
        XCTAssertEqual(vehicle.cachedRecordCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertFalse(context.hasChanges)
    }
}

@MainActor
final class VehiclePersistenceServiceTests: XCTestCase {

    private enum TestError: Error {
        case commitFailed
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeSavedGraph(
        in context: ModelContext
    ) throws -> (Vehicle, FuelingRecord) {
        let vehicle = Vehicle(
            name: "Original",
            make: "Old Make",
            model: "Old Model",
            year: 2020,
            unitSystem: .imperial
        )
        vehicle.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(vehicle)

        let record = FuelingRecord(
            date: Date(timeIntervalSince1970: 200),
            odometer: 1_000,
            pricePerFuelUnit: 3.5,
            fuelAmount: 10,
            totalCost: 35,
            fillUpType: .full,
            notes: "Original note",
            vehicle: vehicle
        )
        record.modifiedAt = Date(timeIntervalSince1970: 300)
        context.insert(record)
        context.processPendingChanges()

        setSentinelCaches(on: vehicle, record: record)
        try context.save()
        return (vehicle, record)
    }

    private func setSentinelCaches(on vehicle: Vehicle, record: FuelingRecord) {
        vehicle.cachedTotalSpent = 1
        vehicle.cachedTotalDistance = 2
        vehicle.cachedTotalFuel = 3
        vehicle.cachedAverageEfficiency = 4
        vehicle.cachedAverageCostPerDistance = 5
        vehicle.cachedAverageFillUpCost = 6
        vehicle.cachedAveragePricePerFuelUnit = 7
        vehicle.cachedBestEfficiency = 8
        vehicle.cachedWorstEfficiency = 9
        vehicle.cachedHighestPricePerFuelUnit = 10
        vehicle.cachedLowestPricePerFuelUnit = 11
        vehicle.cachedRecordCount = 12
        vehicle.cacheLastUpdated = Date(timeIntervalSince1970: 400)

        record.cachedPreviousOdometer = 13
        record.cachedDistanceDriven = 14
        record.cachedEfficiency = 15
        record.cachedCostPerDistance = 16
    }

    private func assertSentinelCaches(
        on vehicle: Vehicle,
        record: FuelingRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(vehicle.cachedTotalSpent, 1, file: file, line: line)
        XCTAssertEqual(vehicle.cachedTotalDistance, 2, file: file, line: line)
        XCTAssertEqual(vehicle.cachedTotalFuel, 3, file: file, line: line)
        XCTAssertEqual(vehicle.cachedAverageEfficiency, 4, file: file, line: line)
        XCTAssertEqual(vehicle.cachedAverageCostPerDistance, 5, file: file, line: line)
        XCTAssertEqual(vehicle.cachedAverageFillUpCost, 6, file: file, line: line)
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit, 7, file: file, line: line)
        XCTAssertEqual(vehicle.cachedBestEfficiency, 8, file: file, line: line)
        XCTAssertEqual(vehicle.cachedWorstEfficiency, 9, file: file, line: line)
        XCTAssertEqual(vehicle.cachedHighestPricePerFuelUnit, 10, file: file, line: line)
        XCTAssertEqual(vehicle.cachedLowestPricePerFuelUnit, 11, file: file, line: line)
        XCTAssertEqual(vehicle.cachedRecordCount, 12, file: file, line: line)
        XCTAssertEqual(
            vehicle.cacheLastUpdated,
            Date(timeIntervalSince1970: 400),
            file: file,
            line: line
        )

        XCTAssertEqual(record.cachedPreviousOdometer, 13, file: file, line: line)
        XCTAssertEqual(record.cachedDistanceDriven, 14, file: file, line: line)
        XCTAssertEqual(record.cachedEfficiency, 15, file: file, line: line)
        XCTAssertEqual(record.cachedCostPerDistance, 16, file: file, line: line)
    }

    func testInsertUsesOneExplicitCommit() throws {
        let context = try makeContext()
        var commitCount = 0

        let vehicle = try VehiclePersistenceService.insert(
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        ) {
            Vehicle(name: "Inserted")
        }

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(vehicle.name, "Inserted")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedInsertLeavesNoVehicle() throws {
        let context = try makeContext()

        XCTAssertThrowsError(
            try VehiclePersistenceService.insert(
                context: context,
                commit: { _ in throw TestError.commitFailed }
            ) {
                Vehicle(name: "Not Saved")
            }
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testSaveSettingsConvertsSourceValuesAndCommitsOnce() throws {
        let context = try makeContext()
        let (vehicle, record) = try makeSavedGraph(in: context)
        var commitCount = 0

        try VehiclePersistenceService.saveSettings(
            for: vehicle,
            name: "Updated",
            make: nil,
            model: "New Model",
            year: 2025,
            unitSystem: .metric,
            modifiedAt: Date(timeIntervalSince1970: 500),
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(vehicle.name, "Updated")
        XCTAssertNil(vehicle.make)
        XCTAssertEqual(vehicle.model, "New Model")
        XCTAssertEqual(vehicle.year, 2025)
        XCTAssertEqual(vehicle.unitSystem, .metric)
        XCTAssertEqual(record.odometer, 1_000 * UnitSystem.milesToKm, accuracy: 0.000_001)
        XCTAssertEqual(record.fuelAmount, 10 * UnitSystem.gallonsToLiters, accuracy: 0.000_001)
        XCTAssertEqual(record.pricePerFuelUnit, 3.5 / UnitSystem.gallonsToLiters, accuracy: 0.000_001)
        XCTAssertEqual(record.totalCost, 35)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedSaveSettingsRestoresMetadataRecordsAndEveryCache() throws {
        let context = try makeContext()
        let (vehicle, record) = try makeSavedGraph(in: context)

        XCTAssertThrowsError(
            try VehiclePersistenceService.saveSettings(
                for: vehicle,
                name: "Updated",
                make: nil,
                model: "New Model",
                year: 2025,
                unitSystem: .metric,
                modifiedAt: Date(timeIntervalSince1970: 500),
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertEqual(vehicle.name, "Original")
        XCTAssertEqual(vehicle.make, "Old Make")
        XCTAssertEqual(vehicle.model, "Old Model")
        XCTAssertEqual(vehicle.year, 2020)
        XCTAssertEqual(vehicle.unitSystem, .imperial)
        XCTAssertEqual(vehicle.modifiedAt, Date(timeIntervalSince1970: 100))

        XCTAssertEqual(record.date, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(record.odometer, 1_000)
        XCTAssertEqual(record.pricePerFuelUnit, 3.5)
        XCTAssertEqual(record.fuelAmount, 10)
        XCTAssertEqual(record.totalCost, 35)
        XCTAssertEqual(record.fillUpType, .full)
        XCTAssertEqual(record.notes, "Original note")
        XCTAssertEqual(record.modifiedAt, Date(timeIntervalSince1970: 300))
        assertSentinelCaches(on: vehicle, record: record)
        XCTAssertFalse(context.hasChanges)
    }

    func testClearHistoryCommitsRecordsAndEmptyCachesTogether() throws {
        let context = try makeContext()
        let (vehicle, _) = try makeSavedGraph(in: context)
        var commitCount = 0

        try VehiclePersistenceService.clearFuelingHistory(
            for: vehicle,
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue((vehicle.fuelingRecords ?? []).isEmpty)
        XCTAssertEqual(vehicle.cachedRecordCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedClearHistoryRestoresRelationshipAndEveryCache() throws {
        let context = try makeContext()
        let (vehicle, record) = try makeSavedGraph(in: context)

        XCTAssertThrowsError(
            try VehiclePersistenceService.clearFuelingHistory(
                for: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [record.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        assertSentinelCaches(on: vehicle, record: record)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedVehicleDeleteRestoresGraph() throws {
        let context = try makeContext()
        let (vehicle, record) = try makeSavedGraph(in: context)

        XCTAssertThrowsError(
            try VehiclePersistenceService.delete(
                vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [record.id])
        assertSentinelCaches(on: vehicle, record: record)
        XCTAssertFalse(context.hasChanges)
    }

    func testVehicleDeleteCommitsEntireGraph() throws {
        let context = try makeContext()
        let (vehicle, _) = try makeSavedGraph(in: context)
        var commitCount = 0

        try VehiclePersistenceService.delete(
            vehicle,
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedDeleteAllRestoresEveryGraph() throws {
        let context = try makeContext()
        let (vehicle, record) = try makeSavedGraph(in: context)

        XCTAssertThrowsError(
            try VehiclePersistenceService.deleteAllData(
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [record.id])
        assertSentinelCaches(on: vehicle, record: record)
        XCTAssertFalse(context.hasChanges)
    }

    func testDeleteAllCommitsEveryGraphOnce() throws {
        let context = try makeContext()
        _ = try makeSavedGraph(in: context)
        let secondVehicle = Vehicle(name: "Second")
        context.insert(secondVehicle)
        try context.save()
        var commitCount = 0

        try VehiclePersistenceService.deleteAllData(
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }
}
