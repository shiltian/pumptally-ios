import CloudKit
import SwiftData
import SwiftUI
import XCTest
import os

@testable import PumpTally

@MainActor
final class ChartInputTests: XCTestCase {
    private var fixtureContainer: ModelContainer?

    private func fixture() throws -> (ModelContainer, Vehicle, [FuelingRecord]) {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Chart-\(UUID()).store")
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        fixtureContainer = container
        let context = container.mainContext
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Chart fixture", createdAt: Date(timeIntervalSince1970: 1_000_000))
        context.insert(vehicle)
        var records: [FuelingRecord] = []
        for index in 0..<3 {
            let price = Double(index + 3)
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400)
            let record = FuelingRecord(
                date: date, odometer: 1000 + Double(index) * 300,
                pricePerFuelUnit: price, fuelAmount: 10, totalCost: price * 10,
                createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
            context.insert(record)
            records.append(record)
        }
        context.processPendingChanges()
        StatisticsCacheService.refresh(for: vehicle)
        try context.save()
        return (container, vehicle, records)
    }

    func testPriceSwapChangesChartInputWhenEveryAggregateAndCacheTimestampStayUnchanged() throws {
        let (container, vehicle, records) = try fixture()
        let before = ChartInput(vehicle: vehicle, records: records)
        let timestamp = vehicle.cacheLastUpdated
        records[0].pricePerFuelUnit = 4
        records[1].pricePerFuelUnit = 3
        StatisticsCacheService.refresh(for: vehicle)
        try container.mainContext.save()
        let after = ChartInput(vehicle: vehicle, records: records)
        XCTAssertEqual(vehicle.cacheLastUpdated, timestamp)
        XCTAssertEqual(vehicle.cachedAveragePricePerFuelUnit, 4)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(PrecomputedChartData(input: before).priceData.map(\.value), [3, 4, 5])
        XCTAssertEqual(PrecomputedChartData(input: after).priceData.map(\.value), [4, 3, 5])
        XCTAssertEqual(
            PrecomputedChartData(input: before).priceAverage,
            PrecomputedChartData(input: after).priceAverage)
    }

    func testCostSwapChangesSeriesEvenWithUnchangedTotalAndAverage() throws {
        let (_, vehicle, records) = try fixture()
        let before = ChartInput(vehicle: vehicle, records: records)
        records[0].totalCost = 40
        records[1].totalCost = 30
        let after = ChartInput(vehicle: vehicle, records: records)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(
            PrecomputedChartData(input: before).costAverage,
            PrecomputedChartData(input: after).costAverage)
        XCTAssertEqual(PrecomputedChartData(input: after).costData.map(\.value), [40, 30, 50])
    }

    func testDisplayUnitsAndEfficiencyFormatChangeInputsWithoutChangingStoredMeasurements() throws {
        let (_, vehicle, records) = try fixture()
        let bits = records.map { [$0.odometer.bitPattern, $0.fuelAmount.bitPattern, $0.pricePerFuelUnit.bitPattern] }
        let original = ChartInput(vehicle: vehicle, records: records)
        vehicle.displayUnitSystem = .metric
        let metric = ChartInput(vehicle: vehicle, records: records)
        XCTAssertNotEqual(metric, original)
        XCTAssertEqual(
            metric.records[0].pricePerFuelUnit,
            UnitSystem.metric.priceValue(3, from: .imperial))
        let formats = MetricEfficiencyFormat.allCases
        XCTAssertNotEqual(
            ChartInput(vehicle: vehicle, records: records, metricEfficiencyFormat: formats[0]),
            ChartInput(vehicle: vehicle, records: records, metricEfficiencyFormat: formats[1]))
        XCTAssertEqual(
            records.map { [$0.odometer.bitPattern, $0.fuelAmount.bitPattern, $0.pricePerFuelUnit.bitPattern] }, bits)
    }

