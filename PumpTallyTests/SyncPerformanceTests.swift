import CloudKit
import SwiftData
import XCTest

@testable import PumpTally

/// Disk-backed scaling checks. Each vehicle has 800 records; increasing the
/// store size adds unrelated history rather than changing the affected history.
@MainActor
final class SyncPerformanceTests: XCTestCase {
    private struct Fixture {
        let container: ModelContainer
        let incoming: CKRecord
        let recordID: UUID
    }

    private func fixture(count: Int) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Model executors release SQLite handles asynchronously. Keep these
        // isolated files in the test app temporary directory until its cleanup.
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema, url: directory.appendingPathComponent("store"), cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        var target: FuelingRecord?
        for owner in 0..<(count / 800) {
            let vehicle = Vehicle(name: "History \(owner)")
            context.insert(vehicle)
            for index in 0..<800 {
                let record = FuelingRecord(
                    date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                    odometer: 1_000.123456789 + Double(index) * 250,
                    pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789,
                    totalCost: 35.123456789, notes: "History \(owner):\(index)",
                    createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
                context.insert(record)
                if target == nil { target = record }
            }
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            try context.save()
        }
        let record = try XCTUnwrap(target)
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        try SyncChangeJournal.enqueue(record, in: context)
        try context.save()
        return Fixture(container: container, incoming: incoming, recordID: record.id)
    }

    private func measureUpload(count: Int) throws {
        let fixture = try fixture(count: count)
        let environment = TestingCloudSyncEnvironment()
        environment.automaticDelivery = false
        let suite = "Performance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = SyncStateManager(defaults: defaults)
        state.iCloudSyncEnabled = true
        state.initialSyncCompleted = true
        let writer = OwnedModelStore(container: fixture.container)
        let service = CloudSyncService(
            writer: writer, stateManager: state, environment: environment)
        let started = expectation(description: "Start isolated engine")
        Task {
            do {
                try await SyncPersistenceStore(writer: writer).activate(accountID: environment.userID) { _ in }
                await service.startMonitoring()
            } catch { XCTFail("\(error)") }
            started.fulfill()
        }
        wait(for: [started], timeout: 30)
        let driver = try XCTUnwrap(environment.drivers.last)
        addTeardownBlock { await service.stopMonitoring() }
        let verified = expectation(description: "Verify bounded reads")
        Task {
            let preparation = await CloudChangeBatchBuilder.make(
                container: fixture.container,
                codec: CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID), blockedParents: [])
            do {
                _ = try await preparation.build(
                    pendingChanges: driver.pendingRecordZoneChanges,
                    control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
                let asyncResult1 = (await preparation.metrics).journalEntriesRead
                XCTAssertEqual(asyncResult1, 1)
                let asyncResult2 = (await preparation.metrics).fuelingRecordsRead
                XCTAssertEqual(asyncResult2, 1)
                let asyncResult3 = (await preparation.metrics).vehiclesRead
                XCTAssertEqual(asyncResult3, 0)
                let asyncResult4 = (await preparation.metrics).recordsEncoded
                XCTAssertEqual(asyncResult4, 1)
            } catch { XCTFail("\(error)") }
            verified.fulfill()
        }
        wait(for: [verified], timeout: 30)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let prepared = expectation(description: "Prepare one upload")
            Task {
                let batch = await driver.batch()
                XCTAssertEqual(batch?.businessRecordsToSave.map(\.recordID.recordName), [fixture.recordID.uuidString])
                prepared.fulfill()
            }
            wait(for: [prepared], timeout: 30)
        }
    }

    private func measureDownload(count: Int) throws {
        let fixture = try fixture(count: count)
        let reconciliation = CloudReconciliationService(
            codec: CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID))
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let context = ModelContext(fixture.container)
            context.autosaveEnabled = false
            fixture.incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = "Updated note"
            fixture.incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(
                timeIntervalSince1970: 2_000_000)
            do {
                let result = try reconciliation.stageRemoteChanges(
                    changedRecords: [fixture.incoming], deletedRecordIDs: [], context: context)
                XCTAssertEqual(result.indexedVehicleCount, 1)
                XCTAssertEqual(result.indexedFuelingRecordCount, 1)
                XCTAssertTrue(result.affectedVehicleIDs.isEmpty)
            } catch { XCTFail("\(error)") }
            // Every iteration reads the same persisted state. Saves are covered
            // by runtime/fidelity tests, outside the preparation metric.
            context.rollback()
        }
    }

    func testUpload800() throws { try measureUpload(count: 800) }
    func testUpload3200() throws { try measureUpload(count: 3_200) }
    func testUpload12800() throws { try measureUpload(count: 12_800) }
    func testDownload800() throws { try measureDownload(count: 800) }
    func testDownload3200() throws { try measureDownload(count: 3_200) }
    func testDownload12800() throws { try measureDownload(count: 12_800) }
}
