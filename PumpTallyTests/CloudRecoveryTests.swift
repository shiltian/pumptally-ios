import CloudKit
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class CloudRecoveryTests: XCTestCase {
    private enum Failure: Error { case interrupted }

    @MainActor private final class Fixture {
        let url: URL
        let container: ModelContainer
        let environment = TestingCloudSyncEnvironment()
        let defaults: UserDefaults
        let vehicleID: UUID
        let recordIDs: [UUID]
        let chosen: [CKRecord]
        let inboxBytes = Data([0, 1, 254, 255])
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)

        init(count: Int = 4) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-\(UUID()).store")
            let schema = Schema(versionedSchema: SchemaV5.self)
            container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            defaults = try XCTUnwrap(UserDefaults(suiteName: "Recovery.\(UUID())"))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let vehicle = Vehicle(name: "Trusted local", createdAt: Date(timeIntervalSince1970: 1_000_000))
            context.insert(vehicle)
            var ids: [UUID] = []
            for index in 0..<count {
                let record = FuelingRecord(
                    date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 86_400),
                    odometer: 1000.123456789 + Double(index) * 300, pricePerFuelUnit: 3.459876543,
                    fuelAmount: 10.123456789, totalCost: 35.123456789, notes: "Trusted \(index)",
                    createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
                record.modifiedAt = Date(timeIntervalSince1970: 2_000_000)
                context.insert(record)
                try SyncChangeJournal.enqueue(record, in: context)
                ids.append(record.id)
            }
            context.processPendingChanges()
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            let checkpoint = SyncCheckpoint(key: "FuelioZone.private")
            checkpoint.accountID = environment.userID
            checkpoint.bootstrapCompleted = true
            checkpoint.cloudGeneration = CloudSyncControl.baselineGeneration
            context.insert(checkpoint)
            context.insert(PendingRemoteChange(key: "unreadable-old-inbox", recordData: inboxBytes))
            try context.save()
            vehicleID = vehicle.id
            recordIDs = ids
            chosen = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: context)
            environment.records.vehicles = [codec.vehicleToCKRecord(vehicle)]
            environment.records.fuelingRecords = chosen.filter {
                $0.recordType == CloudRecordCodec.RecordType.fuelingRecord
            }.map {
                let copy = $0.copy() as! CKRecord
                copy[CloudRecordCodec.CloudFieldKey.FuelingRecord.totalCost] = 0.0
                copy[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 9_000_000)
                return copy
            }
            let extra = CKRecord(
                recordType: "UnknownOldData", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: codec.zoneID)
            )
            extra["value"] = "Original cloud bytes"
            environment.records.otherRecords = [extra]
        }

        func service(
            commit: @escaping OwnedModelStore.Commit = { try $0.modelContext.save() },
            container override: ModelContainer? = nil
        ) -> CloudSyncService {
            let writer = OwnedModelStore(container: override ?? container)
            let state = SyncStateManager(defaults: defaults)
            state.iCloudSyncEnabled = true
            state.initialSyncCompleted = true
            return CloudSyncService(
                writer: writer, stateManager: state, environment: environment,
                makePersistenceStore: { SyncPersistenceStore(writer: $0, commit: commit) })
        }

        func reopen() throws -> ModelContainer {
            let schema = Schema(versionedSchema: SchemaV5.self)
            return try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        }

        func phase() throws -> String? {
            try ModelContext(container).fetch(FetchDescriptor<CloudRecoveryReceipt>()).first?.phaseRaw
        }

        func fingerprint() throws -> [UUID: [String]] {
            try Dictionary(
                uniqueKeysWithValues: ModelContext(container).fetch(FetchDescriptor<FuelingRecord>()).map { record in
                    (
                        record.id,
                        [record.odometer, record.pricePerFuelUnit, record.fuelAmount, record.totalCost].map {
                            String($0.bitPattern)
                        }
                            + [record.vehicle.id.uuidString, record.notes ?? "nil", record.fillUpTypeRaw]
                    )
                })
        }

        func assertPublished(file: StaticString = #filePath, line: UInt = #line) throws {
            let control = try CloudSyncControl(record: XCTUnwrap(environment.records.control), zone: codec.zoneID)
            XCTAssertEqual(control.phase, .ready, file: file, line: line)
            XCTAssertEqual(environment.records.businessRecords.count, chosen.count, file: file, line: line)
            let server = Dictionary(uniqueKeysWithValues: environment.records.businessRecords.map { ($0.recordID, $0) })
            var mismatches: [String] = []
            for original in chosen {
                let actual = try XCTUnwrap(server[original.recordID])
                if try !CloudRecoveryManifest.matches(original, server: actual, generation: control.generation) {
                    if mismatches.isEmpty {
                        let keys = Set(original.allKeys() + actual.allKeys()).sorted()
                        let details = keys.map {
                            "\($0): \(String(describing: original[$0])) -> \(String(describing: actual[$0]))"
                        }
                        print("Recovery mismatch \(original.recordID.recordName): \(details)")
                    }
                    mismatches.append(original.recordID.recordName)
                }
            }
            XCTAssertTrue(
                mismatches.isEmpty, "Mismatched \(mismatches.count) records: \(mismatches.prefix(3))", file: file,
                line: line)
        }
    }

    private func interrupted(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line)
        async
    {
        do {
            try await operation()
            XCTFail("Expected interrupted recovery", file: file, line: line)
        } catch { /* The test verifies the durable state below. */  }
    }

    func testReplacementPreservesLocalBitsPublishesChosenDataAndRetainsOldInbox() async throws {
        let fixture = try Fixture()
        let before = try fixture.fingerprint()
        let service = fixture.service()
        try await service.replaceCloudDataWithLocal()
        try fixture.assertPublished()
        XCTAssertEqual(try fixture.fingerprint(), before)
        let context = ModelContext(fixture.container)
        let receipt = try XCTUnwrap(context.fetch(FetchDescriptor<CloudRecoveryReceipt>()).first)
        XCTAssertEqual(receipt.phaseRaw, "completed")
        let manifest = try JSONDecoder().decode(CloudRecoveryManifest.self, from: receipt.payload)
        XCTAssertEqual(manifest.inbox.first?.data, fixture.inboxBytes)
        let retained = try JSONDecoder().decode(
            [CloudRecoveryManifest.InboxEntry].self, from: XCTUnwrap(receipt.retainedInbox))
        XCTAssertEqual(retained.first?.data, fixture.inboxBytes)
        XCTAssertNotNil(receipt.remoteBackup)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
        XCTAssertEqual(service.stateManager.syncStatus, .synced)
        await service.stopMonitoring()
    }

    func testReceiptIsCommittedBeforeFirstCloudMutation() async throws {
        let fixture = try Fixture()
        var checked = false
        fixture.environment.batchHandler = { _ in
            if !checked {
                XCTAssertEqual(try fixture.phase(), "prepared")
                checked = true
            }
        }
        let service = fixture.service()
        try await service.replaceCloudDataWithLocal()
        XCTAssertTrue(checked)
        await service.stopMonitoring()
    }

    func testPrepareFailureMakesNoCloudMutationAndKeepsEveryLocalValue() async throws {
        let fixture = try Fixture()
        let before = try fixture.fingerprint()
        let service = fixture.service(commit: { actor in
            if try actor.modelContext.fetchCount(FetchDescriptor<CloudRecoveryReceipt>()) > 0 {
                throw Failure.interrupted
            }
            try actor.modelContext.save()
        })
        await interrupted { try await service.replaceCloudDataWithLocal() }
        XCTAssertNil(fixture.environment.records.control)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
        XCTAssertNil(try fixture.phase())
        XCTAssertEqual(try fixture.fingerprint(), before)
    }

    func testResumeAfterEachDurablePhaseSaveFailure() async throws {
        for phase in ["publishing", "verified", "completed"] {
            let fixture = try Fixture()
            let fault = OSAllocatedUnfairLock(initialState: true)
            let before = try fixture.fingerprint()
            let service = fixture.service(commit: { actor in
                let matches = try actor.modelContext.fetch(FetchDescriptor<CloudRecoveryReceipt>()).contains {
                    $0.phaseRaw == phase
                }
                if matches
                    && fault.withLock({ enabled in
                        let result = enabled
                        enabled = false
                        return result
                    })
                {
                    throw Failure.interrupted
                }
                try actor.modelContext.save()
            })
            await interrupted { try await service.replaceCloudDataWithLocal() }
            XCTAssertNotEqual(try fixture.phase(), "completed")
            let restarted = fixture.service(container: try fixture.reopen())
            restarted.stateManager.iCloudSyncEnabled = false
            restarted.stateManager.initialSyncCompleted = false
            try await restarted.resumeRecoveryIfNeeded()
            try fixture.assertPublished()
            XCTAssertEqual(try fixture.phase(), "completed")
            XCTAssertEqual(try fixture.fingerprint(), before)
            await restarted.stopMonitoring()
        }
    }

    func testResumeWhenTheControlReachedCloudBeforeTheClaimAcknowledgement() async throws {
        let fixture = try Fixture()
        var once = true
        fixture.environment.afterBatch = { batch in
            if once && batch.recordsToSave.count == 1 {
                once = false
                throw Failure.interrupted
            }
        }
        let service = fixture.service()
        await interrupted { try await service.replaceCloudDataWithLocal() }
        XCTAssertEqual(try fixture.phase(), "prepared")
        XCTAssertNotNil(fixture.environment.records.control)
        let restarted = fixture.service(container: try fixture.reopen())
        try await restarted.resumeRecoveryIfNeeded()
        try fixture.assertPublished()
        await restarted.stopMonitoring()
    }

    func testLostBusinessAcknowledgementResumes800RecordsWithoutRepeatingAcknowledgedSaves() async throws {
        let fixture = try Fixture(count: 800)
        var once = true
        var acknowledgedIDs = Set<CKRecord.ID>()
        var repeated = Set<CKRecord.ID>()
        var resuming = false
        fixture.environment.batchHandler = { batch in
            if resuming {
                repeated.formUnion(batch.recordsToSave.map(\.recordID).filter { acknowledgedIDs.contains($0) })
            }
        }
        fixture.environment.afterBatch = { batch in
            let records = batch.recordsToSave.filter { $0.recordType != CloudSyncControl.recordType }
            if once && !records.isEmpty {
                once = false
                acknowledgedIDs = Set(records.map(\.recordID))
                throw Failure.interrupted
            }
        }
        let service = fixture.service()
        await interrupted { try await service.replaceCloudDataWithLocal() }
        XCTAssertFalse(acknowledgedIDs.isEmpty)
        XCTAssertEqual(try fixture.phase(), "publishing")
        resuming = true
        let restarted = fixture.service(container: try fixture.reopen())
        try await restarted.resumeRecoveryIfNeeded()
        try fixture.assertPublished()
        XCTAssertTrue(repeated.isEmpty)
        await restarted.stopMonitoring()
    }

    func testLaterLocalEditStaysOutsideTheFrozenSnapshotAndSyncsAfterCompletion() async throws {
        let fixture = try Fixture()
        var once = true
        let id = fixture.recordIDs[1]
        fixture.environment.afterBatch = { batch in
            guard once,
                batch.recordsToSave.contains(where: { $0.recordType == CloudRecordCodec.RecordType.fuelingRecord })
            else { return }
            once = false
            let context = ModelContext(fixture.container)
            let record = try XCTUnwrap(
                context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
            let old = FuelingRecordValues(record: record)
            var new = old
            new.fuelAmount += 0.25
            new.notes = "Edited after the snapshot"
            _ = try await FuelingRecordPersistenceService(writer: OwnedModelStore(container: fixture.container)).update(
                recordID: id, update: FuelingRecordUpdate(original: old, proposed: new))
            throw Failure.interrupted
        }
        await interrupted { try await fixture.service().replaceCloudDataWithLocal() }
        let restarted = fixture.service(container: try fixture.reopen())
        try await restarted.resumeRecoveryIfNeeded()
        let context = ModelContext(fixture.container)
        let local = try XCTUnwrap(
            context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(local.fuelAmount.bitPattern, (10.123456789 + 0.25).bitPattern)
        XCTAssertEqual(local.notes, "Edited after the snapshot")
        let cloud = try XCTUnwrap(
            fixture.environment.records.fuelingRecords.first { $0.recordID.recordName == id.uuidString })
        XCTAssertEqual(
            (cloud[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] as? Double)?.bitPattern,
            local.fuelAmount.bitPattern)
        let receipt = try XCTUnwrap(context.fetch(FetchDescriptor<CloudRecoveryReceipt>()).first)
        let manifest = try JSONDecoder().decode(CloudRecoveryManifest.self, from: receipt.payload)
        let frozen = try XCTUnwrap(manifest.decodedRecords().first { $0.recordID.recordName == id.uuidString })
        XCTAssertEqual(
            (frozen[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] as? Double)?.bitPattern,
            10.123456789.bitPattern)
        await restarted.stopMonitoring()
    }

    func testAccountAndContainerChangesCannotResumeIntoAnotherScope() async throws {
        for changeAccount in [true, false] {
            let fixture = try Fixture()
            fixture.environment.afterBatch = { _ in throw Failure.interrupted }
            await interrupted { try await fixture.service().replaceCloudDataWithLocal() }
            let drivers = fixture.environment.drivers.count
            fixture.environment.afterBatch = nil
            if changeAccount {
                fixture.environment.userID = "different-account"
            } else {
                fixture.environment.scopeIdentifier = "different-container"
            }
            let restarted = fixture.service()
            await interrupted { try await restarted.resumeRecoveryIfNeeded() }
            XCTAssertEqual(fixture.environment.drivers.count, drivers)
            XCTAssertNotEqual(try fixture.phase(), "completed")
        }
    }

    func testNewGenerationSupersedesTheOldReceiptWithoutReplayingItsDeletions() async throws {
        let fixture = try Fixture()
        fixture.environment.afterBatch = { _ in throw Failure.interrupted }
        await interrupted { try await fixture.service().replaceCloudDataWithLocal() }
        fixture.environment.afterBatch = nil
        let control = try CloudSyncControl(
            record: XCTUnwrap(fixture.environment.records.control), zone: fixture.codec.zoneID)
        fixture.environment.records.control = try control.changing(generation: UUID().uuidString, phase: .ready).record
        let before = fixture.environment.records.businessRecords.count
        let drivers = fixture.environment.drivers.count
        let restarted = fixture.service()
        await interrupted { try await restarted.resumeRecoveryIfNeeded() }
        XCTAssertEqual(try fixture.phase(), "superseded")
        XCTAssertEqual(fixture.environment.records.businessRecords.count, before)
        XCTAssertEqual(fixture.environment.drivers.count, drivers)
        XCTAssertFalse(restarted.stateManager.iCloudSyncEnabled)
    }

    func testPendingRecoveryBlocksDisableAndLegacyReviewWithoutDeletingTheReceipt() async throws {
        let fixture = try Fixture()
        fixture.environment.afterBatch = { _ in throw Failure.interrupted }
        let service = fixture.service()
        await interrupted { try await service.replaceCloudDataWithLocal() }
        await interrupted { try await service.disable(.removeLocalCopy) }
        await interrupted {
            try await SyncReviewService.resolveLegacyDeletions(
                apply: false,
                writer: OwnedModelStore(container: fixture.container))
        }
        XCTAssertEqual(try fixture.phase(), "prepared")
        XCTAssertEqual(try fixture.fingerprint().count, 4)
    }

    func testMalformedReceiptCannotMakeCloudMutations() async throws {
        let fixture = try Fixture()
        let context = ModelContext(fixture.container)
        context.insert(
            CloudRecoveryReceipt(
                id: UUID(), scope: fixture.environment.scopeIdentifier, accountID: fixture.environment.userID,
                payload: Data([0, 255])))
        try context.save()
        let before = try fixture.fingerprint()
        await interrupted { try await fixture.service().resumeRecoveryIfNeeded() }
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
        XCTAssertNil(fixture.environment.records.control)
        XCTAssertEqual(try fixture.fingerprint(), before)
        XCTAssertEqual(try fixture.phase(), "prepared")
    }

    func testFailedServerVerificationKeepsReplacementPendingAndNeverReportsSynced() async throws {
        let fixture = try Fixture()
        fixture.environment.afterBatch = { batch in
            guard batch.recordsToSave.contains(where: { $0.recordType == CloudRecordType.fuelingRecord }) else {
                return
            }
            fixture.environment.records.fuelingRecords.first?[CloudRecordCodec.CloudFieldKey.FuelingRecord.totalCost] =
                0.0
        }
        let before = try fixture.fingerprint()
        let service = fixture.service()
        do {
            try await service.replaceCloudDataWithLocal()
            XCTFail("A mismatched server value must prevent activation")
        } catch { XCTAssertEqual(error as? CloudRecoveryError, .verificationFailed) }
        XCTAssertEqual(try fixture.phase(), "publishing")
        let marker = try CloudSyncControl(
            record: XCTUnwrap(fixture.environment.records.control), zone: fixture.codec.zoneID)
        XCTAssertEqual(marker.phase, .replacing)
        XCTAssertNotEqual(service.stateManager.syncStatus, .synced)
        XCTAssertEqual(try fixture.fingerprint(), before)
        fixture.environment.afterBatch = nil
        let restarted = fixture.service(container: try fixture.reopen())
        try await restarted.resumeRecoveryIfNeeded()
        try fixture.assertPublished()
        await restarted.stopMonitoring()
    }

    func testCopiedV4StorePublishes800RecordsWithoutDirtyingBusinessModelsAndReopensUnchanged() async throws {
        let original = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "SchemaV4", withExtension: "store", subdirectory: "Fixtures"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CopiedRecovery-\(UUID()).store")
        try FileManager.default.copyItem(at: original, to: url)
        let schema = Schema(versionedSchema: SchemaV5.self)
        func open() throws -> ModelContainer {
            try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        }
        let container = try open()
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let context = ModelContext(container)
        let chosen = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: context)
        XCTAssertEqual(chosen.count, 802)
        func caches(in context: ModelContext) throws -> [UUID: [UInt64?]] {
            var values: [UUID: [UInt64?]] = [:]
            for r in try context.fetch(FetchDescriptor<FuelingRecord>()) {
                values[r.id] = [
                    r.cachedPreviousOdometer, r.cachedDistanceDriven, r.cachedEfficiency, r.cachedCostPerDistance,
                ]
                .map { $0?.bitPattern }
            }
            for v in try context.fetch(FetchDescriptor<Vehicle>()) {
                values[v.id] = [
                    v.cachedTotalSpent, v.cachedTotalDistance, v.cachedTotalFuel,
                    v.cachedAverageEfficiency, v.cachedAverageCostPerDistance, v.cachedAverageFillUpCost,
                    v.cachedAveragePricePerFuelUnit, v.cachedBestEfficiency, v.cachedWorstEfficiency,
                    v.cachedHighestPricePerFuelUnit, v.cachedLowestPricePerFuelUnit,
                    v.cacheLastUpdated?.timeIntervalSinceReferenceDate,
                ].map { $0?.bitPattern }
            }
            return values
        }
        let before = try caches(in: context)
        let environment = TestingCloudSyncEnvironment()
        environment.userID = "v4-fixture-account"
        let state = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "CopiedRecovery.\(UUID())")))
        let dirtied = OSAllocatedUnfairLock(initialState: false)
        let service = CloudSyncService(
            writer: OwnedModelStore(container: container), stateManager: state,
            environment: environment,
            makePersistenceStore: { writer in
                SyncPersistenceStore(
                    writer: writer,
                    commit: { actor in
                        if actor.modelContext.changedModelsArray.contains(where: {
                            $0 is Vehicle || $0 is FuelingRecord
                        }) {
                            dirtied.withLock { $0 = true }
                        }
                        try actor.modelContext.save()
                    })
            })
        try await service.replaceCloudDataWithLocal()
        await service.stopMonitoring()
        XCTAssertFalse(dirtied.withLock { $0 })
        let reopened = ModelContext(try open())
        XCTAssertEqual(try caches(in: reopened), before)
        let current = try InitialSyncReconciler(codec: codec).uploadSnapshot(in: reopened)
        XCTAssertEqual(current.count, chosen.count)
        let expected = Dictionary(uniqueKeysWithValues: chosen.map { ($0.recordID, $0) })
        for record in current {
            record[CloudSyncControl.businessGenerationField] = "local-comparison"
            XCTAssertTrue(
                try CloudRecoveryManifest.matches(
                    XCTUnwrap(expected[record.recordID]), server: record, generation: "local-comparison"))
        }
    }
}
