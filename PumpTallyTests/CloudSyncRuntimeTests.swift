import CloudKit
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class CloudSyncRuntimeTests: XCTestCase {
    private enum Failure: Error { case diskFull, offline }
    private final class CommitFault: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var enabled: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    @MainActor
    private struct Runtime {
        let container: ModelContainer
        let writer: OwnedModelStore
        let environment: TestingCloudSyncEnvironment
        let service: CloudSyncService
        let recordID: UUID
        let vehicleID: UUID
        let fault: CommitFault

        var state: SyncStateManager { service.stateManager }
        var context: ModelContext { ModelContext(container) }
        var driver: TestingSyncEngineDriver { environment.drivers.last! }
        var cloudID: CKRecord.ID {
            CKRecord.ID(recordName: recordID.uuidString, zoneID: NativeCloudSyncEnvironment.zoneID)
        }

        nonisolated func record(in context: ModelContext) throws -> FuelingRecord {
            let id = recordID
            return try XCTUnwrap(
                context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
        }

        func journal() throws -> [SyncChange] { try context.fetch(FetchDescriptor<SyncChange>()) }

        func edit(notes: String) async throws {
            let id = recordID
            try await writer.transaction { actor in
                let context = actor.modelContext
                let record = try XCTUnwrap(
                    context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
                record.notes = notes
                record.modifiedAt = Date(timeIntervalSince1970: 3_000_000)
                try SyncChangeJournal.enqueue(record, in: context)
            }
        }
    }

    private func runtime(url: URL? = nil) throws -> Runtime {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let configuration =
            url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let vehicle = Vehicle(name: "Runtime fixture", createdAt: Date(timeIntervalSince1970: 1_000_000))
        context.insert(vehicle)
        let record = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_000_000), odometer: 1000.123456789,
            pricePerFuelUnit: 3.459876543, fuelAmount: 10.123456789, totalCost: 35.123456789,
            notes: "baseline", createdAt: Date(timeIntervalSince1970: 1_000_000), vehicle: vehicle)
        context.insert(record)
        try context.save()
        let environment = TestingCloudSyncEnvironment()
        environment.automaticDelivery = false
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        environment.records = CloudSyncSnapshot(
            vehicles: [codec.vehicleToCKRecord(vehicle)],
            fuelingRecords: [
                codec.fuelingRecordToCKRecord(record, vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            ])
        let state = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "Runtime.\(UUID())")))
        state.iCloudSyncEnabled = true
        state.initialSyncCompleted = true
        let fault = CommitFault()
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(
            writer: writer, stateManager: state, environment: environment,
            makePersistenceStore: { writer in
                SyncPersistenceStore(
                    writer: writer,
                    commit: { actor in
                        let context = actor.modelContext
                        if fault.enabled { throw Failure.diskFull }
                        try context.save()
                    })
            })
        return Runtime(
            container: container, writer: writer, environment: environment, service: service,
            recordID: record.id, vehicleID: vehicle.id, fault: fault)
    }

    func testAdvancedGenerationRejectsPreparedOrdinarySaveAndDeleteWithoutAcknowledgingIntent() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let context = runtime.context
        let removed = try runtime.record(in: context)
        try SyncChangeJournal.enqueue(removed, operation: .delete, in: context)
        context.delete(removed)
        let inserted = Vehicle(name: "Later local vehicle")
        context.insert(inserted)
        try SyncChangeJournal.enqueue(inserted, in: context)
        try context.save()
        await runtime.service.pushPendingLocalChanges()
        let before = try runtime.journal().map { $0.key + $0.generation }.sorted()
        runtime.environment.batchHandler = { batch in
            XCTAssertTrue(batch.atomicByZone)
            XCTAssertEqual(batch.recordIDsToDelete, [runtime.cloudID])
            XCTAssertEqual(batch.businessRecordsToSave.map(\.recordID.recordName), [inserted.id.uuidString])
            let replacement = try CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID)
                .changing(generation: UUID().uuidString, phase: .ready).record
            replacement["testServerTag"] = "advanced-on-another-device"
            runtime.environment.records.control = replacement
        }
        runtime.driver.automaticDelivery = true
        try await runtime.driver.sendChanges()
        XCTAssertEqual(try runtime.journal().map { $0.key + $0.generation }.sorted(), before)
        XCTAssertEqual(runtime.environment.records.fuelingRecords.map(\.recordID), [runtime.cloudID])
        XCTAssertFalse(
            runtime.environment.records.vehicles.contains { $0.recordID.recordName == inserted.id.uuidString })
        XCTAssertFalse(runtime.state.iCloudSyncEnabled)
        XCTAssertFalse(runtime.state.initialSyncCompleted)
        guard case .error = runtime.state.syncStatus else { return XCTFail("A changed generation must pause sync") }
    }

    func testNewGenerationInboundDeletionIsRetainedWithoutDeletingLocalData() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let generation = try CloudSyncControl.baseline(in: NativeCloudSyncEnvironment.zoneID)
            .changing(generation: UUID().uuidString, phase: .ready)
        runtime.environment.records.control = generation.record
        await runtime.driver.emit(
            .fetchedRecords(
                modifications: [generation.record],
                deletions: [
                    (recordID: runtime.cloudID, recordType: CloudRecordType.fuelingRecord)
                ]))
        XCTAssertEqual(try runtime.record(in: runtime.context).notes, "baseline")
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 2)
        XCTAssertFalse(runtime.state.iCloudSyncEnabled)
    }

    func testInitialUploadCommitsIntentBeforeAnEngineExists() async throws {
        let runtime = try runtime()
        runtime.state.iCloudSyncEnabled = false
        runtime.state.initialSyncCompleted = false
        runtime.environment.records = CloudSyncSnapshot()
        let proposal = try await runtime.service.prepareInitialSync()
        try await runtime.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try runtime.journal().count, 2)
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
        XCTAssertEqual(runtime.driver.pendingRecordZoneChanges.count, 2)
        let batch = await runtime.driver.batch()
        XCTAssertEqual(batch?.businessRecordsToSave.count, 2)
    }

    func testBackgroundSaveCapturesPushSuppressionBeforeMainRunLoopDelivery() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        XCTAssertTrue(runtime.driver.pendingRecordZoneChanges.isEmpty)
        let registrations = runtime.driver.recordRegistrations.count
        try await runtime.service.withLocalPushesSuspended {
            try await runtime.edit(notes: "suppressed background save")
        }
        let automaticPush = expectation(description: "Suppressed save must not register an automatic push")
        runtime.driver.registrationObserver = { automaticPush.fulfill() }
        automaticPush.isInverted = true
        await fulfillment(of: [automaticPush], timeout: 1.2)
        runtime.driver.registrationObserver = nil
        XCTAssertEqual(runtime.driver.recordRegistrations.count, registrations)
        await runtime.service.pushPendingLocalChanges()
        XCTAssertEqual(runtime.driver.pendingRecordZoneChanges, [.saveRecord(runtime.cloudID)])
    }

    func testInitialMergeCommitsMetadataAndLocalWinnerTogether() async throws {
        let runtime = try runtime()
        try await runtime.edit(notes: "local winner")
        runtime.state.iCloudSyncEnabled = false
        runtime.state.initialSyncCompleted = false
        let proposal = try await runtime.service.prepareInitialSync()
        try await runtime.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 2)
        XCTAssertEqual(try runtime.journal().map(\.recordName), [runtime.recordID.uuidString])
        let batch = await runtime.driver.batch()
        XCTAssertEqual(
            batch?.businessRecordsToSave.first?[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] as? String,
            "local winner")
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
    }

    func testEditDuringSendSurvivesOlderAcknowledgementAndIsRequeued() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "first edit")
        await runtime.service.pushPendingLocalChanges()
        let firstBatch = await runtime.driver.batch()
        _ = try XCTUnwrap(firstBatch?.businessRecordsToSave.first)
        let firstGeneration = try XCTUnwrap(runtime.journal().first?.generation)
        try await runtime.edit(notes: "second edit")
        let secondGeneration = try XCTUnwrap(runtime.journal().first?.generation)
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        runtime.driver.remove(pendingRecordZoneChanges: [.saveRecord(runtime.cloudID)])
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(firstBatch).recordsToSave)))
        XCTAssertEqual(try runtime.journal().first?.generation, secondGeneration)
        XCTAssertEqual(runtime.driver.pendingRecordZoneChanges, [.saveRecord(runtime.cloudID)])
        let secondBatch = await runtime.driver.batch()
        let second = try XCTUnwrap(secondBatch?.businessRecordsToSave.first)
        XCTAssertEqual(second[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] as? String, "second edit")
        runtime.driver.remove(pendingRecordZoneChanges: [.saveRecord(runtime.cloudID)])
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(secondBatch).recordsToSave)))
        XCTAssertTrue(try runtime.journal().isEmpty)
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(secondBatch).recordsToSave)))
        XCTAssertTrue(try runtime.journal().isEmpty)
    }

    func testDeletionDuringSaveIsPreservedAndSentNext() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "save in flight")
        await runtime.service.pushPendingLocalChanges()
        let batch = await runtime.driver.batch()
        _ = try XCTUnwrap(batch?.businessRecordsToSave.first)
        let context = runtime.context
        let record = try runtime.record(in: context)
        try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
        context.delete(record)
        try context.save()
        runtime.driver.remove(pendingRecordZoneChanges: [.saveRecord(runtime.cloudID)])
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(batch).recordsToSave)))
        XCTAssertEqual(try runtime.journal().first?.operationRaw, "delete")
        let deleteBatch = await runtime.driver.batch()
        XCTAssertEqual(deleteBatch?.recordIDsToDelete, [runtime.cloudID])
    }

    func testFetchFailureCannotBeErasedByEitherCompletionEvent() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: CKError(.networkFailure)))
        await runtime.driver.emit(.didFetch)
        await runtime.driver.emit(.willSend)
        await runtime.driver.emit(.didSend)
        guard case .error = runtime.state.syncStatus else { return XCTFail("A failed fetch must remain visible") }
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: nil))
        await runtime.driver.emit(.didFetch)
        XCTAssertEqual(runtime.state.syncStatus, .synced)
    }

    func testFailedSendRemainsVisibleAfterSuccessfulFetch() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        await runtime.driver.emit(.willSend)
        await runtime.driver.emit(.sentZones(errors: [CKError(.permissionFailure)]))
        await runtime.driver.emit(.didSend)
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.didFetch)
        guard case .error = runtime.state.syncStatus else { return XCTFail("Fetch completion erased send failure") }
    }

    func testThrowingExplicitSendRemainsFailedThroughLaterFetch() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        runtime.driver.sendError = Failure.offline
        await runtime.service.synchronizeNow()
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.didFetch)
        guard case .error = runtime.state.syncStatus else { return XCTFail("Thrown send failure was lost") }
    }

    func testEmptyQueuesWithoutFetchDoNotReportSynced() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        await runtime.driver.emit(.didSend)
        await runtime.driver.emit(.didFetch)
        await runtime.driver.emit(.checkpoint(Data("no successful fetch yet".utf8)))
        XCTAssertNotEqual(runtime.state.syncStatus, .synced)
        runtime.driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: NativeCloudSyncEnvironment.zoneID))])
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.didFetch)
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
    }

    func testInboxFailureInvalidatesSessionBeforeCheckpointCanAdvance() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let driver = runtime.driver
        runtime.fault.enabled = true
        await driver.emit(.fetchedRecords(modifications: runtime.environment.records.fuelingRecords, deletions: []))
        runtime.fault.enabled = false
        await driver.emit(.checkpoint(Data("must not advance".utf8)))
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
        let asyncResult1 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult1)
        let obsoleteBatch = await driver.batch()
        XCTAssertNil(obsoleteBatch)
        await runtime.service.startMonitoring()
        XCTAssertEqual(runtime.environment.drivers.count, 2)
    }

    func testCheckpointFailureKeepsInboxDurableAndRejectsLaterEvents() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let driver = runtime.driver
        await driver.emit(.fetchedRecords(modifications: runtime.environment.records.fuelingRecords, deletions: []))
        runtime.fault.enabled = true
        await driver.emit(.checkpoint(Data("unsaved checkpoint".utf8)))
        runtime.fault.enabled = false
        await driver.emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: nil))
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        let asyncResult2 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult2)
        await runtime.service.startMonitoring()
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
    }

    func testAcknowledgementFailureRetainsJournalAndInvalidatesSession() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "keep me")
        await runtime.service.pushPendingLocalChanges()
        let batch = await runtime.driver.batch()
        _ = try XCTUnwrap(batch?.businessRecordsToSave.first)
        runtime.fault.enabled = true
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(batch).recordsToSave)))
        runtime.fault.enabled = false
        XCTAssertEqual(try runtime.journal().count, 1)
        await runtime.driver.emit(.checkpoint(Data("late checkpoint".utf8)))
        let asyncResult3 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult3)
    }

    func testStoppedDriverCannotAcknowledgeNewSessionWork() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let obsolete = runtime.driver
        await runtime.service.stopMonitoring()
        try await runtime.edit(notes: "new session")
        await runtime.service.startMonitoring()
        await obsolete.emit(.checkpoint(Data("obsolete".utf8)))
        await obsolete.emit(.sentRecords(.init(savedRecords: runtime.environment.records.fuelingRecords)))
        let asyncResult4 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult4)
        XCTAssertEqual(try runtime.journal().count, 1)
        XCTAssertEqual(obsolete.cancellations, 1)
    }

    func testAccountConfirmationContinuesButSwitchImmediatelyInvalidatesSession() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let driver = runtime.driver
        await driver.emit(.accountChanged(.signIn(currentUser: CKRecord.ID(recordName: runtime.environment.userID))))
        XCTAssertTrue(runtime.state.iCloudSyncEnabled)
        await driver.emit(
            .accountChanged(
                .switchAccounts(
                    previousUser: CKRecord.ID(recordName: runtime.environment.userID),
                    currentUser: CKRecord.ID(recordName: "other"))))
        await driver.emit(.checkpoint(Data("wrong account".utf8)))
        XCTAssertFalse(runtime.state.iCloudSyncEnabled)
        XCTAssertFalse(runtime.state.initialSyncCompleted)
        let asyncResult5 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult5)
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        // Returning to the prior account still requires a new source choice.
        try await runtime.service.resumeRecoveryIfNeeded()
        XCTAssertFalse(runtime.state.iCloudSyncEnabled)
        XCTAssertFalse(runtime.state.initialSyncCompleted)
    }

    func testStartupZoneFailureNeverStartsAnEngineOrChangesBusinessValues() async throws {
        let runtime = try runtime()
        runtime.environment.zoneError = CKError(.permissionFailure)
        await runtime.service.startMonitoring()
        XCTAssertTrue(runtime.environment.drivers.isEmpty)
        XCTAssertEqual(try runtime.record(in: runtime.context).odometer.bitPattern, 1000.123456789.bitPattern)
        guard case .error = runtime.state.syncStatus else { return XCTFail("Startup failure not visible") }
    }

    func testScopedBatchDoesNotSendUnverifiedLegacyDeletion() async throws {
        let runtime = try runtime()
        let context = runtime.context
        let legacyID = CKRecord.ID(recordName: UUID().uuidString, zoneID: NativeCloudSyncEnvironment.zoneID)
        let legacy = SyncChange(recordName: legacyID.recordName, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        legacy.originRaw = nil
        context.insert(legacy)
        try context.save()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "eligible")
        await runtime.service.pushPendingLocalChanges()
        runtime.driver.add(pendingRecordZoneChanges: [.deleteRecord(legacyID)])
        let excluded = await runtime.driver.batch(scope: .recordIDs([legacyID]))
        XCTAssertNil(excluded)
        let included = await runtime.driver.batch(scope: .recordIDs([runtime.cloudID]))
        XCTAssertEqual(included?.businessRecordsToSave.map(\.recordID), [runtime.cloudID])
        XCTAssertTrue(included?.recordIDsToDelete.isEmpty == true)
    }

    func testMalformedConflictRetainsBothOutboxAndEvidence() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "trusted local")
        await runtime.service.pushPendingLocalChanges()
        let batch = await runtime.driver.batch()
        let submitted = try XCTUnwrap(batch?.businessRecordsToSave.first)
        let malformed = CKRecord(recordType: "FuelingRecord", recordID: runtime.cloudID)
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: malformed])
        await runtime.driver.emit(.sentRecords(.init(failedSaves: [(submitted, conflict)])))
        XCTAssertEqual(try runtime.journal().count, 1)
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(try runtime.record(in: runtime.context).notes, "trusted local")
    }

    func testUnknownItemDeleteAcknowledgesOnlySubmittedGeneration() async throws {
        let runtime = try runtime()
        let context = runtime.context
        let record = try runtime.record(in: context)
        try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
        context.delete(record)
        try context.save()
        await runtime.service.startMonitoring()
        let batch = await runtime.driver.batch()
        XCTAssertEqual(batch?.recordIDsToDelete, [runtime.cloudID])
        await runtime.driver.emit(.sentRecords(.init(failedDeletes: [runtime.cloudID: CKError(.unknownItem)])))
        XCTAssertTrue(try runtime.journal().isEmpty)
    }

    func testSupersededEngineDeleteCannotOutrunNewSaveIntent() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "must survive the obsolete delete")
        await runtime.service.pushPendingLocalChanges()
        runtime.driver.add(pendingRecordZoneChanges: [.deleteRecord(runtime.cloudID)])
        let batch = await runtime.driver.batch()
        XCTAssertEqual(batch?.businessRecordsToSave.map(\.recordID), [runtime.cloudID])
        XCTAssertTrue(batch?.recordIDsToDelete.isEmpty == true)
    }

    func testBlockedReplacementLeavesTheRunningSyncSessionUsable() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let driver = runtime.driver
        let accountReads = runtime.environment.accountReads
        let snapshotReads = runtime.environment.snapshotReads
        let state = runtime.state.syncStatus
        do {
            try await runtime.service.replaceCloudDataWithLocal()
            XCTFail("Replacement must remain unavailable with unknown older clients")
        } catch { XCTAssertEqual(error as? CloudRecoveryError, .replacementUnavailable) }
        XCTAssertTrue(runtime.driver === driver)
        XCTAssertEqual(driver.cancellations, 0)
        XCTAssertEqual(runtime.environment.accountReads, accountReads)
        XCTAssertEqual(runtime.environment.snapshotReads, snapshotReads)
        XCTAssertEqual(runtime.state.syncStatus, state)
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<CloudRecoveryReceipt>()), 0)
        try await runtime.edit(notes: "ordinary sync still works")
        await runtime.service.pushPendingLocalChanges()
        let batch = await driver.batch()
        XCTAssertEqual(batch?.businessRecordsToSave.first?["notes"] as? String, "ordinary sync still works")
        XCTAssertTrue(batch?.recordIDsToDelete.isEmpty == true)
    }

    func testInvalidRecoverySourceMakesNoCloudCalls() async throws {
        let runtime = try runtime()
        let context = runtime.context
        try runtime.record(in: context).vehicle.unitSystemRaw = "unsupported-unit"
        try context.save()
        do {
            try await runtime.service.replaceCloudDataWithLocal()
            XCTFail("Invalid snapshot must fail before deleting cloud data")
        } catch {
            XCTAssertEqual(runtime.environment.zonePreparations, 0)
            XCTAssertTrue(runtime.environment.drivers.isEmpty)
        }
    }

    func testRemoteApplicationFailurePreservesInboxAndOriginalValues() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let incoming = runtime.environment.records.fuelingRecords[0]
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = "new remote value"
        incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 4_000_000)
        await runtime.driver.emit(.fetchedRecords(modifications: [incoming], deletions: []))
        runtime.fault.enabled = true
        await runtime.driver.emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: nil))
        runtime.fault.enabled = false
        XCTAssertEqual(try runtime.record(in: runtime.context).notes, "baseline")
        XCTAssertEqual(try runtime.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        await runtime.driver.emit(.checkpoint(Data("must not advance".utf8)))
        let asyncResult6 = try await SyncPersistenceStore(container: runtime.container).loadEncodedState()
        XCTAssertNil(asyncResult6)
    }

    func testSyncAcknowledgementDoesNotCommitUnrelatedUnsavedUIEdits() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "submitted value")
        await runtime.service.pushPendingLocalChanges()
        let batch = await runtime.driver.batch()
        _ = try XCTUnwrap(batch?.businessRecordsToSave.first)
        let uiContext = runtime.container.mainContext
        uiContext.autosaveEnabled = false
        let unsaved = try runtime.record(in: uiContext)
        unsaved.notes = "unsaved UI draft"
        await runtime.driver.emit(.sentRecords(.init(savedRecords: try XCTUnwrap(batch).recordsToSave)))
        XCTAssertTrue(uiContext.hasChanges)
        XCTAssertEqual(try runtime.record(in: runtime.context).notes, "submitted value")
        XCTAssertTrue(try runtime.journal().isEmpty)
    }

    func testInitialMergeSettlesWhenSDKQueueUpdateArrivesAfterSendCompletion() async throws {
        let runtime = try runtime()
        runtime.state.iCloudSyncEnabled = false
        runtime.state.initialSyncCompleted = false
        runtime.environment.automaticDelivery = true
        let proposal = try await runtime.service.prepareInitialSync()
        try await runtime.service.enableSync(strategy: .merge, proposal: proposal)
        runtime.environment.automaticDelivery = false
        runtime.driver.automaticDelivery = false
        try await runtime.edit(notes: "later local edit")
        await runtime.service.pushPendingLocalChanges()
        let driver = runtime.driver
        let batch = await driver.batch()
        let saved = try XCTUnwrap(batch?.recordsToSave)
        // Deliver the successful response while the SDK still exposes the old
        // pending set, then deliver its later state update.
        await driver.emit(.sentRecords(.init(savedRecords: saved)))
        await driver.emit(.didSend)
        XCTAssertTrue(try runtime.journal().isEmpty)
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
        driver.remove(pendingRecordZoneChanges: saved.map { .saveRecord($0.recordID) })
        await driver.emit(.checkpoint(Data("settled SDK state".utf8)))
        XCTAssertEqual(runtime.state.syncStatus, .synced)
        XCTAssertEqual(try runtime.record(in: runtime.context).odometer.bitPattern, 1000.123456789.bitPattern)
    }

    func testLateDatabaseQueueUpdateSettlesCompletedSyncWithoutRestart() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        let driver = runtime.driver
        driver.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: NativeCloudSyncEnvironment.zoneID))])
        await driver.emit(.willFetch)
        await driver.emit(.didFetch)
        await driver.emit(.willSend)
        await driver.emit(.sentZones(errors: []))
        await driver.emit(.didSend)
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
        driver.finishDatabaseChanges()
        await driver.emit(.checkpoint(Data("database queue settled".utf8)))
        XCTAssertEqual(runtime.state.syncStatus, .synced)
    }

    func testStateUpdatesDoNotReregisterAlreadyQueuedChanges() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        try await runtime.edit(notes: "pending upload")
        await runtime.service.pushPendingLocalChanges()
        let count = runtime.driver.recordRegistrations.count
        await runtime.driver.emit(.checkpoint(Data("SDK checkpoint".utf8)))
        await runtime.service.pushPendingLocalChanges()
        XCTAssertEqual(runtime.driver.recordRegistrations.count, count)
        XCTAssertEqual(try runtime.journal().count, 1)
    }

    func testCheckpointWithEmptyQueuesCannotEraseFetchFailure() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.fetchedZone(NativeCloudSyncEnvironment.zoneID, error: CKError(.networkFailure)))
        await runtime.driver.emit(.didFetch)
        await runtime.driver.emit(.checkpoint(Data("empty but failed".utf8)))
        guard case .error = runtime.state.syncStatus else { return XCTFail("State updates cannot invent success") }
    }

    func testCheckpointDoesNotCompleteAnActiveFetchOrDiscardNewerOutgoingWork() async throws {
        let runtime = try runtime()
        await runtime.service.startMonitoring()
        await runtime.driver.emit(.willFetch)
        await runtime.driver.emit(.checkpoint(Data("fetch still active".utf8)))
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
        await runtime.driver.emit(.didFetch)
        try await runtime.edit(notes: "unacknowledged work")
        await runtime.driver.emit(.checkpoint(Data("new outgoing generation".utf8)))
        XCTAssertEqual(runtime.state.syncStatus, .syncing)
        XCTAssertEqual(try runtime.journal().count, 1)
    }

    func testCheckpointAndCapturedInboxSurviveDiskStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep this isolated store until SwiftData releases its SQLite handles.
        let url = directory.appendingPathComponent("sync.store")
        let state = Data("opaque adapter state".utf8)
        var expectedID: UUID!
        do {
            let runtime = try runtime(url: url)
            expectedID = runtime.recordID
            await runtime.service.startMonitoring()
            let incoming = runtime.environment.records.fuelingRecords[0]
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
            await runtime.driver.emit(.fetchedRecords(modifications: [incoming], deletions: []))
            await runtime.driver.emit(.checkpoint(state))
            await runtime.service.stopMonitoring()
        }
        let schema = Schema(versionedSchema: SchemaV6.self)
        let reopened = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let environment = TestingCloudSyncEnvironment()
        let preferences = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "Reopen.\(UUID())")))
        preferences.iCloudSyncEnabled = true
        preferences.initialSyncCompleted = true
        let service = CloudSyncService(
            writer: OwnedModelStore(container: reopened), stateManager: preferences, environment: environment)
        await service.startMonitoring()
        XCTAssertEqual(environment.restoredStates.first!, state)
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        let record = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.id, expectedID)
        XCTAssertEqual(record.odometer.bitPattern, 1000.123456789.bitPattern)
        await service.stopMonitoring()
    }
}
