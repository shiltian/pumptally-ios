import XCTest
import SwiftData
@testable import PumpTally

@MainActor
final class VehicleTests: XCTestCase {
    private var fixtureContainer: ModelContainer!

    override func setUp() async throws {
        try await MainActor.run {
            let schema = Schema(versionedSchema: SchemaV6.self)
            fixtureContainer = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                ])
            fixtureContainer.mainContext.autosaveEnabled = false
        }
    }

    private func managed(_ vehicle: Vehicle) -> Vehicle {
        fixtureContainer.mainContext.insert(vehicle)
        return vehicle
    }

    // MARK: - Initialization Tests

    func testInitializationWithDefaultValues() {
        let vehicle = managed(Vehicle(name: "My Car"))

        XCTAssertEqual(vehicle.name, "My Car")
        XCTAssertNil(vehicle.make)
        XCTAssertNil(vehicle.model)
        XCTAssertNil(vehicle.year)
        XCTAssertNotNil(vehicle.id)
        XCTAssertNotNil(vehicle.createdAt)
        XCTAssertEqual(vehicle.unitSystem, .imperial)
        XCTAssertEqual(vehicle.unitSystemRaw, "imperial")
    }

    func testInitializationWithAllValues() {
        let customId = UUID()
        let customDate = Date(timeIntervalSince1970: 1000000)

        let vehicle = managed(
            Vehicle(
            id: customId,
            name: "Daily Driver",
            make: "Toyota",
            model: "Camry",
            year: 2023,
            createdAt: customDate,
            unitSystem: .metric
            ))

        XCTAssertEqual(vehicle.id, customId)
        XCTAssertEqual(vehicle.name, "Daily Driver")
        XCTAssertEqual(vehicle.make, "Toyota")
        XCTAssertEqual(vehicle.model, "Camry")
        XCTAssertEqual(vehicle.year, 2023)
        XCTAssertEqual(vehicle.createdAt, customDate)
        XCTAssertEqual(vehicle.unitSystem, .metric)
        XCTAssertEqual(vehicle.unitSystemRaw, "metric")
    }

    // MARK: - Unit System Tests

    func testUnitSystemDefaultsToImperial() {
        let vehicle = managed(Vehicle(name: "Test Car"))
        XCTAssertEqual(vehicle.unitSystem, .imperial)
    }

    func testUnitSystemAccessor() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        vehicle.unitSystem = .metric
        XCTAssertEqual(vehicle.unitSystem, .metric)
        XCTAssertEqual(vehicle.unitSystemRaw, "metric")

        vehicle.unitSystem = .imperial
        XCTAssertEqual(vehicle.unitSystem, .imperial)
        XCTAssertEqual(vehicle.unitSystemRaw, "imperial")
    }

    func testUnitSystemFallbackForInvalidRaw() {
        let vehicle = managed(Vehicle(name: "Test Car"))
        vehicle.unitSystemRaw = "invalid"
        XCTAssertEqual(vehicle.unitSystem, .imperial) // Fallback
    }

    func testLocalEfficiencyPreferenceDoesNotMutateVehicleData() {
        let suiteName = "VehicleEfficiencyPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let vehicle = managed(Vehicle(name: "Metric Car", unitSystem: .metric))
        let record = FuelingRecord(
            odometer: 12_345.6,
            pricePerFuelUnit: 1.789,
            fuelAmount: 42.5,
            totalCost: 76.03,
            vehicle: vehicle
        )
        vehicle.fuelingRecords = [record]
        vehicle.cachedAverageEfficiency = 18.75
        vehicle.cachedTotalDistance = 8_000
        vehicle.cachedTotalFuel = 426.67

        MetricEfficiencyFormat.kilometersPerLiter.store(
            for: vehicle.id,
            defaults: defaults
        )

        XCTAssertEqual(vehicle.unitSystemRaw, "metric")
        XCTAssertEqual(vehicle.unitSystem, .metric)
        XCTAssertEqual(record.odometer, 12_345.6)
        XCTAssertEqual(record.pricePerFuelUnit, 1.789)
        XCTAssertEqual(record.fuelAmount, 42.5)
        XCTAssertEqual(record.totalCost, 76.03)
        XCTAssertEqual(vehicle.cachedAverageEfficiency, 18.75)
        XCTAssertEqual(vehicle.cachedTotalDistance, 8_000)
        XCTAssertEqual(vehicle.cachedTotalFuel, 426.67)
    }

    // MARK: - Display Name Tests

    func testDisplayNameWithMakeModelAndYear() {
        let vehicle = managed(
            Vehicle(
            name: "My Car",
            make: "Honda",
            model: "Accord",
            year: 2022
            ))

        XCTAssertEqual(vehicle.displayName, "2022 Honda Accord")
    }

    func testDisplayNameWithMakeAndModelOnly() {
        let vehicle = managed(
            Vehicle(
            name: "My Car",
            make: "Honda",
            model: "Accord",
            year: nil
            ))

        XCTAssertEqual(vehicle.displayName, "Honda Accord")
    }

    func testDisplayNameWithNameOnly() {
        let vehicle = managed(Vehicle(name: "Family Van"))

        XCTAssertEqual(vehicle.displayName, "Family Van")
    }

    func testDisplayNameWithMakeOnlyFallsBackToName() {
        let vehicle = managed(
            Vehicle(
            name: "My Car",
            make: "Honda",
            model: nil,
            year: nil
            ))

        XCTAssertEqual(vehicle.displayName, "My Car")
    }

    func testDisplayNameWithModelOnlyFallsBackToName() {
        let vehicle = managed(
            Vehicle(
            name: "My Car",
            make: nil,
            model: "Accord",
            year: nil
            ))

        XCTAssertEqual(vehicle.displayName, "My Car")
    }

    // MARK: - Sorted Records Tests

    func testSortedRecordsEmptyWhenNoRecords() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        XCTAssertTrue(vehicle.sortedRecords.isEmpty)
    }

    func testSortedRecordsReturnsMostRecentFirst() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        let oldDate = Date(timeIntervalSince1970: 1000000)
        let newDate = Date(timeIntervalSince1970: 2000000)

        let oldRecord = FuelingRecord(
            date: oldDate,
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            vehicle: vehicle
        )

        let newRecord = FuelingRecord(
            date: newDate,
            odometer: 10500,
            pricePerFuelUnit: 3.60,
            fuelAmount: 11.0,
            totalCost: 39.60,
            vehicle: vehicle
        )

        vehicle.fuelingRecords = [oldRecord, newRecord]

        let sorted = vehicle.sortedRecords
        XCTAssertEqual(sorted.count, 2)
        XCTAssertEqual(sorted[0].date, newDate)
        XCTAssertEqual(sorted[1].date, oldDate)
    }

    func testSortedRecordsAndLastRecordUseOdometerForEqualTimestamps() {
        let vehicle = managed(Vehicle(name: "Test Car"))
        let sameDate = Date(timeIntervalSince1970: 1_000_000)
        let lower = FuelingRecord(
            date: sameDate,
            odometer: 10_000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10,
            totalCost: 35,
            vehicle: vehicle
        )
        let higher = FuelingRecord(
            date: sameDate,
            odometer: 10_500,
            pricePerFuelUnit: 3.60,
            fuelAmount: 10,
            totalCost: 36,
            vehicle: vehicle
        )
        vehicle.fuelingRecords = [lower, higher]

        XCTAssertEqual(vehicle.sortedRecords.map(\.id), [higher.id, lower.id])
        XCTAssertEqual(vehicle.lastRecord?.id, higher.id)
    }

    // MARK: - Last Record Tests

    func testLastRecordReturnsNilWhenNoRecords() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        XCTAssertNil(vehicle.lastRecord)
    }

    func testLastRecordReturnsMostRecentRecord() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        let oldDate = Date(timeIntervalSince1970: 1000000)
        let newDate = Date(timeIntervalSince1970: 2000000)

        let oldRecord = FuelingRecord(
            date: oldDate,
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            vehicle: vehicle
        )

        let newRecord = FuelingRecord(
            date: newDate,
            odometer: 10500,
            pricePerFuelUnit: 3.60,
            fuelAmount: 11.0,
            totalCost: 39.60,
            vehicle: vehicle
        )

        vehicle.fuelingRecords = [oldRecord, newRecord]

        let lastRecord = vehicle.lastRecord
        XCTAssertNotNil(lastRecord)
        XCTAssertEqual(lastRecord?.date, newDate)
        XCTAssertEqual(lastRecord?.odometer, 10500)
    }

    // MARK: - Cache Status Tests

    func testNeedsCacheRebuildWhenNoCacheExists() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        XCTAssertTrue(vehicle.needsCacheRebuild)
    }

    func testNeedsCacheRebuildWhenCacheCountMismatch() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        vehicle.cacheLastUpdated = Date()
        vehicle.cachedRecordCount = 5

        XCTAssertTrue(vehicle.needsCacheRebuild)
    }

    func testNeedsCacheRebuildFalseWhenCacheMatches() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        vehicle.cacheLastUpdated = Date()
        vehicle.cachedRecordCount = 0

        XCTAssertFalse(vehicle.needsCacheRebuild)
    }

    func testNeedsCacheRebuildWhenRecordCountIsNil() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        vehicle.cacheLastUpdated = Date()
        vehicle.cachedRecordCount = nil

        XCTAssertTrue(vehicle.needsCacheRebuild)
    }

    // MARK: - Invalidate Cache Tests

    func testInvalidateCacheClearsAllCachedValues() {
        let vehicle = managed(Vehicle(name: "Test Car"))

        // Set all cached values
        vehicle.cachedTotalSpent = 1000.0
        vehicle.cachedTotalDistance = 5000.0
        vehicle.cachedTotalFuel = 200.0
        vehicle.cachedAverageEfficiency = 25.0
        vehicle.cachedAverageCostPerDistance = 0.20
        vehicle.cachedAverageFillUpCost = 50.0
        vehicle.cachedAveragePricePerFuelUnit = 3.50
        vehicle.cachedBestEfficiency = 32.0
        vehicle.cachedWorstEfficiency = 18.0
        vehicle.cachedHighestPricePerFuelUnit = 4.50
        vehicle.cachedLowestPricePerFuelUnit = 2.80
        vehicle.cachedRecordCount = 20
        vehicle.cacheLastUpdated = Date()

        // Invalidate cache
        vehicle.invalidateCache()

        // Verify all values are nil
        XCTAssertNil(vehicle.cachedTotalSpent)
        XCTAssertNil(vehicle.cachedTotalDistance)
        XCTAssertNil(vehicle.cachedTotalFuel)
        XCTAssertNil(vehicle.cachedAverageEfficiency)
        XCTAssertNil(vehicle.cachedAverageCostPerDistance)
        XCTAssertNil(vehicle.cachedAverageFillUpCost)
        XCTAssertNil(vehicle.cachedAveragePricePerFuelUnit)
        XCTAssertNil(vehicle.cachedBestEfficiency)
        XCTAssertNil(vehicle.cachedWorstEfficiency)
        XCTAssertNil(vehicle.cachedHighestPricePerFuelUnit)
        XCTAssertNil(vehicle.cachedLowestPricePerFuelUnit)
        XCTAssertNil(vehicle.cachedRecordCount)
        XCTAssertNil(vehicle.cacheLastUpdated)
    }

    // MARK: - Edge Cases

    func testVehicleWithEmptyName() {
        let vehicle = managed(Vehicle(name: ""))

        XCTAssertEqual(vehicle.name, "")
        XCTAssertEqual(vehicle.displayName, "")
    }

    func testVehicleWithZeroYear() {
        let vehicle = managed(
            Vehicle(
            name: "Test Car",
            make: "Toyota",
            model: "Corolla",
            year: 0
            ))

        XCTAssertEqual(vehicle.displayName, "0 Toyota Corolla")
    }

    func testVehicleWithNegativeYear() {
        let vehicle = managed(
            Vehicle(
            name: "Test Car",
            make: "Toyota",
            model: "Corolla",
            year: -1
            ))

        XCTAssertEqual(vehicle.displayName, "-1 Toyota Corolla")
    }
}
