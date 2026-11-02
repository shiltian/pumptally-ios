import XCTest
import SwiftData
@testable import PumpTally

@MainActor
final class StatisticsCacheServiceTests: XCTestCase {
    private func projection(_ vehicle: Vehicle) -> [String: [UInt64?]] {
        var result: [String: [UInt64?]] = [:]
        for record in vehicle.fuelingRecords ?? [] {
            result[record.id.uuidString] = [
                record.cachedPreviousOdometer, record.cachedDistanceDriven,
                record.cachedEfficiency, record.cachedCostPerDistance,
            ].map { $0?.bitPattern }
        }
        result["vehicle"] = [
            vehicle.cachedTotalSpent, vehicle.cachedTotalDistance, vehicle.cachedTotalFuel,
            vehicle.cachedAverageEfficiency, vehicle.cachedAverageCostPerDistance, vehicle.cachedAverageFillUpCost,
            vehicle.cachedAveragePricePerFuelUnit, vehicle.cachedBestEfficiency, vehicle.cachedWorstEfficiency,
            vehicle.cachedHighestPricePerFuelUnit, vehicle.cachedLowestPricePerFuelUnit,
        ].map { $0?.bitPattern }
        result["count"] = [vehicle.cachedRecordCount.map(UInt64.init)]
        return result
    }

    private func assertReference(_ vehicle: Vehicle, file: StaticString = #filePath, line: UInt = #line) {
        let incremental = projection(vehicle)
        StatisticsReference.recalculateAllStatistics(for: vehicle)
        XCTAssertEqual(projection(vehicle), incremental, file: file, line: line)
    }

