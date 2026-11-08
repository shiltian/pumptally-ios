import CloudKit
import SwiftData
import XCTest

@testable import PumpTally

@MainActor
final class SyncSafetyTests: XCTestCase {
    private enum Failure: Error { case diskFull }
    private let t1 = Date(timeIntervalSince1970: 1_000_000)
    private let t2 = Date(timeIntervalSince1970: 2_000_000)
    private let t3 = Date(timeIntervalSince1970: 3_000_000)

    func testRecoveryAssessmentLeavesOrdinarySyncWorkAutomatic() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        try await SyncPersistenceStore(container: container).capture(
            modifications: [
                codec.vehicleToCKRecord(record.vehicle),
                codec.fuelingRecordToCKRecord(
                    record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID),
            ], deletions: [])
        let assessment = try SyncReviewService.assessment(in: context)
        XCTAssertTrue(assessment.unitConfirmations.isEmpty)
        XCTAssertTrue(assessment.diagnostics.isEmpty)
        XCTAssertEqual(assessment.legacyDeletionCount, 0)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 2)
        XCTAssertFalse(context.hasChanges)
    }

    func testRecoveryAssessmentSeparatesMalformedChangesFromUnitDecisions() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let legacy = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        legacy[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
        legacy[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
        let malformed = CKRecord(
            recordType: "FuelingRecord",
            recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: legacy.recordID.zoneID))
        try await SyncPersistenceStore(container: container).capture(modifications: [legacy, malformed], deletions: [])

        let assessment = try SyncReviewService.assessment(in: context)
        XCTAssertEqual(assessment.unitConfirmations.map(\.recordID), [legacy.recordID])
        XCTAssertEqual(assessment.diagnostics.map(\.reason), [.malformedRecord])
        let row = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<PendingRemoteChange>()).first {
                $0.key.contains(malformed.recordID.recordName)
            })
        let forgedDecision = SyncReviewService.Item(id: row.key, record: malformed, archivedPayload: row.recordData)
        do {
            _ =
                try await SyncReviewService.confirm(
                    forgedDecision, sourceUnit: .metric, writer: OwnedModelStore(container: context.container))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 2)
        XCTAssertEqual(record.odometer, 1000)
        XCTAssertFalse(context.hasChanges)
    }

    func testUnreadableChangeDoesNotHideOtherRecoveryActionsOrGetDiscarded() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let legacy = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        legacy[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
        legacy[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
        try await SyncPersistenceStore(container: container).capture(modifications: [legacy], deletions: [])
        let unreadable = Data("unreadable original change".utf8)
        context.insert(PendingRemoteChange(key: "damaged-change", recordData: unreadable))
        let deletion = SyncChange(recordName: UUID().uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        deletion.originRaw = nil
        context.insert(deletion)
        try context.save()

        let assessment = try SyncReviewService.assessment(in: context)
        XCTAssertEqual(assessment.unitConfirmations.count, 1)
        XCTAssertEqual(assessment.diagnostics.map(\.reason), [.unreadableChange])
        XCTAssertEqual(assessment.legacyDeletionCount, 1)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<PendingRemoteChange>()).first {
                $0.key == "damaged-change"
            }?.recordData, unreadable)
    }

    func testUnsupportedAndMalformedMeasurementFormatsCannotBeConfirmedAsLegacyUnits() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        let field = CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements
        let data = try XCTUnwrap(incoming[field] as? Data)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        future["version"] = 2
        incoming[field] = try JSONSerialization.data(withJSONObject: future)
        let persistence = SyncPersistenceStore(container: container)
        try await persistence.capture(modifications: [incoming], deletions: [])
        XCTAssertEqual(try SyncReviewService.assessment(in: context).diagnostics.map(\.reason), [.unsupportedFormat])
        XCTAssertTrue(try SyncReviewService.items(in: context).isEmpty)

        incoming[field] = "invalid payload type"
        try await persistence.capture(modifications: [incoming], deletions: [])
        XCTAssertEqual(try SyncReviewService.assessment(in: context).diagnostics.map(\.reason), [.malformedRecord])
        XCTAssertTrue(try SyncReviewService.items(in: context).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(record.odometer, 1000)
    }

    func testMissingVehicleNeedsDiagnosisRatherThanUnitConfirmation() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        context.delete(record.vehicle)
        try context.save()
        try await SyncPersistenceStore(container: container).capture(modifications: [incoming], deletions: [])
        let assessment = try SyncReviewService.assessment(in: context)
        XCTAssertTrue(assessment.unitConfirmations.isEmpty)
        XCTAssertEqual(assessment.diagnostics.map(\.reason), [.missingVehicle])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }

    func testParentUnitsMustBeConfirmedBeforeChildrenBecomeActionable() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let parent = codec.vehicleToCKRecord(record.vehicle)
        parent[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] = "metric"
        let incoming = codec.fuelingRecordToCKRecord(record, vehicleRecordID: parent.recordID)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 2200.0
        try await SyncPersistenceStore(container: container).capture(modifications: [parent, incoming], deletions: [])

        let parentItem = try XCTUnwrap(SyncReviewService.items(in: context).first)
        XCTAssertEqual(parentItem.recordID, parent.recordID)
        XCTAssertEqual(try SyncReviewService.items(in: context).count, 1)
        try await SyncReviewService.confirm(
            parentItem, sourceUnit: .metric, writer: OwnedModelStore(container: context.container))
        let saved = ModelContext(container)
        let updated = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(updated.vehicle.unitSystem, .metric)
        XCTAssertEqual(updated.odometer, UnitSystem.metric.distanceValue(1000, from: .imperial))
        XCTAssertEqual(try SyncReviewService.items(in: context).map(\.recordID), [incoming.recordID])
    }

    func testVerifiedSignInPreservesCheckpointInboxAndPendingChanges() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        try SyncChangeJournal.enqueue(record, in: context)
        try context.save()
        let persistence = SyncPersistenceStore(container: container)
        try await persistence.prepare(accountID: "verified-account")
        let checkpoint = Data("last committed checkpoint".utf8)
        try await persistence.saveEncodedState(checkpoint)
        let incoming = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test")).vehicleToCKRecord(record.vehicle)
        try await persistence.capture(modifications: [incoming], deletions: [])

        let asyncResult1 = try await persistence.isVerifiedSignIn(
            .signIn(currentUser: CKRecord.ID(recordName: "verified-account")))
        XCTAssertTrue(asyncResult1)

        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SyncCheckpoint>()).first?.engineState, checkpoint)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<SyncChange>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<FuelingRecord>()).first?.odometer, record.odometer)
    }

    func testUnverifiedSignInRequiresExplicitActivation() async throws {
        let container = try store()
        let persistence = SyncPersistenceStore(container: container)
        let signIn = CKSyncEngine.Event.AccountChange.ChangeType.signIn(
            currentUser: CKRecord.ID(recordName: "other-account"))
        let asyncResult2 = try await persistence.isVerifiedSignIn(signIn)
        XCTAssertFalse(asyncResult2)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<SyncCheckpoint>()), 0)

        try await persistence.prepare(accountID: "verified-account")
        let asyncResult3 = try await persistence.isVerifiedSignIn(signIn)
        XCTAssertFalse(asyncResult3)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, "verified-account")
    }

    func testSignOutAndAccountSwitchRequireActivationEvenWhenSwitchingBack() async throws {
        let container = try store()
        let persistence = SyncPersistenceStore(container: container)
        try await persistence.prepare(accountID: "verified-account")
        let verified = CKRecord.ID(recordName: "verified-account")
        let other = CKRecord.ID(recordName: "other-account")

        let asyncResult4 = try await persistence.isVerifiedSignIn(.signOut(previousUser: verified))
        XCTAssertFalse(asyncResult4)
        let asyncResult5 = try await persistence.isVerifiedSignIn(
            .switchAccounts(previousUser: verified, currentUser: other))
        XCTAssertFalse(asyncResult5)
        let asyncResult6 = try await persistence.isVerifiedSignIn(
            .switchAccounts(previousUser: other, currentUser: verified))
        XCTAssertFalse(asyncResult6)
        XCTAssertEqual(
            try ModelContext(container).fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, verified.recordName)
    }

    func testLegacyInboxKeyIsNormalizedWithoutDuplicatingTheRecord() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let incoming = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test")).vehicleToCKRecord(record.vehicle)
        context.insert(
            PendingRemoteChange(
                key: incoming.recordID.recordName,
                recordData: try CloudRecordCodec.archiveFullRecord(incoming)))
        try context.save()
        incoming[CloudRecordCodec.CloudFieldKey.Vehicle.name] = "Latest copy"
        try await SyncPersistenceStore(container: container).capture(modifications: [incoming], deletions: [])
        let fresh = ModelContext(container)
        let entries = try fresh.fetch(FetchDescriptor<PendingRemoteChange>())
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.key, "Vehicle:\(incoming.recordID.recordName)")
        let payload = try SyncPersistenceStore.PendingPayload.decode(entry.recordData)
        XCTAssertEqual(try payload.record()?[CloudRecordCodec.CloudFieldKey.Vehicle.name] as? String, "Latest copy")
    }

    func testInboxAndCheckpointSurviveDiskContainerReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.store")
        let schema = Schema(versionedSchema: SchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let checkpoint = Data("opaque committed engine state".utf8)
        var recordName = ""
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
            let context = ModelContext(container)
            let record = try fixture(context)
            let incoming = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test")).vehicleToCKRecord(record.vehicle)
            recordName = incoming.recordID.recordName
            let store = SyncPersistenceStore(container: container)
            try await store.prepare(accountID: "fixture-account")
            try await store.capture(modifications: [incoming], deletions: [])
            try await store.saveEncodedState(checkpoint)
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(reopened)
        let state = try XCTUnwrap(context.fetch(FetchDescriptor<SyncCheckpoint>()).first)
        XCTAssertEqual(state.engineState, checkpoint)
        XCTAssertEqual(state.accountID, "fixture-account")
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<PendingRemoteChange>()).first)
        let payload = try SyncPersistenceStore.PendingPayload.decode(entry.recordData)
        XCTAssertEqual(try payload.record()?.recordID.recordName, recordName)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
    }

    func testDisableKeepLocalPersistsDetachedReceiptAndPreservesPendingWork() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        try SyncChangeJournal.enqueue(record, in: context)
        try context.save()
        let name = "SyncSafety.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = SyncStateManager(defaults: defaults)
        state.iCloudSyncEnabled = true
        state.initialSyncCompleted = true
        try await CloudSyncService(writer: OwnedModelStore(container: container), stateManager: state).disable(
            .keepLocalData)
        XCTAssertFalse(state.iCloudSyncEnabled)
        let asyncResult2 = try await SyncPersistenceStore(container: container).isDetached
        XCTAssertTrue(asyncResult2)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testExplicitActivationResetsOldEngineStateAfterInitialReconciliation() async throws {
        let container = try store()
        let state = SyncPersistenceStore(container: container)
        try await state.prepare(accountID: "same-account")
        try await state.saveEncodedState(Data("old engine pending changes".utf8))
        try await state.markBootstrapped()
        try await state.detach()
        try await state.activate(accountID: "same-account", reconciling: { _ in })
        let fresh = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<SyncCheckpoint>()).first)
        XCTAssertNil(fresh.engineState)
        XCTAssertTrue(fresh.bootstrapCompleted == true)
        let asyncResult3 = try await SyncPersistenceStore(container: container).isDetached
        XCTAssertFalse(asyncResult3)
    }

    func testConfirmingOldReviewSnapshotCannotDiscardNewIncomingPayload() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
        let persistence = SyncPersistenceStore(container: container)
        try await persistence.capture(modifications: [incoming], deletions: [])
        let oldItem = try XCTUnwrap(SyncReviewService.items(in: context).first)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1400.0
        try await persistence.capture(modifications: [incoming], deletions: [])
        do {
            _ =
                try await SyncReviewService.confirm(
                    oldItem, sourceUnit: .imperial, writer: OwnedModelStore(container: context.container))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(record.odometer, 1000)
        XCTAssertEqual(try SyncReviewService.items(in: context).first?.odometer, 1400)
    }

    func testExplicitLegacyMeasurementConfirmationPreservesAndAppliesItsUnits() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let incoming = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 2092.1472
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] = 37.8541
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = t3
        try await SyncPersistenceStore(container: container).capture(modifications: [incoming], deletions: [])
        let item = try XCTUnwrap(SyncReviewService.items(in: context).first)
        try await SyncReviewService.confirm(
            item, sourceUnit: .metric, writer: OwnedModelStore(container: context.container))
        let saved = ModelContext(container)
        let updated = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(updated.odometer, UnitSystem.imperial.distanceValue(2092.1472, from: .metric))
        XCTAssertEqual(updated.vehicle.unitSystem, .imperial)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testRejectingLegacyDeletionKeepsDataAndRemovesOnlyUnverifiedRequests() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let old = SyncChange(recordName: record.id.uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        old.originRaw = nil
        context.insert(old)
        try SyncChangeJournal.enqueue(record.vehicle, in: context)
        try context.save()
        try await SyncReviewService.resolveLegacyDeletions(
            apply: false, writer: OwnedModelStore(container: context.container))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        let remaining = try context.fetch(FetchDescriptor<SyncChange>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.operationRaw, "save")
    }

    func testConfirmedLegacyDeletionRemovesDataAndRetainsVerifiedIntent() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let old = SyncChange(recordName: record.id.uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        old.originRaw = nil
        context.insert(old)
        try context.save()
        try await SyncReviewService.resolveLegacyDeletions(
            apply: true, writer: OwnedModelStore(container: context.container))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SyncChange>()).first?.originRaw, "confirmed")
    }

    func testFailedLocalEvictionKeepsWholeStoreIntact() async throws {
        let container = try store()
        let context = ModelContext(container)
        _ = try fixture(context)
        let failing = SyncPersistenceStore(container: container, commit: { _ in throw Failure.diskFull })
        do {
            _ = try await failing.removeLocalCopy()
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Vehicle>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<SyncChange>()), 0)
    }

    func testAccountChangeCannotReuseCheckpointOrDiscardPendingInboundChanges() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let store = SyncPersistenceStore(container: container)
        try await store.prepare(accountID: "first")
        try await store.saveEncodedState(Data("first account checkpoint".utf8))
        let incoming = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test")).vehicleToCKRecord(record.vehicle)
        try await store.capture(modifications: [incoming], deletions: [])
        do {
            _ = try await store.prepare(accountID: "second")
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ =
                try await store.activate(
                    accountID: "second",
                    reconciling: { _ in XCTFail("Account preflight must reject before reconciliation") })
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, "first")
    }

    private func store() throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
    }

    private func fixture(_ context: ModelContext) throws -> FuelingRecord {
        let vehicle = Vehicle(name: "Car", createdAt: t1)
        vehicle.modifiedAt = t1
        let record = FuelingRecord(
            date: t1, odometer: 1000, pricePerFuelUnit: 3.5,
            fuelAmount: 10, totalCost: 35, createdAt: t1, vehicle: vehicle)
        record.modifiedAt = t1
        context.insert(vehicle)
        context.insert(record)
        try context.save()
        return record
    }

    func testDisplayPreferenceDoesNotRelabelIncomingImperialValuesAsMetricStorage() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let vehicle = record.vehicle
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloudVehicle = codec.vehicleToCKRecord(vehicle)
        record.odometer = 1300
        record.modifiedAt = t3
        let cloudRecord = codec.fuelingRecordToCKRecord(record, vehicleRecordID: cloudVehicle.recordID)
        record.odometer = 1000
        record.modifiedAt = t1
        try context.save()
        let original = VehicleSettingsValues(vehicle: vehicle)
        var proposed = original
        proposed.displayUnit = .metric
        try await VehiclePersistenceService(container: context.container).update(
            vehicleID: vehicle.id, update: VehicleSettingsUpdate(original: original, proposed: proposed))
        let applied = ModelContext(container)
        let updated = try XCTUnwrap(applied.fetch(FetchDescriptor<FuelingRecord>()).first)
        _ = try CloudReconciliationService(codec: codec).applyRemoteChanges(
            changedRecords: [cloudVehicle, cloudRecord], deletedRecordIDs: [], context: applied)
        XCTAssertEqual(updated.vehicle.unitSystem, .imperial)
        XCTAssertEqual(updated.vehicle.displayUnitSystem, .metric)
        XCTAssertEqual(updated.odometer, 1300)
        XCTAssertEqual(updated.fuelAmount, 10)
        XCTAssertEqual(
            updated.vehicle.displayUnitSystem.distanceValue(updated.odometer, from: updated.vehicle.unitSystem),
            Measurement(value: 1300, unit: UnitLength.miles).converted(to: .kilometers).value)
    }

    func testLegacyParentUnitChangeIsPreservedWithoutChangingLocalBasis() throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloud = codec.vehicleToCKRecord(record.vehicle)
        cloud[CloudRecordCodec.CloudFieldKey.Vehicle.unitSystemRaw] = "metric"
        cloud[CloudRecordCodec.CloudFieldKey.Vehicle.modifiedAt] = t3
        let result = try CloudReconciliationService(codec: codec).applyRemoteChanges(
            changedRecords: [cloud], deletedRecordIDs: [], context: context)
        XCTAssertEqual(record.vehicle.unitSystem, .imperial)
        XCTAssertEqual(record.odometer, 1000)
        XCTAssertTrue(result.deferredRecordNames.contains(cloud.recordID.recordName))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }

    func testLegacyWriterCannotRetainAnEnvelopeAndChangeItsNumericMeaning() throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloud = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1609.34
        cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = t3
        let result = try CloudReconciliationService(codec: codec).applyRemoteChanges(
            changedRecords: [cloud], deletedRecordIDs: [], context: context)
        XCTAssertEqual(record.odometer, 1000)
        XCTAssertTrue(result.deferredRecordNames.contains(cloud.recordID.recordName))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }

    func testMissingFuelIsRetainedRatherThanSavedAsZero() throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloud = codec.fuelingRecordToCKRecord(
            record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
        cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] = nil
        cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = t3
        _ = try CloudReconciliationService(codec: codec).applyRemoteChanges(
            changedRecords: [cloud], deletedRecordIDs: [], context: context)
        XCTAssertEqual(record.fuelAmount, 10)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }

    func testNotesEditInMetricDisplayPreservesStoredImperialBits() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        record.fuelAmount = 10.123456789
        record.pricePerFuelUnit = 3.459876543
        try context.save()
        let original = FuelingRecordValues(record: record)
        var draft = FuelingRecordDraft(values: original, storageUnit: .imperial, inputUnit: .metric)
        draft.notes = "Metric display"
        try await FuelingRecordPersistenceService(container: context.container).update(
            recordID: record.id, update: draft.makeUpdate())
        let saved = ModelContext(container)
        let updated = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(updated.notes, "Metric display")
        XCTAssertEqual(updated.odometer.bitPattern, original.odometer.bitPattern)
        XCTAssertEqual(updated.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
        XCTAssertEqual(updated.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let outgoing = codec.fuelingRecordToCKRecord(
            updated, vehicleRecordID: codec.vehicleToCKRecord(updated.vehicle).recordID)
        try codec.validateOutgoing(outgoing)
        let data = try XCTUnwrap(outgoing[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] as? Data)
        let payload = try JSONDecoder().decode(CloudMeasurementPayload.self, from: data)
        XCTAssertEqual(payload.odometer.bitPattern, original.odometer.bitPattern)
        XCTAssertEqual(payload.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
        XCTAssertEqual(payload.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
    }

    func testLocalRemovalCreatesNoRemoteDeleteIntentAndCanReconcileBack() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloudVehicle = codec.vehicleToCKRecord(record.vehicle)
        let cloudRecord = codec.fuelingRecordToCKRecord(record, vehicleRecordID: cloudVehicle.recordID)
        try await SyncPersistenceStore(container: container).removeLocalCopy()
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<SyncChange>()), 0)
        _ = try CloudReconciliationService(codec: codec).reconcileMerge(
            vehicleCKRecords: [cloudVehicle], fuelingCKRecords: [cloudRecord], context: reopened)
        try reopened.save()
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<SyncChange>()), 0)
    }

    func testLocalRemovalPreservesPendingWorkWhenRefused() async throws {
        let container = try store()
        let context = ModelContext(container)
        let record = try fixture(context)
        try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
        try context.save()
        do {
            _ = try await SyncPersistenceStore(container: container).removeLocalCopy()
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testFailedInboxCommitRejectsLaterCheckpointAndRestartReplays() async throws {
        let container = try store()
        let baseline = Data("last durable opaque checkpoint".utf8)
        try await SyncPersistenceStore(container: container).saveEncodedState(baseline)
        let context = ModelContext(container)
        let record = try fixture(context)
        let codec = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test"))
        let cloud = codec.vehicleToCKRecord(record.vehicle)
        let failing = SyncPersistenceStore(container: container, commit: { _ in throw Failure.diskFull })
        do {
            _ = try await failing.capture(modifications: [cloud], deletions: [])
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        do {
            _ = try await failing.saveEncodedState(Data("must not advance".utf8))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        XCTAssertEqual(failing.health, .recoveryRequired)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SyncCheckpoint>()).first?.engineState, baseline)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
        let restarted = SyncPersistenceStore(container: container)
        try await restarted.capture(modifications: [cloud], deletions: [])
        try await restarted.saveEncodedState(Data("replayed checkpoint".utf8))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }

    func testFailedCheckpointCommitLeavesInboxAndPriorCheckpointDurable() async throws {
        let container = try store()
        let baseline = Data("baseline".utf8)
        let healthy = SyncPersistenceStore(container: container)
        try await healthy.saveEncodedState(baseline)
        let context = ModelContext(container)
        let record = try fixture(context)
        let cloud = CloudRecordCodec(zoneID: CKRecordZone.ID(zoneName: "test")).vehicleToCKRecord(record.vehicle)
        try await healthy.capture(modifications: [cloud], deletions: [])
        let failing = SyncPersistenceStore(container: container, commit: { _ in throw Failure.diskFull })
        do {
            _ = try await failing.saveEncodedState(Data("new".utf8))
            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<SyncCheckpoint>()).first?.engineState, baseline)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
    }
}
