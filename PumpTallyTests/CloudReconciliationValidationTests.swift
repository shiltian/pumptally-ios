import CloudKit
import SwiftData
import XCTest

@testable import PumpTally

@MainActor
final class CloudReconciliationValidationTests: XCTestCase {
    private enum Path: CaseIterable { case merge, incremental }
    private let zoneID = CKRecordZone.ID(zoneName: "validation-tests")
    private let originalDate = Date(timeIntervalSince1970: 1_000_000)
    private let newerDate = Date(timeIntervalSince1970: 2_000_000)

    private func fixture() throws -> (ModelContext, FuelingRecord) {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Original vehicle", createdAt: originalDate)
        let record = FuelingRecord(
            date: originalDate, odometer: 1000, pricePerFuelUnit: 3.5,
            fuelAmount: 10, totalCost: 35, notes: "Original note", createdAt: originalDate, vehicle: vehicle)
        context.insert(vehicle)
        context.insert(record)
        try context.save()
        return (context, record)
    }

    private func apply(_ incoming: CKRecord, path: Path, context: ModelContext, owner: Vehicle) throws {
        let codec = CloudRecordCodec(zoneID: zoneID)
        let reconciliation = CloudReconciliationService(codec: codec)
        switch path {
        case .merge:
            _ = try reconciliation.reconcileMerge(
                vehicleCKRecords: [codec.vehicleToCKRecord(owner)],
                fuelingCKRecords: [incoming], context: context)
            try context.save()
        case .incremental:
            _ = try reconciliation.applyRemoteChanges(
                changedRecords: [incoming], deletedRecordIDs: [], context: context)
        }
    }