    func testIncrementalMutationsMatchFrozenFullRebuildBitForBit() {
        let vehicle = createVehicle()
        var state: UInt64 = 47
        func random(_ n: UInt64) -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int((state >> 32) % n)
        }
        var rows: [FuelingRecord] = []
        for index in 0..<80 {
            rows.append(
                createRecord(
                    date: Date(timeIntervalSince1970: Double(index / 2)),
                    odometer: Double(index * 300) + 1000.123456789, pricePerFuelUnit: 3.459876543,
                    fuelAmount: 10.123456789, fillUpType: FillUpType.allCases[index % 3], vehicle: vehicle))
        }
        vehicle.fuelingRecords = rows
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        for iteration in 0..<200 {
            switch random(4) {
            case 0:
                let row = createRecord(
                    date: Date(timeIntervalSince1970: Double(random(50))),
                    odometer: Double(random(120)) * 300 + 1000.123456789,
                    fuelAmount: Double(random(15)) + 0.123456789,
                    fillUpType: FillUpType.allCases[random(3)], vehicle: vehicle)
                rows.append(row)
            case 1 where !rows.isEmpty:
                rows.remove(at: random(UInt64(rows.count)))
            default:
                guard !rows.isEmpty else { continue }
                let row = rows[random(UInt64(rows.count))]
                let previous = FuelingRecordValues(record: row)
                row.date = Date(timeIntervalSince1970: Double(random(50)))
                row.odometer = Double(random(120)) * 300 + 1000.123456789
                row.fuelAmount = Double(random(15)) + 0.123456789
                row.totalCost = Double(random(100)) + 0.987654321
                row.pricePerFuelUnit = Double(random(8)) + 0.459876543
                row.fillUpType = FillUpType.allCases[random(3)]
                StatisticsCacheService.invalidateIfNeeded(row, previous: previous)
            }
            vehicle.fuelingRecords = rows
            let result = StatisticsCacheService.refresh(for: vehicle)
            XCTAssertLessThanOrEqual(result.calculatedRecordIDs.count, 5, "iteration \(iteration)")
            assertReference(vehicle)
        }
    }

    func testRemovingFirstRecordUpdatesTheNewBaselineAndItsSuccessor() {
        let vehicle = createVehicle()
        let rows: [FuelingRecord] = (0..<4).map { index in
            let kind: FillUpType = index == 1 ? .partial : .full
            let odometer = Double(index * 100 + 100)
            return createRecord(
                date: Date(timeIntervalSince1970: Double(index)),
                odometer: odometer, fillUpType: kind, vehicle: vehicle)
        }
        vehicle.fuelingRecords = rows
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        vehicle.fuelingRecords = Array(rows.dropFirst())
        let result = StatisticsCacheService.refresh(for: vehicle)
        XCTAssertEqual(result.calculatedRecordIDs, Set([rows[1].id, rows[2].id]))
        assertReference(vehicle)
    }

    func testLegacyNonmonotonicAndZeroBaselineIntervalsRetainFullRebuildRules() {
        for readings: [Double] in [[0, 100, 50, 300], [100, 100, 50, 300]] {
            let vehicle = createVehicle()
            let rows = readings.enumerated().map {
                createRecord(
                    date: Date(timeIntervalSince1970: Double($0.offset)),
                    odometer: $0.element, vehicle: vehicle)
            }
            vehicle.fuelingRecords = Array(rows.prefix(3))
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            vehicle.fuelingRecords = rows
            let result = StatisticsCacheService.refresh(for: vehicle)
            XCTAssertEqual(result.calculatedRecordIDs, [rows[3].id])
            assertReference(vehicle)
        }
    }

    func testRepairDetectsLegacyClippedDistancesAndMissingIntervals() {
        let vehicle = createVehicle()
        let rows = (0..<3).map {
            createRecord(
                date: Date(timeIntervalSince1970: Double($0)),
                odometer: Double(300 - $0 * 100), vehicle: vehicle)
        }
        vehicle.fuelingRecords = rows
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        rows[1].cachedDistanceDriven = 0
        rows[2].cachedPreviousOdometer = nil
        let result = StatisticsCacheService.refresh(for: vehicle)
        XCTAssertEqual(result.calculatedRecordIDs, [rows[1].id, rows[2].id])
        assertReference(vehicle)
    }

    func testPriceOnlyInvalidationHasNoIntervalWorkAndPreservesAllCachesOnNoOp() {
        let vehicle = createVehicle()
        let rows = (0..<3).map {
            createRecord(
                date: Date(timeIntervalSince1970: Double($0)),
                odometer: Double($0 * 100 + 100), vehicle: vehicle)
        }
        vehicle.fuelingRecords = rows
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        let before = FuelingRecordValues(record: rows[1])
        rows[1].pricePerFuelUnit = 0
        XCTAssertTrue(StatisticsCacheService.invalidateIfNeeded(rows[1], previous: before))
        let updated = StatisticsCacheService.refresh(for: vehicle)
        XCTAssertTrue(updated.calculatedRecordIDs.isEmpty)
        assertReference(vehicle)
        let date = vehicle.cacheLastUpdated
        let noop = StatisticsCacheService.refresh(for: vehicle)
        XCTAssertTrue(noop.calculatedRecordIDs.isEmpty)
        XCTAssertTrue(noop.updatedRecordIDs.isEmpty)
        XCTAssertFalse(noop.updatedVehicle)
        XCTAssertEqual(vehicle.cacheLastUpdated, date)
    }

    func testHealthyFullRebuildDoesNotDirtyNativeModels() throws {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicle = createVehicle()
        context.insert(vehicle)
        for index in 0..<4 {
            context.insert(
                createRecord(
                    date: Date(timeIntervalSince1970: Double(index)),
                    odometer: Double(index * 100 + 100), vehicle: vehicle))
        }
        context.processPendingChanges()
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        try context.save()
        let result = StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        XCTAssertEqual(result.calculatedRecordIDs.count, 4)
        XCTAssertTrue(result.updatedRecordIDs.isEmpty)
        XCTAssertFalse(result.updatedVehicle)
        XCTAssertFalse(context.hasChanges)
    }

    // MARK: - Helper Methods

    private func createVehicle(name: String = "Test Car") -> Vehicle {
        return Vehicle(name: name)
    }

    private func createRecord(
        date: Date = Date(),
        odometer: Double,
        pricePerFuelUnit: Double = 3.50,
        fuelAmount: Double = 10.0,
        totalCost: Double? = nil,
        fillUpType: FillUpType = .full,
        vehicle: Vehicle? = nil
    ) -> FuelingRecord {
        let cost = totalCost ?? (pricePerFuelUnit * fuelAmount)
        let v = vehicle ?? Vehicle(name: "Helper Vehicle")
        return FuelingRecord(
            date: date,
            odometer: odometer,
            pricePerFuelUnit: pricePerFuelUnit,
            fuelAmount: fuelAmount,
            totalCost: cost,
            fillUpType: fillUpType,
            vehicle: v
        )
    }

    // MARK: - Recalculate All Statistics Tests

    func testRecalculateAllStatisticsWithNoRecords() {
        let vehicle = createVehicle()
        vehicle.fuelingRecords = []

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 0)
        XCTAssertNotNil(vehicle.cacheLastUpdated)
    }

    func testRecalculateAllStatisticsWithSingleRecord() {
        let vehicle = createVehicle()

        let record = createRecord(odometer: 10000, pricePerFuelUnit: 3.50, fuelAmount: 10.0, vehicle: vehicle)
        vehicle.fuelingRecords = [record]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 1)
        XCTAssertEqual(vehicle.cachedTotalSpent, 35.0)
        XCTAssertEqual(vehicle.cachedTotalFuel, 10.0)
        XCTAssertEqual(vehicle.cachedTotalDistance, 0) // No previous record to calculate distance
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit, 3.50)
        XCTAssertNotNil(vehicle.cacheLastUpdated)
    }

    func testRecalculateAllStatisticsWithMultipleRecords() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, pricePerFuelUnit: 3.00, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, pricePerFuelUnit: 3.50, fuelAmount: 10.0, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, pricePerFuelUnit: 4.00, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 3)
        XCTAssertEqual(vehicle.cachedTotalSpent, 105.0) // 30 + 35 + 40
        XCTAssertEqual(vehicle.cachedTotalFuel, 30.0)
        XCTAssertEqual(vehicle.cachedTotalDistance, 600.0) // 300 + 300
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit!, 3.50, accuracy: 0.001) // (3 + 3.5 + 4) / 3
        XCTAssertEqual(vehicle.cachedAverageFillUpCost, 35.0) // 105 / 3
    }

    func testRecalculateOrdersSameTimestampRecordsByOdometer() {
        let vehicle = createVehicle()
        let sameDate = Date(timeIntervalSince1970: 1_000_000)
        let higher = createRecord(date: sameDate, odometer: 300, vehicle: vehicle)
        let lower = createRecord(date: sameDate, odometer: 100, vehicle: vehicle)
        let middle = createRecord(date: sameDate, odometer: 200, vehicle: vehicle)
        vehicle.fuelingRecords = [higher, lower, middle]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(lower.cachedPreviousOdometer, 0)
        XCTAssertEqual(lower.cachedDistanceDriven, 0)
        XCTAssertEqual(middle.cachedPreviousOdometer, 100)
        XCTAssertEqual(middle.cachedDistanceDriven, 100)
        XCTAssertEqual(higher.cachedPreviousOdometer, 200)
        XCTAssertEqual(higher.cachedDistanceDriven, 100)
        XCTAssertEqual(vehicle.cachedTotalDistance, 200)
    }

    func testRecalculateAllStatisticsEfficiencyCalculation() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 10.0, vehicle: vehicle) // 300 / 10 = 30

        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedAverageEfficiency, 30.0)
        XCTAssertEqual(record2.cachedEfficiency, 30.0)
        XCTAssertEqual(record2.cachedDistanceDriven, 300.0)
        XCTAssertEqual(record2.cachedPreviousOdometer, 10000.0)
    }

    func testRecalculateAllStatisticsBestAndWorstEfficiency() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10400, fuelAmount: 10.0, vehicle: vehicle) // 40
        let record3 = createRecord(date: date3, odometer: 10600, fuelAmount: 10.0, vehicle: vehicle) // 20

        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedBestEfficiency, 40.0)
        XCTAssertEqual(vehicle.cachedWorstEfficiency, 20.0)
    }

    func testRecalculateAllStatisticsPriceExtremes() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, pricePerFuelUnit: 3.00, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, pricePerFuelUnit: 4.50, fuelAmount: 10.0, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, pricePerFuelUnit: 2.80, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedHighestPricePerFuelUnit, 4.50)
        XCTAssertEqual(vehicle.cachedLowestPricePerFuelUnit, 2.80)
    }

    func testRecalculateAllStatisticsWithPartialFillUp() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 5.0, fillUpType: .partial, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertNil(record2.cachedEfficiency)
        XCTAssertNil(record3.cachedEfficiency)
    }

    func testEfficiencyResumesAfterFullFillUpReestablishesBaseline() {
        let vehicle = createVehicle()
        let records = [
            createRecord(date: Date(timeIntervalSince1970: 1), odometer: 100, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 2), odometer: 200, fillUpType: .partial, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 3), odometer: 300, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 4), odometer: 500, fuelAmount: 10, vehicle: vehicle)
        ]
        vehicle.fuelingRecords = records

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertNil(records[1].cachedEfficiency)
        XCTAssertNil(records[2].cachedEfficiency)
        XCTAssertEqual(records[3].cachedEfficiency, 20)
    }

    func testRecalculateAllStatisticsWithResetFillUp() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 10.0, fillUpType: .reset, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertNil(record2.cachedEfficiency)
    }

    func testResetBreaksEfficiencyUntilFullFillUpReestablishesBaseline() {
        let vehicle = createVehicle()
        let records = [
            createRecord(date: Date(timeIntervalSince1970: 1), odometer: 100, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 2), odometer: 200, fillUpType: .reset, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 3), odometer: 300, vehicle: vehicle),
            createRecord(date: Date(timeIntervalSince1970: 4), odometer: 500, fuelAmount: 10, vehicle: vehicle)
        ]
        vehicle.fuelingRecords = records

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertNil(records[1].cachedEfficiency)
        XCTAssertNil(records[2].cachedEfficiency)
        XCTAssertEqual(records[3].cachedEfficiency, 20)
    }

    func testRecalculateAllStatisticsCostPerDistance() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, pricePerFuelUnit: 3.50, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10350, pricePerFuelUnit: 3.50, fuelAmount: 10.0, totalCost: 35.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(record2.cachedCostPerDistance!, 0.10, accuracy: 0.001)
        XCTAssertEqual(vehicle.cachedAverageCostPerDistance!, 0.20, accuracy: 0.001) // $70 / 350
    }

    // MARK: - Incremental Update Tests

    func testUpdateForNewRecordFirstRecord() {
        let vehicle = createVehicle()
        vehicle.fuelingRecords = []

        let record = createRecord(odometer: 10000, vehicle: vehicle)
        vehicle.fuelingRecords = [record]

        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 1)
        XCTAssertNotNil(vehicle.cacheLastUpdated)
    }

    func testUpdateForNewRecordLatestRecord() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, vehicle: vehicle)
        vehicle.fuelingRecords = [record1]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        let record2 = createRecord(date: date2, odometer: 10300, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 2)
        XCTAssertEqual(record2.cachedDistanceDriven, 300.0)
        XCTAssertEqual(record2.cachedPreviousOdometer, 10000.0)
    }

    func testIncrementalAddUsesOdometerOrderForSameTimestamp() {
        let vehicle = createVehicle()
        let firstDate = Date(timeIntervalSince1970: 1_000_000)
        let sharedDate = Date(timeIntervalSince1970: 2_000_000)
        let first = createRecord(date: firstDate, odometer: 100, vehicle: vehicle)
        let lower = createRecord(date: sharedDate, odometer: 200, vehicle: vehicle)
        vehicle.fuelingRecords = [first, lower]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        let higher = createRecord(date: sharedDate, odometer: 300, vehicle: vehicle)
        vehicle.fuelingRecords = [higher, first, lower]
        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(higher.cachedPreviousOdometer, 200)
        XCTAssertEqual(higher.cachedDistanceDriven, 100)
        XCTAssertEqual(vehicle.cachedTotalDistance, 200)
    }

    func testUpdateForNewRecordLatestRecordUpdatesAverageEfficiency() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 10.0, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedAverageEfficiency, 30.0) // 300 / 10

        let record3 = createRecord(date: date3, odometer: 10500, fuelAmount: 10.0, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.refresh(for: vehicle)

        // After incremental add: fullFillUpDistance = 300 + 200 = 500,
        // fullFillUpFuel = 10 (record2) + 10 (record3) = 20
        // (baseline record1's fuel is excluded — it has no valid efficiency)
        XCTAssertNotNil(vehicle.cachedAverageEfficiency)
        XCTAssertEqual(vehicle.cachedAverageEfficiency!, 500.0 / 20.0, accuracy: 0.001)
    }

    func testUpdateForNewRecordAfterPartialExcludesInvalidEfficiency() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        // record1: full (baseline), record2: partial (breaks efficiency chain)
        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 5.0, fillUpType: .partial, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        // Partial after full → no valid efficiency intervals yet
        XCTAssertNil(record2.cachedEfficiency)

        // record3: full latest, but previous was partial → no efficiency for record3
        let record3 = createRecord(date: date3, odometer: 10600, fuelAmount: 10.0, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.refresh(for: vehicle)

        // record3 should have no efficiency (previous was partial)
        XCTAssertNil(record3.cachedEfficiency)

        // No valid full-to-full intervals exist, so cachedAverageEfficiency
        // should use the fallback (totalDistance / totalFuel), matching full recalc
        let expectedTotalDistance = 300.0 + 300.0  // 600
        let expectedTotalFuel = 10.0 + 5.0 + 10.0 // 25
        XCTAssertEqual(vehicle.cachedAverageEfficiency!, expectedTotalDistance / expectedTotalFuel, accuracy: 0.001)

        // Verify incremental result matches a full recalculation
        let incrementalAvg = vehicle.cachedAverageEfficiency!
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        XCTAssertEqual(vehicle.cachedAverageEfficiency!, incrementalAvg, accuracy: 0.001)
    }

    func testIncrementalUpdateMatchesFirstRecordBaselineCompatibilityRule() {
        for firstType in [FillUpType.partial, .reset] {
            let vehicle = createVehicle()
            let first = createRecord(
                date: Date(timeIntervalSince1970: 1),
                odometer: 100,
                fillUpType: firstType,
                vehicle: vehicle
            )
            vehicle.fuelingRecords = [first]
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)

            let second = createRecord(
                date: Date(timeIntervalSince1970: 2),
                odometer: 300,
                fuelAmount: 10,
                vehicle: vehicle
            )
            vehicle.fuelingRecords = [second, first]
            StatisticsCacheService.refresh(for: vehicle)

            XCTAssertEqual(second.cachedEfficiency, 20)
            let incrementalAverage = vehicle.cachedAverageEfficiency

            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            XCTAssertEqual(second.cachedEfficiency, 20)
            XCTAssertEqual(vehicle.cachedAverageEfficiency, incrementalAverage)
        }
    }

    func testUpdateForNewRecordNotLatest() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record3]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        let record2 = createRecord(date: date2, odometer: 10300, vehicle: vehicle)
        vehicle.fuelingRecords = [record1, record2, record3]

        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 3)
    }

    // MARK: - Delete and Edit Tests

    func testUpdateForDeletedRecord() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, pricePerFuelUnit: 3.00, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, pricePerFuelUnit: 4.00, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        vehicle.fuelingRecords = [record1]
        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 1)
        XCTAssertEqual(vehicle.cachedTotalSpent, 30.0)
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit, 3.00)
    }

    func testUpdateForEditedRecord() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, pricePerFuelUnit: 3.00, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, pricePerFuelUnit: 4.00, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2]
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        let previous = FuelingRecordValues(record: record2)
        record2.pricePerFuelUnit = 5.00
        record2.fuelAmount = 12.0

        StatisticsCacheService.invalidateIfNeeded(record2, previous: previous)
        StatisticsCacheService.refresh(for: vehicle)

        XCTAssertEqual(vehicle.cachedRecordCount, 2)
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit!, 4.00, accuracy: 0.001) // (3 + 5) / 2
    }

    // MARK: - Edge Cases

    func testRecalculateWithZeroFuelAmount() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertNil(record2.cachedEfficiency)
    }

    func testRecalculateWithSameOdometer() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(record2.cachedDistanceDriven, 0)
        XCTAssertNil(record2.cachedEfficiency)
    }

    func testRecalculateWithRecordsInReverseOrder() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)
        let date3 = Date(timeIntervalSince1970: 3000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10300, fuelAmount: 10.0, vehicle: vehicle)
        let record3 = createRecord(date: date3, odometer: 10600, fuelAmount: 10.0, vehicle: vehicle)

        vehicle.fuelingRecords = [record3, record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(vehicle.cachedTotalDistance, 600.0)
        XCTAssertEqual(vehicle.cachedRecordCount, 3)
    }

    func testEfficiencyCalculationAccuracy() {
        let vehicle = createVehicle()

        let date1 = Date(timeIntervalSince1970: 1000000)
        let date2 = Date(timeIntervalSince1970: 2000000)

        let record1 = createRecord(date: date1, odometer: 10000, fuelAmount: 10.0, vehicle: vehicle)
        let record2 = createRecord(date: date2, odometer: 10333, fuelAmount: 11.1, vehicle: vehicle) // 333 / 11.1 = 30.0

        vehicle.fuelingRecords = [record1, record2]

        StatisticsCacheService.recalculateAllStatistics(for: vehicle)

        XCTAssertEqual(record2.cachedEfficiency!, 30.0, accuracy: 0.01)
    }
}

