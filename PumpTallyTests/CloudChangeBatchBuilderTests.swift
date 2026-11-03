import CloudKit
import SwiftData
import XCTest

@testable import PumpTally

@MainActor
final class CloudChangeBatchBuilderTests: XCTestCase {
    private let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)

    private func context() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func insertRecord(in context: ModelContext) throws -> FuelingRecord {
        let owner = Vehicle(name: "Owner")
        let record = FuelingRecord(
            odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
            fuelAmount: 10.123456789, totalCost: 35.123456789, vehicle: owner)
        context.insert(owner)
        context.insert(record)
        try SyncChangeJournal.enqueue(record, in: context)
        try context.save()
        return record
    }

    private func builder(_ context: ModelContext, blockedParents: Set<String> = []) async -> CloudChangeBatchBuilder {
        await CloudChangeBatchBuilder.make(container: context.container, codec: codec, blockedParents: blockedParents)
    }

    private func id(_ uuid: UUID) -> CKRecord.ID { CKRecord.ID(recordName: uuid.uuidString, zoneID: codec.zoneID) }

    func testOneSaveReadsOnlyItsModelAndSystemFieldsAndDoesNotMutateTheStore() async throws {
        let context = try context()
        let record = try insertRecord(in: context)
        let expected = record.odometer.bitPattern
        let outgoing = codec.fuelingRecordToCKRecord(record, vehicleRecordID: id(record.vehicle.id))
        try SyncPersistenceStore.stageSystemFields(from: outgoing, in: context)
        let unrelated = Vehicle(name: "Unrelated")
        context.insert(unrelated)
        context.insert(CloudRecordMetadata(key: "Vehicle:\(unrelated.id)", systemFieldsData: Data([0, 1])))
        try context.save()
        let preparation = await builder(ModelContext(context.container))
        let prepared = try await preparation.build(
            pendingChanges: [.saveRecord(id(record.id))],
            control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        XCTAssertEqual(prepared?.batch.businessRecordsToSave.count, 1)
        XCTAssertEqual(prepared?.batch.atomicByZone, true)
        XCTAssertEqual(prepared?.batch.recordsToSave.first?.recordType, CloudSyncControl.recordType)
        XCTAssertEqual(
            prepared?.batch.businessRecordsToSave.first?[CloudSyncControl.businessGenerationField] as? String,
            CloudSyncControl.baselineGeneration)
        let asyncResult1 = (await preparation.metrics).journalEntriesRead
        XCTAssertEqual(asyncResult1, 1)
        let asyncResult2 = (await preparation.metrics).vehiclesRead
        XCTAssertEqual(asyncResult2, 0)
        let asyncResult3 = (await preparation.metrics).fuelingRecordsRead
        XCTAssertEqual(asyncResult3, 1)
        let asyncResult4 = (await preparation.metrics).metadataRead
        XCTAssertEqual(asyncResult4, 1)
        let asyncResult5 = (await preparation.metrics).recordsEncoded
        XCTAssertEqual(asyncResult5, 1)
        XCTAssertEqual(
            prepared?.batch.businessRecordsToSave.first?[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer]
                as? Double,
            record.odometer)
        XCTAssertEqual(record.odometer.bitPattern, expected)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 2)
    }

    func testDeletesNeedOnlyVerifiedIntentAndNoBusinessModels() async throws {
        let context = try context()
        let uuid = UUID()
        try SyncChangeJournal.enqueue(
            recordName: uuid.uuidString, recordType: .vehicle, operation: .delete, in: context)
        try context.save()
        let preparation = await builder(context)
        let prepared = try await preparation.build(
            pendingChanges: [.deleteRecord(id(uuid))],
            control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        XCTAssertEqual(prepared?.batch.recordIDsToDelete, [id(uuid)])
        XCTAssertEqual(prepared?.generations.count, 1)
        let asyncResult6 =
            (await preparation.metrics).vehiclesRead + (await preparation.metrics).fuelingRecordsRead
            + (await preparation.metrics).metadataRead
        XCTAssertEqual(asyncResult6, 0)
        let asyncResult7 = (await preparation.metrics).recordsEncoded
        XCTAssertEqual(asyncResult7, 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testUnverifiedDeletesAndSupersededOperationsCannotBeSent() async throws {
        let context = try context()
        let record = try insertRecord(in: context)
        let legacy = SyncChange(recordName: UUID().uuidString, recordTypeRaw: "Vehicle", operationRaw: "delete")
        legacy.originRaw = nil
        context.insert(legacy)
        try context.save()
        let preparation = await builder(context)
        let batch = try await preparation.build(pendingChanges: [
            .deleteRecord(id(record.id)), .deleteRecord(id(try XCTUnwrap(UUID(uuidString: legacy.recordName)))),
            ], control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        XCTAssertNil(batch)
        let asyncResult8 = (await preparation.metrics).recordsEncoded
        XCTAssertEqual(asyncResult8, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 2)
    }

    func testQuarantinedParentBlocksItsChildren() async throws {
        let context = try context()
        let record = try insertRecord(in: context)
        try SyncChangeJournal.enqueue(record.vehicle, in: context)
        try context.save()
        let preparation = await builder(context, blockedParents: [record.vehicle.id.uuidString])
        let batch = try await preparation.build(pendingChanges: [
            .saveRecord(id(record.vehicle.id)), .saveRecord(id(record.id)),
            ], control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        XCTAssertNil(batch)
        let asyncResult9 = (await preparation.metrics).recordsEncoded
        XCTAssertEqual(asyncResult9, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 2)
    }

    func testMissingModelRetainsItsIntent() async throws {
        let context = try context()
        let uuid = UUID()
        try SyncChangeJournal.enqueue(
            recordName: uuid.uuidString, recordType: .fuelingRecord, operation: .save, in: context)
        try context.save()
        let batch = try await builder(context).build(
            pendingChanges: [.saveRecord(id(uuid))],
            control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        XCTAssertNil(batch)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testCorruptRequestedSystemFieldsFailPreparationWithoutDroppingIntent() async throws {
        let context = try context()
        let record = try insertRecord(in: context)
        context.insert(CloudRecordMetadata(key: "FuelingRecord:\(record.id)", systemFieldsData: Data([0, 1])))
        try context.save()
        do {
            _ = try await builder(context).build(
                pendingChanges: [.saveRecord(id(record.id))],
                control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
            XCTFail("Corrupt metadata must pause the send")
        } catch {}
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
        XCTAssertFalse(context.hasChanges)
    }

    func testSystemFieldsForAnotherRecordAreRejected() async throws {
        let context = try context()
        let record = try insertRecord(in: context)
        let other = CKRecord(recordType: "FuelingRecord", recordID: id(UUID()))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        other.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        context.insert(CloudRecordMetadata(key: "FuelingRecord:\(record.id)", systemFieldsData: archiver.encodedData))
        try context.save()
        do {
            _ = try await builder(context).build(
                pendingChanges: [.saveRecord(id(record.id))],
                control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
            XCTFail("Metadata must belong to the requested record")
        } catch {}
        XCTAssertFalse(context.hasChanges)
    }

    func testOnlySDKSelectedRecordsAreEncodedAndHaveCapturedGenerations() async throws {
        let context = try context()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for index in 0..<800 {
            let vehicle = Vehicle(name: "Vehicle \(index)")
            context.insert(vehicle)
            try SyncChangeJournal.enqueue(vehicle, in: context)
            pending.append(.saveRecord(id(vehicle.id)))
        }
        try context.save()
        let preparation = await builder(context)
        let result = try await preparation.build(
            pendingChanges: pending, control: CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID))
        let prepared = try XCTUnwrap(result)
        let saved = prepared.batch.businessRecordsToSave
        XCTAssertGreaterThan(saved.count, 0)
        XCTAssertLessThan(saved.count, pending.count, "The native initializer must exercise a bounded batch")
        let asyncResult10 = (await preparation.metrics).recordsEncoded
        XCTAssertEqual(asyncResult10, saved.count)
        let asyncResult11 = (await preparation.metrics).vehiclesRead
        XCTAssertEqual(asyncResult11, saved.count)
        XCTAssertEqual(Set(prepared.generations.keys), Set(saved.map { "Vehicle:\($0.recordID.recordName)" }))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 800)
        XCTAssertFalse(context.hasChanges)
    }
}
