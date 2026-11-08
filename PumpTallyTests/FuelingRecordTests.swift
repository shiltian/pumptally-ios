import XCTest
import SwiftData
@testable import PumpTally

@MainActor
final class FuelingRecordTests: XCTestCase {
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
            fixtureContainer.mainContext.insert(testVehicle)
        }
    }

    private func managed(_ vehicle: Vehicle) -> Vehicle {
        fixtureContainer.mainContext.insert(vehicle)
        return vehicle
    }

    private let testVehicle = Vehicle(name: "Test Car")

    // MARK: - Initialization Tests

    func testInitializationWithDefaultValues() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.odometer, 10000)
        XCTAssertEqual(record.pricePerFuelUnit, 3.50)
        XCTAssertEqual(record.fuelAmount, 12.5)
        XCTAssertEqual(record.totalCost, 43.75)
        XCTAssertEqual(record.fillUpType, .full)
        XCTAssertNil(record.notes)
        XCTAssertNotNil(record.id)
        XCTAssertNotNil(record.date)
        XCTAssertNotNil(record.createdAt)
    }

    @MainActor
    func testNewRecordsHaveOneOwnerBeforeSavingAndAfterReopening() throws {
        // Keep the isolated store until SwiftData releases its SQLite handles.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ownership-\(UUID()).store")
        let schema = Schema(versionedSchema: SchemaV6.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Existing vehicle")
        context.insert(vehicle)
        try context.save()

        let records = (0..<2).map { index in
            FuelingRecord(
                odometer: 1000.123456789 + Double(index) * 300, pricePerFuelUnit: 3.459876543,
                fuelAmount: 10.123456789, totalCost: 35.123456789, vehicle: vehicle)
        }
        XCTAssertEqual(vehicle.fuelingRecords?.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.vehicle === vehicle })
        for record in records { context.insert(record) }
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        try context.save()

        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let saved = ModelContext(reopened)
        let owner = try XCTUnwrap(saved.fetch(FetchDescriptor<Vehicle>()).first)
        XCTAssertEqual(owner.cachedRecordCount, 2)
        XCTAssertEqual(Set((owner.fuelingRecords ?? []).map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(try saved.fetchCount(FetchDescriptor<FuelingRecord>()), 2)
        for record in try saved.fetch(FetchDescriptor<FuelingRecord>()) {
            XCTAssertEqual(record.vehicle.id, vehicle.id)
            XCTAssertEqual(record.fuelAmount.bitPattern, 10.123456789.bitPattern)
            XCTAssertEqual(record.pricePerFuelUnit.bitPattern, 3.459876543.bitPattern)
            XCTAssertEqual(record.totalCost.bitPattern, 35.123456789.bitPattern)
        }
    }

    func testInitializationWithCustomValues() {
        let customId = UUID()
        let customDate = Date(timeIntervalSince1970: 1000000)

        let record = FuelingRecord(
            id: customId,
            date: customDate,
            odometer: 25000,
            pricePerFuelUnit: 4.25,
            fuelAmount: 15.0,
            totalCost: 63.75,
            fillUpType: .partial,
            notes: "Test note",
            createdAt: customDate,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.id, customId)
        XCTAssertEqual(record.date, customDate)
        XCTAssertEqual(record.odometer, 25000)
        XCTAssertEqual(record.pricePerFuelUnit, 4.25)
        XCTAssertEqual(record.fuelAmount, 15.0)
        XCTAssertEqual(record.totalCost, 63.75)
        XCTAssertEqual(record.fillUpType, .partial)
        XCTAssertEqual(record.notes, "Test note")
    }

    // MARK: - Fill-up Type Tests

    func testFillUpTypeAccessor() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            fillUpType: .full,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.fillUpType, .full)
        XCTAssertEqual(record.fillUpTypeRaw, "full")

        record.fillUpType = .partial
        XCTAssertEqual(record.fillUpType, .partial)
        XCTAssertEqual(record.fillUpTypeRaw, "partial")

        record.fillUpType = .reset
        XCTAssertEqual(record.fillUpType, .reset)
        XCTAssertEqual(record.fillUpTypeRaw, "reset")
    }

    func testIsPartialFillUp() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            fillUpType: .partial,
            vehicle: testVehicle
        )

        XCTAssertTrue(record.isPartialFillUp)
        XCTAssertFalse(record.isFullFillUp)
    }

    func testIsReset() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            fillUpType: .reset,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.fillUpType, .reset)
        XCTAssertFalse(record.isFullFillUp)
        XCTAssertFalse(record.isPartialFillUp)
    }

    func testIsFullFillUp() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            fillUpType: .full,
            vehicle: testVehicle
        )

        XCTAssertTrue(record.isFullFillUp)
        XCTAssertFalse(record.isPartialFillUp)
    }

    // MARK: - Cached Value Tests

    func testGetPreviousOdometerWithCachedValue() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9500
        XCTAssertEqual(record.getPreviousOdometer(), 9500)
    }

    func testGetPreviousOdometerWithFallback() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.getPreviousOdometer(fallback: 100), 100)
    }

    func testGetDistanceDrivenWithCachedValue() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        record.cachedDistanceDriven = 500
        XCTAssertEqual(record.getDistanceDriven(), 500)
    }

    func testGetDistanceDrivenCalculated() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9500
        XCTAssertEqual(record.getDistanceDriven(), 500)
    }

    func testGetDistanceDrivenNoPreviousOdometer() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.getDistanceDriven(), 0)
    }

    func testGetEfficiencyWithCachedValue() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 12.5,
            totalCost: 43.75,
            vehicle: testVehicle
        )

        record.cachedEfficiency = 32.5
        XCTAssertEqual(record.getEfficiency(), 32.5)
    }

    func testGetEfficiencyCalculated() {
        let previousRecord = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_000_000),
            odometer: 9700,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            fillUpType: .full,
            vehicle: testVehicle
        )
        let record = FuelingRecord(
            date: Date(timeIntervalSince1970: 2_000_000),
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            fillUpType: .full,
            vehicle: testVehicle
        )

        testVehicle.fuelingRecords = [record, previousRecord]
        // Should calculate: (10000 - 9700) / 10 = 30
        XCTAssertEqual(record.getEfficiency(), 30.0)
    }

    func testGetEfficiencyReturnsZeroForPartialFillUp() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            fillUpType: .partial,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9700
        XCTAssertEqual(record.getEfficiency(), 0)
    }

    func testGetEfficiencyReturnsZeroForReset() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            fillUpType: .reset,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9700
        XCTAssertEqual(record.getEfficiency(), 0)
    }

    func testGetEfficiencyReturnsZeroForZeroFuelAmount() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 0,
            totalCost: 0,
            fillUpType: .full,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9700
        XCTAssertEqual(record.getEfficiency(), 0)
    }

    func testGetCostPerDistanceWithCachedValue() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            vehicle: testVehicle
        )

        record.cachedCostPerDistance = 0.12
        XCTAssertEqual(record.getCostPerDistance(), 0.12)
    }

    func testGetCostPerDistanceCalculated() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            vehicle: testVehicle
        )

        record.cachedPreviousOdometer = 9700
        // Cost per distance: 35 / 300 = 0.1166...
        XCTAssertEqual(record.getCostPerDistance(), 35.0 / 300.0, accuracy: 0.0001)
    }

    func testGetCostPerDistanceReturnsZeroForZeroDistance() {
        let record = FuelingRecord(
            odometer: 10000,
            pricePerFuelUnit: 3.50,
            fuelAmount: 10.0,
            totalCost: 35.0,
            vehicle: testVehicle
        )

        XCTAssertEqual(record.getCostPerDistance(), 0)
    }

}