private enum StatisticsReference {
    static func recalculateAllStatistics(for vehicle: Vehicle) {
        let records = vehicle.fuelingRecords ?? []

        guard !records.isEmpty else {
            vehicle.invalidateCache()
            vehicle.cachedRecordCount = 0
            vehicle.cacheLastUpdated = Date()
            return
        }

        // Sort once - O(n log n)
        let sortedByDate = records.sorted(
            by: OdometerChronologyValidator.areInIncreasingOrder
        )

        // Single pass to compute all per-record cached values and aggregate statistics - O(n)
        var totalSpent: Double = 0
        var totalDistance: Double = 0
        var totalFuel: Double = 0
        var totalPricePerFuelUnit: Double = 0

        var fullFillUpDistance: Double = 0
        var fullFillUpFuel: Double = 0

        var bestEfficiency: Double = 0
        var worstEfficiency: Double = Double.greatestFiniteMagnitude
        var highestPrice: Double = 0
        var lowestPrice: Double = Double.greatestFiniteMagnitude

        var hasValidEfficiency = false
        var previousOdometer: Double = 0
        for (index, record) in sortedByDate.enumerated() {
            // Cache previous odometer for this record
            record.cachedPreviousOdometer = previousOdometer

            // Calculate distance driven
            let distanceDriven: Double
            if previousOdometer > 0 {
                distanceDriven = record.odometer - previousOdometer
                record.cachedDistanceDriven = distanceDriven
            } else {
                distanceDriven = 0
                record.cachedDistanceDriven = 0
            }

            let previousRecord = index > 0 ? sortedByDate[index - 1] : nil
            if let efficiency = FuelEfficiencyPolicy.rawEfficiency(
                distanceDriven: distanceDriven,
                fuelAmount: record.fuelAmount,
                currentFillUpType: record.fillUpType,
                previousFillUpType: previousRecord?.fillUpType,
                previousIsFirstRecord: index == 1
            ) {
                record.cachedEfficiency = efficiency

                // Track best/worst efficiency
                hasValidEfficiency = true
                if efficiency > bestEfficiency { bestEfficiency = efficiency }
                if efficiency < worstEfficiency { worstEfficiency = efficiency }

                // Accumulate for average efficiency calculation
                fullFillUpDistance += distanceDriven
                fullFillUpFuel += record.fuelAmount
            } else {
                record.cachedEfficiency = nil
            }

            // Calculate cost per distance
            if distanceDriven > 0 {
                record.cachedCostPerDistance = record.totalCost / distanceDriven
            } else {
                record.cachedCostPerDistance = nil
            }

            // Accumulate totals
            totalSpent += record.totalCost
            totalDistance += distanceDriven
            totalFuel += record.fuelAmount
            totalPricePerFuelUnit += record.pricePerFuelUnit

            // Track price extremes
            if record.pricePerFuelUnit > highestPrice { highestPrice = record.pricePerFuelUnit }
            if record.pricePerFuelUnit < lowestPrice { lowestPrice = record.pricePerFuelUnit }

            // Update state for next iteration
            previousOdometer = record.odometer
        }

        // Store aggregated statistics on the vehicle
        vehicle.cachedTotalSpent = totalSpent
        vehicle.cachedTotalDistance = totalDistance
        vehicle.cachedTotalFuel = totalFuel
        vehicle.cachedRecordCount = records.count

        // Average efficiency from full fill-ups only (more accurate)
        if fullFillUpFuel > 0 {
            vehicle.cachedAverageEfficiency = fullFillUpDistance / fullFillUpFuel
        } else if totalFuel > 0 {
            // Fallback to all records if no full fill-ups
            vehicle.cachedAverageEfficiency = totalDistance / totalFuel
        } else {
            vehicle.cachedAverageEfficiency = 0
        }

        // Average cost per distance
        if totalDistance > 0 {
            vehicle.cachedAverageCostPerDistance = totalSpent / totalDistance
        } else {
            vehicle.cachedAverageCostPerDistance = 0
        }

        // Average fill-up cost
        vehicle.cachedAverageFillUpCost = totalSpent / Double(records.count)

        // Average price per fuel unit
        vehicle.cachedAveragePricePerFuelUnit = totalPricePerFuelUnit / Double(records.count)

        // Best/worst efficiency
        vehicle.cachedBestEfficiency = hasValidEfficiency ? bestEfficiency : nil
        vehicle.cachedWorstEfficiency =
            hasValidEfficiency && worstEfficiency != Double.greatestFiniteMagnitude ? worstEfficiency : nil

        // Price extremes
        vehicle.cachedHighestPricePerFuelUnit = highestPrice > 0 ? highestPrice : nil
        vehicle.cachedLowestPricePerFuelUnit = lowestPrice != Double.greatestFiniteMagnitude ? lowestPrice : nil

        vehicle.cacheLastUpdated = Date()
    }

}