    func testMalformedOptionalFieldsCannotEraseExistingNotes() throws {
        for path in Path.allCases {
            let (context, record) = try fixture()
            let codec = CloudRecordCodec(zoneID: zoneID)
            let incoming = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = 123
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = newerDate
            try apply(incoming, path: path, context: context, owner: record.vehicle)
            XCTAssertEqual(record.notes, "Original note", "\(path)")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1, "\(path)")
        }
    }

    func testIncomingRecordCannotChangeItsOwnerAndMeasurementBasis() throws {
        for path in Path.allCases {
            let (context, record) = try fixture()
            let original = FuelingRecordValues(record: record)
            let ownerID = record.vehicle.id
            let other = Vehicle(name: "Other vehicle", unitSystem: .metric)
            context.insert(other)
            try context.save()
            let codec = CloudRecordCodec(zoneID: zoneID)
            let incoming = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] = other.id.uuidString
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = newerDate
            try apply(incoming, path: path, context: context, owner: other)
            XCTAssertEqual(record.vehicle.id, ownerID, "\(path)")
            XCTAssertEqual(FuelingRecordValues(record: record), original, "\(path)")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1, "\(path)")
        }
    }

    func testFullMergePreservesMalformedAndOrphanedCloudRecords() throws {
        let (context, record) = try fixture()
        let codec = CloudRecordCodec(zoneID: zoneID)
        let malformed = CKRecord(
            recordType: "FuelingRecord", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        let orphanID = UUID()
        let orphan = CKRecord(
            recordType: "FuelingRecord", recordID: CKRecord.ID(recordName: orphanID.uuidString, zoneID: zoneID))
        let original = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        for key in original.allKeys() { orphan[key] = original[key] }
        orphan[CloudRecordCodec.CloudFieldKey.FuelingRecord.id] = orphanID.uuidString
        orphan[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] = UUID().uuidString
        _ = try CloudReconciliationService(codec: codec).reconcileMerge(
            vehicleCKRecords: [codec.vehicleToCKRecord(record.vehicle)], fuelingCKRecords: [malformed, orphan],
            context: context)
        try context.save()
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 2)
        XCTAssertEqual(record.odometer, 1000)
    }

    func testMergeCannotUploadAQuarantinedVehiclesLocalChildren() throws {
        let (context, record) = try fixture()
        let codec = CloudRecordCodec(zoneID: zoneID)
        let parent = codec.vehicleToCKRecord(record.vehicle)
        parent[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] = "metric"
        let uploads = try CloudReconciliationService(codec: codec).reconcileMerge(
            vehicleCKRecords: [parent], fuelingCKRecords: [], context: context)
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(record.vehicle.unitSystem, .imperial)
    }

    func testIncrementalApplyDoesNotRewriteUnrelatedOrUnchangedCaches() throws {
        let (context, record) = try fixture()
        let unrelated = Vehicle(name: "Unrelated")
        unrelated.cacheLastUpdated = originalDate
        context.insert(unrelated)
        try context.save()
        let codec = CloudRecordCodec(zoneID: zoneID)
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = "New note"
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = newerDate
        let reconciliation = CloudReconciliationService(codec: codec)
        _ = try reconciliation.applyRemoteChanges(changedRecords: [incoming], deletedRecordIDs: [], context: context)
        XCTAssertEqual(unrelated.cacheLastUpdated, originalDate)
        let lastUpdate = record.vehicle.cacheLastUpdated
        _ = try reconciliation.applyRemoteChanges(changedRecords: [], deletedRecordIDs: [], context: context)
        XCTAssertEqual(record.vehicle.cacheLastUpdated, lastUpdate)
        XCTAssertEqual(unrelated.cacheLastUpdated, originalDate)
    }

    func testNumericDownloadAndDeletionOnlyDirtyDependentIntervals() throws {
        let (context, first) = try fixture()
        let owner = first.vehicle
        var rows = [first]
        for index in 1..<80 {
            let row = FuelingRecord(
                date: originalDate.addingTimeInterval(Double(index) * 86_400),
                odometer: 1000 + Double(index) * 300, pricePerFuelUnit: 3.5, fuelAmount: 10,
                totalCost: 35, createdAt: originalDate, vehicle: owner)
            context.insert(row)
            rows.append(row)
        }
        context.processPendingChanges()
        StatisticsCacheService.recalculateAllStatistics(for: owner)
        try context.save()
        let codec = CloudRecordCodec(zoneID: zoneID)
        let remoteOwner = Vehicle(id: owner.id, name: owner.name, createdAt: originalDate)
        let target = rows[40]
        let remote = FuelingRecord(
            id: target.id, date: target.date, odometer: target.odometer + 10,
            pricePerFuelUnit: target.pricePerFuelUnit, fuelAmount: 12, totalCost: target.totalCost,
            createdAt: originalDate, vehicle: remoteOwner)
        remote.modifiedAt = newerDate
        let incoming = codec.fuelingRecordToCKRecord(
            remote, vehicleRecordID: codec.vehicleToCKRecord(remoteOwner).recordID)
        let removedID = rows[20].id
        let result = try CloudReconciliationService(codec: codec).stageRemoteChanges(
            changedRecords: [incoming],
            deletedRecordIDs: [CKRecord.ID(recordName: removedID.uuidString, zoneID: zoneID)], context: context)
        XCTAssertEqual(result.affectedVehicleIDs, [owner.id])
        context.processPendingChanges()
        let dirty = Set(context.changedModelsArray.compactMap { ($0 as? FuelingRecord)?.id })
        XCTAssertTrue(dirty.isSubset(of: [removedID, rows[21].id, rows[40].id, rows[41].id]))
        XCTAssertTrue(dirty.contains(rows[40].id))
        XCTAssertEqual(rows[40].fuelAmount, 12)
        XCTAssertEqual(rows[41].cachedDistanceDriven, 290)
        XCTAssertEqual(rows[21].cachedDistanceDriven, 600)
        try context.save()
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<FuelingRecord>()), 79)
    }

    func testNotesOnlyDownloadPreservesStatisticsAndNumericBitsAfterSave() throws {
        let (context, record) = try fixture()
        StatisticsCacheService.recalculateAllStatistics(for: record.vehicle)
        try context.save()
        let cacheDate = record.vehicle.cacheLastUpdated
        let bits = [
            record.odometer.bitPattern, record.fuelAmount.bitPattern, record.pricePerFuelUnit.bitPattern,
            record.totalCost.bitPattern,
        ]
        let codec = CloudRecordCodec(zoneID: zoneID)
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = "Updated note"
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = newerDate
        let result = try CloudReconciliationService(codec: codec).applyRemoteChanges(
            changedRecords: [incoming], deletedRecordIDs: [], context: context)
        XCTAssertTrue(result.affectedVehicleIDs.isEmpty)
        XCTAssertEqual(result.indexedVehicleCount, 1)
        XCTAssertEqual(result.indexedFuelingRecordCount, 1)
        let reread = try XCTUnwrap(ModelContext(context.container).fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(reread.notes, "Updated note")
        XCTAssertEqual(reread.vehicle.cacheLastUpdated, cacheDate)
        XCTAssertEqual(
            [
                reread.odometer.bitPattern, reread.fuelAmount.bitPattern, reread.pricePerFuelUnit.bitPattern,
                reread.totalCost.bitPattern,
            ], bits)
    }

    func testChangesToEveryStatisticsInputStillRebuildTheAffectedHistory() throws {
        let changes: [(FuelingRecord) -> Void] = [
            { $0.odometer += 100 }, { $0.date.addTimeInterval(100) },
            { $0.pricePerFuelUnit += 1 }, { $0.fuelAmount += 1 },
            { $0.totalCost += 1 }, { $0.fillUpType = .partial },
        ]
        for change in changes {
            let (context, record) = try fixture()
            record.vehicle.cacheLastUpdated = originalDate
            try context.save()
            let codec = CloudRecordCodec(zoneID: zoneID)
            change(record)
            record.modifiedAt = newerDate
            let incoming = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
            context.rollback()
            let result = try CloudReconciliationService(codec: codec).applyRemoteChanges(
                changedRecords: [incoming], deletedRecordIDs: [], context: context)
            XCTAssertEqual(result.affectedVehicleIDs, [record.vehicle.id])
            XCTAssertNotEqual(record.vehicle.cacheLastUpdated, originalDate)
        }
    }

    func testDeletionLoadsTheExistingOwnerAndRebuildsItsRemainingHistory() throws {
        let (context, record) = try fixture()
        let owner = record.vehicle
        let unrelated = Vehicle(name: "Unrelated")
        context.insert(unrelated)
        try context.save()
        let result = try CloudReconciliationService(codec: CloudRecordCodec(zoneID: zoneID)).applyRemoteChanges(
            changedRecords: [], deletedRecordIDs: [CKRecord.ID(recordName: record.id.uuidString, zoneID: zoneID)],
            context: context)
        XCTAssertEqual(result.indexedFuelingRecordCount, 1)
        XCTAssertEqual(result.indexedVehicleCount, 1)
        XCTAssertEqual(result.affectedVehicleIDs, [owner.id])
        XCTAssertEqual(owner.cachedRecordCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertNil(unrelated.cacheLastUpdated)
    }

    func testEmptyIncrementalApplyBuildsNoLocalIndex() throws {
        let (context, _) = try fixture()
        let result = try CloudReconciliationService(codec: CloudRecordCodec(zoneID: zoneID)).stageRemoteChanges(
            changedRecords: [], deletedRecordIDs: [], context: context)
        XCTAssertEqual(result.indexedVehicleCount, 0)
        XCTAssertEqual(result.indexedFuelingRecordCount, 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testCreateRejectsAnObsoleteDraftStorageBasis() async throws {
        let (context, record) = try fixture()
        var draft = FuelingRecordDraft(date: newerDate, storageUnit: .imperial, inputUnit: .imperial)
        draft.odometerString = "5000"
        draft.edit(.pricePerFuelUnit, input: 3500)
        draft.edit(.fuelAmount, input: 10000)
        let values = try draft.makeValues()
        // Reproduce an explicit legacy-unit repair while Add remains open.
        record.odometer = UnitSystem.metric.distanceValue(record.odometer, from: .imperial)
        record.vehicle.unitSystem = .metric
        try context.save()
        do {
            _ =
                try await FuelingRecordPersistenceService(container: context.container).create(
                    values: values, storageUnit: draft.storageUnit,
                    vehicleID: record.vehicle.id)
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<SyncChange>()), 0)
    }

    func testUploadPreflightRejectsInvalidDataWithoutChangingTheStore() throws {
        let (context, record) = try fixture()
        let service = CloudSyncMappingHarness()
        XCTAssertEqual(try service.prepareUploadSnapshot(in: context).count, 2)
        record.fuelAmount = .infinity
        try context.save()
        XCTAssertThrowsError(try service.prepareUploadSnapshot(in: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(record.odometer, 1000)
        XCTAssertEqual(record.fuelAmount, .infinity)
        XCTAssertEqual(try ModelContext(context.container).fetchCount(FetchDescriptor<SyncChange>()), 0)
    }
}