    func testUnrelatedNotesAndCacheBookkeepingDoNotInvalidateCharts() throws {
        let (_, vehicle, records) = try fixture()
        let before = ChartInput(vehicle: vehicle, records: records)
        records[0].notes = "Changed notes"
        records[0].modifiedAt = Date()
        vehicle.cacheLastUpdated = Date()
        XCTAssertEqual(ChartInput(vehicle: vehicle, records: records), before)
    }

    private final class Observer: Sendable {
        private let state = OSAllocatedUnfairLock<ChartInput?>(initialState: nil)
        var input: ChartInput? {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    private struct RenderedInput: UIViewRepresentable {
        let input: ChartInput
        let observer: Observer
        func makeUIView(context: Context) -> UILabel { UILabel() }
        func updateUIView(_ view: UILabel, context: Context) { observer.input = input }
    }

    private struct Probe: View {
        @Query(sort: \FuelingRecord.date) private var records: [FuelingRecord]
        @Query private var vehicles: [Vehicle]
        let observer: Observer
        var body: some View {
            if let vehicle = vehicles.first {
                RenderedInput(input: ChartInput(vehicle: vehicle, records: records), observer: observer)
            }
        }
    }

    func testSwiftDataQueryPublishesRemotePriceSwapWithoutAnyCacheRevisionChange() async throws {
        if !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
            let activated = expectation(forNotification: UIScene.didActivateNotification, object: nil)
            await fulfillment(of: [activated], timeout: 5)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let (container, vehicle, records) = try fixture()
        let timestamp = vehicle.cacheLastUpdated
        let observer = Observer()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Probe(observer: observer).modelContainer(container))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let initial = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                observer.input?.records.map(\.pricePerFuelUnit) == [3, 4, 5]
            }, object: nil)
        await fulfillment(of: [initial], timeout: 5)
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let incoming = try records.prefix(2).enumerated().map { index, record in
            let remote = codec.fuelingRecordToCKRecord(
                record,
                vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            remote[CloudRecordCodec.CloudFieldKey.FuelingRecord.pricePerFuelUnit] = index == 0 ? 4.0 : 3.0
            remote[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 2_000_000)
            return try CloudMeasurementPayload.confirmedLegacyRecord(remote, unit: .imperial)
        }
        try await OwnedModelStore(container: container).transaction { actor in
            _ = try CloudReconciliationService(codec: codec).stageRemoteChanges(
                changedRecords: incoming, deletedRecordIDs: [], context: actor.modelContext)
        }
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                observer.input?.records.map(\.pricePerFuelUnit) == [4, 3, 5]
            }, object: nil)
        await fulfillment(of: [updated], timeout: 5)
        let input = try XCTUnwrap(observer.input)
        XCTAssertEqual(PrecomputedChartData(input: input).priceData.map(\.value), [4, 3, 5])
        XCTAssertEqual(vehicle.cacheLastUpdated, timestamp)
    }
}

private extension ChartRecordSnapshot {
    @MainActor
    init(record: FuelingRecord) {
        let units = record.vehicle.displayUnitSystem
        let storage = record.vehicle.unitSystem
        self.init(
            id: record.id, date: record.date,
            odometer: units.distanceValue(record.odometer, from: storage),
            cachedEfficiency: record.cachedEfficiency.map { units.efficiencyValue($0, from: storage) },
            totalCost: record.totalCost,
            pricePerFuelUnit: units.priceValue(record.pricePerFuelUnit, from: storage))
    }
}

private extension ChartInput {
    @MainActor
    init(vehicle: Vehicle, records: [FuelingRecord], metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat) {
        self.init(
            records: records.map(ChartRecordSnapshot.init(record:)),
            unitSystem: vehicle.displayUnitSystem,
            rawAverageEfficiency: vehicle.displayUnitSystem.efficiencyValue(
                vehicle.cachedAverageEfficiency ?? 0, from: vehicle.unitSystem),
            metricEfficiencyFormat: metricEfficiencyFormat)
    }

}
