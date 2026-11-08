import SwiftData
import XCTest

@testable import PumpTally

/// Optimized, disk-backed launch measurements. Fixture construction and cache
/// invalidation are outside the measured interval; repair includes its saves.
@MainActor
final class StartupCachePerformanceTests: XCTestCase {
    private func fixture(count: Int, recordsPerVehicle: Int, cached: Bool) throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema, url: directory.appendingPathComponent("history.store"), cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for owner in 0..<(count / recordsPerVehicle) {
            let vehicle = Vehicle(name: "History \(owner)")
            context.insert(vehicle)
            for index in 0..<recordsPerVehicle {
                context.insert(
                    FuelingRecord(
                        date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                        odometer: 1_000.123456789 + Double(index) * 250,
                        pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789,
                        totalCost: 35.123456789, vehicle: vehicle))
            }
            context.processPendingChanges()
            if cached { StatisticsCacheService.recalculateAllStatistics(for: vehicle) }
            try context.save()
        }
        return container
    }

    private func measureStartup(count: Int, cold: Bool, recordsPerVehicle: Int = 800) throws {
        let container = try fixture(count: count, recordsPerVehicle: recordsPerVehicle, cached: !cold)
        let service = StatisticsCachePersistenceService(container: container)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            if cold {
                do {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) { vehicle.invalidateCache() }
                    for record in try context.fetch(FetchDescriptor<FuelingRecord>()) {
                        record.cachedPreviousOdometer = nil
                        record.cachedDistanceDriven = nil
                        record.cachedEfficiency = nil
                        record.cachedCostPerDistance = nil
                    }
                    try context.save()
                } catch {
                    XCTFail("Fixture invalidation failed: \(error)")
                    return
                }
            }
            let completed = expectation(description: "Startup cache validation")
            Task {
                startMeasuring()
                do {
                    let rebuilt = try await service.rebuildIfNeeded()
                    stopMeasuring()
                    XCTAssertEqual(rebuilt, cold ? count / recordsPerVehicle : 0)
                } catch {
                    stopMeasuring()
                    XCTFail("Cache repair failed: \(error)")
                }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
    }

    func testWarm800() throws { try measureStartup(count: 800, cold: false) }
    func testWarm3200() throws { try measureStartup(count: 3_200, cold: false) }
    func testWarm12800() throws { try measureStartup(count: 12_800, cold: false) }
    func testCold800() throws { try measureStartup(count: 800, cold: true) }
    func testCold3200() throws { try measureStartup(count: 3_200, cold: true) }
    func testCold12800() throws { try measureStartup(count: 12_800, cold: true) }
    func testSingleVehicleCold12800() throws {
        try measureStartup(count: 12_800, cold: true, recordsPerVehicle: 12_800)
    }
}