/// Isolated cache-maintenance transactions, including native disk commits.
/// The reference is the frozen pre-refactor full rebuild, not the new builder.
@MainActor
final class StatisticsMutationPerformanceTests: XCTestCase {
    private func fixture(_ count: Int) throws -> (ModelContainer, UUID, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: SchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema, url: directory.appendingPathComponent("statistics.store"), cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Synthetic statistics")
        context.insert(vehicle)
        var target = UUID()
        for index in 0..<count {
            let record = FuelingRecord(
                date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                odometer: 1000.123456789 + Double(index) * 300, pricePerFuelUnit: 3.459876543,
                fuelAmount: 10.123456789, totalCost: 35.123456789,
                fillUpType: index % 4 == 0 ? .partial : .full, vehicle: vehicle)
            context.insert(record)
            if index == count / 2 + 2 { target = record.id }
        }
        context.processPendingChanges()
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        try context.save()
        return (container, vehicle.id, target)
    }

    private func measureEdit(_ count: Int, legacy: Bool) throws {
        let (container, vehicleID, recordID) = try fixture(count)
        let writer = OwnedModelStore(container: container)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let saved = expectation(description: "Cache transaction committed")
            Task {
                do {
                    try await writer.transaction { actor in
                        let context = actor.modelContext
                        let vehicle = try XCTUnwrap(
                            context.fetch(FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == vehicleID })).first)
                        let record = try XCTUnwrap(
                            context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == recordID }))
                                .first)
                        let previous = FuelingRecordValues(record: record)
                        record.fuelAmount += 0.125
                        if legacy {
                            StatisticsReference.recalculateAllStatistics(for: vehicle)
                        } else {
                            StatisticsCacheService.invalidateIfNeeded(record, previous: previous)
                            let result = StatisticsCacheService.refresh(for: vehicle)
                            XCTAssertEqual(result.calculatedRecordIDs, [recordID])
                            context.processPendingChanges()
                            XCTAssertLessThanOrEqual(context.changedModelsArray.count, 2)
                        }
                    }
                } catch { XCTFail("\(error)") }
                saved.fulfill()
            }
            wait(for: [saved], timeout: 60)
        }
    }

    func testEdit800() throws { try measureEdit(800, legacy: false) }
    func testEdit3200() throws { try measureEdit(3200, legacy: false) }
    func testEdit12800() throws { try measureEdit(12800, legacy: false) }
    func testReference800() throws { try measureEdit(800, legacy: true) }
    func testReference3200() throws { try measureEdit(3200, legacy: true) }
    func testReference12800() throws { try measureEdit(12800, legacy: true) }

    func testReadCachedEfficiencies12800() throws {
        let (container, _, _) = try fixture(12800)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        withExtendedLifetime(context) {
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                XCTAssertTrue(records.reduce(0) { $0 + $1.getEfficiency() }.isFinite)
            }
        }
    }
}
