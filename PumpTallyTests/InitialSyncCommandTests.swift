import CloudKit
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class InitialSyncCommandTests: XCTestCase {
    private enum Failure: Error { case diskFull, offline }

    private final class Commits: Sendable {
        private struct State: Sendable {
            var attempts = 0
            var fail = false
            var observe: OwnedModelStore.Commit?
            var beforeSave: (@MainActor @Sendable () -> Void)?
            var afterSave: (@MainActor @Sendable () -> Void)?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var attempts: Int { state.withLock { $0.attempts } }
        func attempted() { state.withLock { $0.attempts += 1 } }
        var fail: Bool {
            get { state.withLock { $0.fail } }
            set { state.withLock { $0.fail = newValue } }
        }
        var observe: OwnedModelStore.Commit? {
            get { state.withLock { $0.observe } }
            set { state.withLock { $0.observe = newValue } }
        }
        var beforeSave: (@MainActor @Sendable () -> Void)? {
            get { state.withLock { $0.beforeSave } }
            set { state.withLock { $0.beforeSave = newValue } }
        }
        var afterSave: (@MainActor @Sendable () -> Void)? {
            get { state.withLock { $0.afterSave } }
            set { state.withLock { $0.afterSave = newValue } }
        }
    }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let writer: OwnedModelStore
        let environment: TestingCloudSyncEnvironment
        let service: CloudSyncService
        let commits: Commits
        let recordID: UUID

        var context: ModelContext { ModelContext(container) }
        var state: SyncStateManager { service.stateManager }
        var driver: TestingSyncEngineDriver { environment.drivers.last! }

        nonisolated func record(in context: ModelContext) throws -> FuelingRecord {
            let id = recordID
            return try XCTUnwrap(
                context.fetch(FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })).first)
        }

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

        func cloudEdit(notes: String) throws -> CloudSyncSnapshot {
            var snapshot = environment.records
            let original = try XCTUnwrap(snapshot.fuelingRecords.first)
            let record = try XCTUnwrap(
                CloudRecordCodec.unarchiveFullRecord(from: CloudRecordCodec.archiveFullRecord(original)))
            record[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] = notes
            record[CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(timeIntervalSince1970: 2_000_000)
            snapshot.fuelingRecords = [record]
            return snapshot
        }
    }

    private func fixture(url: URL? = nil) throws -> Fixture {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let config =
            url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let date = Date(timeIntervalSince1970: 1_000_000)
        let vehicle = Vehicle(name: "Initial sync fixture", createdAt: date)
        let record = FuelingRecord(
            date: date, odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
            fuelAmount: 10.123456789, totalCost: 35.123456789, notes: "original", createdAt: date, vehicle: vehicle)
        context.insert(vehicle)
        context.insert(record)
        try context.save()
        let environment = TestingCloudSyncEnvironment()
        environment.automaticDelivery = false
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        let parent = codec.vehicleToCKRecord(vehicle)
        environment.records = CloudSyncSnapshot(
            vehicles: [parent],
            fuelingRecords: [codec.fuelingRecordToCKRecord(record, vehicleRecordID: parent.recordID)])
        let state = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "Initial.\(UUID())")))
        state.iCloudSyncEnabled = false
        state.initialSyncCompleted = false
        let commits = Commits()
        let writer = OwnedModelStore(container: container)
        let service = CloudSyncService(
            writer: writer, stateManager: state, environment: environment,
            makePersistenceStore: { writer in
                SyncPersistenceStore(
                    writer: writer,
                    commit: { actor in
                        let context = actor.modelContext
                        commits.attempted()
                        try commits.observe?(actor)
                        if let before = commits.beforeSave { try observeOnMainActor(before) }
                        if commits.fail { throw Failure.diskFull }
                        try context.save()
                        if let after = commits.afterSave { try observeOnMainActor(after) }
                    })
            })
        addTeardownBlock { @MainActor in
            commits.beforeSave = nil
            commits.observe = nil
            commits.afterSave = nil
            environment.snapshotHandler = nil
            environment.zoneHandler = nil
            environment.replacementHandler = nil
            await service.stopMonitoring()
        }
        return Fixture(
            container: container, writer: writer, environment: environment, service: service, commits: commits,
            recordID: record.id)
    }

    func testProposalDoesNotActivateStoreOrCommitBusinessData() async throws {
        let fixture = try fixture()
        let store = SyncPersistenceStore(container: fixture.container)
        try await store.prepare(accountID: fixture.environment.userID)
        try await store.saveEncodedState(Data("old engine state".utf8))
        try await store.detach()
        let proposal = try await fixture.service.prepareInitialSync()
        XCTAssertTrue(proposal.hasCloudData)
        XCTAssertEqual(proposal.accountID, fixture.environment.userID)
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertFalse(fixture.state.initialSyncCompleted)
        let asyncResult1 = try await store.isDetached
        XCTAssertTrue(asyncResult1)
        let asyncResult2 = try await store.loadEncodedState()
        XCTAssertEqual(asyncResult2, Data("old engine state".utf8))
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
        XCTAssertEqual(try fixture.record(in: fixture.context).odometer.bitPattern, 1000.123456789.bitPattern)
    }

    func testUnavailableAccountCannotReadCloudOrActivate() async throws {
        let fixture = try fixture()
        fixture.environment.status = .noAccount
        do {
            _ = try await fixture.service.prepareInitialSync()
            XCTFail("Account availability must be checked before reading data")
        } catch InitialSyncError.unavailableAccount {}
        XCTAssertEqual(fixture.environment.accountReads, 0)
        XCTAssertEqual(fixture.environment.snapshotReads, 0)
        XCTAssertEqual(fixture.environment.zonePreparations, 0)
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
    }

    func testOldAccountInboxIsRejectedBeforeCloudReadOrAnyLocalChange() async throws {
        let fixture = try fixture()
        let store = SyncPersistenceStore(container: fixture.container)
        try await store.prepare(accountID: "old-account")
        try await store.capture(modifications: fixture.environment.records.vehicles, deletions: [])
        do {
            _ = try await fixture.service.prepareInitialSync()
            XCTFail("Unresolved data from another account must not be reconciled")
        } catch SyncPersistenceError.accountDataNeedsReview {}
        XCTAssertEqual(fixture.environment.snapshotReads, 0)
        XCTAssertEqual(fixture.environment.zonePreparations, 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, "old-account")
        XCTAssertEqual(fixture.commits.attempts, 0)
    }

    func testAccountSwitchWhilePreparingDoesNotReturnAConfirmationForTheNewAccount() async throws {
        let fixture = try fixture()
        fixture.environment.snapshotHandler = {
            fixture.environment.userID = "other-account"
            return fixture.environment.records
        }
        do {
            _ = try await fixture.service.prepareInitialSync()
            XCTFail("The account changed while reading the proposal")
        } catch SyncPersistenceError.accountChanged {}
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
    }

    func testEveryStrategyRejectsAnAccountSwitchAfterConfirmation() async throws {
        for strategy: InitialSyncStrategy in [.merge, .useCloud, .replaceCloud] {
            let fixture = try fixture()
            let proposal = try await fixture.service.prepareInitialSync()
            fixture.environment.userID = "other-account"
            do {
                try await fixture.service.enableSync(strategy: strategy, proposal: proposal)
                XCTFail("A confirmation cannot apply to another account")
            } catch SyncPersistenceError.accountChanged {}
            XCTAssertEqual(fixture.environment.snapshotReads, 1)
            XCTAssertEqual(fixture.environment.zoneReplacements, 0)
            XCTAssertEqual(fixture.commits.attempts, 0)
            XCTAssertTrue(fixture.environment.drivers.isEmpty)
            XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
        }
    }

    func testProposalCannotBeAppliedToAnotherStore() async throws {
        let first = try fixture()
        let second = try fixture()
        let proposal = try await first.service.prepareInitialSync()
        do {
            try await second.service.enableSync(strategy: .useCloud, proposal: proposal)
            XCTFail("Proposal must be bound to its original store")
        } catch InitialSyncError.differentStore {}
        XCTAssertEqual(try second.record(in: second.context).notes, "original")
        XCTAssertEqual(first.commits.attempts, 0)
    }

    func testAccountSwitchDuringFreshFetchCannotCommitTheFetchedValues() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        let incoming = try fixture.cloudEdit(notes: "wrong scope")
        fixture.environment.snapshotHandler = {
            fixture.environment.userID = "other-account"
            return incoming
        }
        do {
            try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
            XCTFail("Post-fetch account verification must precede the transaction")
        } catch SyncPersistenceError.accountChanged {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 0)
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
    }

    func testFetchFailureDoesNotChangePreferencesCheckpointOrRecords() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.environment.snapshotError = Failure.offline
        do {
            try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
            XCTFail("Failed fetch must not be treated as an empty source")
        } catch Failure.offline {}
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SyncCheckpoint>()), 0)
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertFalse(fixture.state.initialSyncCompleted)
    }

    func testMergeCommitsRecordsCachesMetadataOutboxAndActivationBeforeEngineStarts() async throws {
        let fixture = try fixture()
        let context = fixture.context
        let localOnly = Vehicle(name: "local-only")
        context.insert(localOnly)
        try context.save()
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.environment.records = try fixture.cloudEdit(notes: "fresh server value")
        fixture.commits.beforeSave = {
            XCTAssertTrue(fixture.environment.drivers.isEmpty)
            XCTAssertFalse(fixture.state.iCloudSyncEnabled)
            XCTAssertFalse(fixture.state.initialSyncCompleted)
        }
        let expectedAccount = fixture.environment.userID
        let localOnlyName = localOnly.id.uuidString
        fixture.commits.observe = { actor in
            let context = actor.modelContext
            XCTAssertEqual(try fixture.record(in: context).notes, "fresh server value")
            XCTAssertEqual(try fixture.record(in: context).vehicle.cachedRecordCount, 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 2)
            XCTAssertEqual(
                try context.fetch(FetchDescriptor<SyncChange>()).map(\.recordName), [localOnlyName])
            let checkpoint = try XCTUnwrap(context.fetch(FetchDescriptor<SyncCheckpoint>()).first)
            XCTAssertEqual(checkpoint.accountID, expectedAccount)
            XCTAssertTrue(checkpoint.bootstrapCompleted == true)
            XCTAssertFalse(checkpoint.detached == true)
        }
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(fixture.commits.attempts, 1)
        XCTAssertEqual(fixture.environment.snapshotReads, 2, "Startup must not repeat initial reconciliation")
        XCTAssertTrue(fixture.state.iCloudSyncEnabled)
        XCTAssertTrue(fixture.state.initialSyncCompleted)
        let batch = await fixture.driver.batch()
        XCTAssertEqual(batch?.recordsToSave.map(\.recordID.recordName), [localOnly.id.uuidString])
    }

    func testMergeCommitFailureRollsBackEveryPartOfActivation() async throws {
        let fixture = try fixture()
        let store = SyncPersistenceStore(container: fixture.container)
        try await store.prepare(accountID: fixture.environment.userID)
        try await store.saveEncodedState(Data("previous checkpoint".utf8))
        try await store.detach()
        try await fixture.edit(notes: "previous local edit")
        let oldGeneration = try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.environment.records = try fixture.cloudEdit(notes: "incoming")
        fixture.environment.records.fuelingRecords[0][CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(
            timeIntervalSince1970: 4_000_000)
        fixture.commits.observe = { actor in
            let context = actor.modelContext
            XCTAssertEqual(try fixture.record(in: context).notes, "incoming")
            XCTAssertEqual(try fixture.record(in: context).vehicle.cachedRecordCount, 1)
        }
        fixture.commits.fail = true
        do {
            try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
            XCTFail("A failed commit must fail the whole activation")
        } catch Failure.diskFull {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "previous local edit")
        XCTAssertNil(try fixture.record(in: fixture.context).vehicle.cachedRecordCount)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation, oldGeneration)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 0)
        let asyncResult3 = try await store.loadEncodedState()
        XCTAssertEqual(asyncResult3, Data("previous checkpoint".utf8))
        let asyncResult4 = try await store.isDetached
        XCTAssertTrue(asyncResult4)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertFalse(fixture.state.initialSyncCompleted)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
    }

    func testUseCloudReplacementAndMetadataAreOneCommit() async throws {
        let fixture = try fixture()
        let cloudSource = try self.fixture()
        try await fixture.edit(notes: "explicitly displaced local data")
        fixture.environment.records = cloudSource.environment.records
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.commits.beforeSave = {
            XCTAssertFalse(fixture.state.iCloudSyncEnabled)
            XCTAssertTrue(fixture.environment.drivers.isEmpty)
        }
        fixture.commits.observe = { actor in
            let context = actor.modelContext
            let records = try context.fetch(FetchDescriptor<FuelingRecord>())
            XCTAssertEqual(records.map(\.id), [cloudSource.recordID])
            XCTAssertEqual(records.first?.odometer.bitPattern, 1000.123456789.bitPattern)
            XCTAssertEqual(records.first?.vehicle.cachedRecordCount, 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 2)
            XCTAssertTrue(try context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.bootstrapCompleted == true)
        }
        try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
        XCTAssertEqual(fixture.commits.attempts, 1)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<FuelingRecord>()).map(\.id), [cloudSource.recordID])
        XCTAssertEqual(fixture.environment.zoneReplacements, 0)
    }

    func testMalformedCloudReplacementLeavesLocalStoreIntact() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.environment.records.fuelingRecords[0][CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] = nil
        do {
            try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
            XCTFail("Validate the complete snapshot before local replacement")
        } catch {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SyncCheckpoint>()), 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
    }

    func testUseCloudRejectsLocalEditsMadeAfterConfirmationWasPrepared() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.edit(notes: "new user edit")
        let generation = try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation
        do {
            try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
            XCTFail("A source confirmation cannot discard later local changes")
        } catch InitialSyncError.localDataChanged {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "new user edit")
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation, generation)
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
    }

    func testMergeIncludesLocalEditCommittedWhileCloudFetchWasSuspended() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        let fetching = expectation(description: "Fresh cloud read is suspended")
        var release: CheckedContinuation<CloudSyncSnapshot, Never>?
        fixture.environment.snapshotHandler = {
            await withCheckedContinuation { continuation in
                release = continuation
                fetching.fulfill()
            }
        }
        let command = Task {
            try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        }
        await fulfillment(of: [fetching], timeout: 5)
        try await fixture.edit(notes: "edit during fetch")
        release?.resume(returning: fixture.environment.records)
        try await command.value
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "edit during fetch")
        XCTAssertEqual(fixture.commits.attempts, 1)
        let batch = await fixture.driver.batch()
        XCTAssertEqual(
            batch?.recordsToSave.first?[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] as? String,
            "edit during fetch")
    }

    func testUseCloudRejectsAnEditCommittedWhileItsFetchWasSuspended() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        let fetching = expectation(description: "Replacement source read is suspended")
        var release: CheckedContinuation<CloudSyncSnapshot, Never>?
        fixture.environment.snapshotHandler = {
            await withCheckedContinuation { continuation in
                release = continuation
                fetching.fulfill()
            }
        }
        let command = Task {
            try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
        }
        await fulfillment(of: [fetching], timeout: 5)
        try await fixture.edit(notes: "do not discard this edit")
        release?.resume(returning: fixture.environment.records)
        do {
            try await command.value
            XCTFail("Late local edits require another confirmation")
        } catch InitialSyncError.localDataChanged {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "do not discard this edit")
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
    }

    func testInitialMergeDoesNotCommitAnUnrelatedUnsavedUIEdit() async throws {
        let fixture = try fixture()
        let uiContext = fixture.container.mainContext
        uiContext.autosaveEnabled = false
        let record = try fixture.record(in: uiContext)
        record.notes = "unsaved UI text"
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertTrue(uiContext.hasChanges)
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
    }

    func testDriverCreationFailureKeepsCommittedActivationAndRetriesWithoutReconciliation() async throws {
        let fixture = try fixture()
        fixture.environment.records = CloudSyncSnapshot()
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.environment.driverError = Failure.offline
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertTrue(fixture.state.iCloudSyncEnabled)
        XCTAssertTrue(fixture.state.initialSyncCompleted)
        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.bootstrapCompleted == true)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SyncChange>()), 2)
        XCTAssertEqual(fixture.commits.attempts, 1)
        XCTAssertEqual(fixture.environment.snapshotReads, 2)
        guard case .error = fixture.state.syncStatus else { return XCTFail("Engine failure must remain visible") }
        fixture.environment.driverError = nil
        await fixture.service.startMonitoring()
        XCTAssertEqual(fixture.environment.drivers.count, 1)
        XCTAssertEqual(fixture.environment.snapshotReads, 2)
        XCTAssertEqual(fixture.driver.pendingRecordZoneChanges.count, 2)
    }

    func testVerifiedLocalDeletionIsNotResurrectedByInitialMerge() async throws {
        let fixture = try fixture()
        let context = fixture.context
        let record = try fixture.record(in: context)
        try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
        context.delete(record)
        try context.save()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        let batch = await fixture.driver.batch()
        XCTAssertEqual(batch?.recordIDsToDelete.map(\.recordName), [fixture.recordID.uuidString])
        XCTAssertTrue(batch?.recordsToSave.isEmpty == true)
    }

    func testConfirmedVehicleDeletionAlsoQueuesChildrenFirstDiscoveredDuringInitialMerge() async throws {
        let fixture = try fixture()
        let other = try self.fixture()
        let discovered = other.environment.records.fuelingRecords[0]
        discovered[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] =
            fixture.environment.records.vehicles[0].recordID.recordName
        fixture.environment.records.fuelingRecords.append(discovered)
        let context = fixture.context
        let record = try fixture.record(in: context)
        try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
        try SyncChangeJournal.enqueue(record.vehicle, operation: .delete, in: context)
        context.delete(record.vehicle)
        try context.save()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Vehicle>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        let batch = await fixture.driver.batch()
        XCTAssertEqual(batch?.recordIDsToDelete.count, 3)
        XCTAssertTrue(batch?.recordIDsToDelete.contains(discovered.recordID) == true)
        XCTAssertTrue(batch?.recordsToSave.isEmpty == true)
    }

    func testUnverifiedDeletionIsRetainedForReviewThroughInitialMerge() async throws {
        let fixture = try fixture()
        let context = fixture.context
        let deletion = SyncChange(
            recordName: fixture.recordID.uuidString, recordTypeRaw: "FuelingRecord", operationRaw: "delete")
        deletion.originRaw = nil
        context.insert(deletion)
        try context.save()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertNil(try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.originRaw)
        let batch = await fixture.driver.batch()
        XCTAssertNil(batch)
        XCTAssertEqual(fixture.state.syncStatus, .reviewRequired)
    }

    func testCancelledEnableCannotCommitOrStartAnEngine() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        let fetching = expectation(description: "Cancelled command waits for cloud read")
        var release: CheckedContinuation<CloudSyncSnapshot, Never>?
        fixture.environment.snapshotHandler = {
            await withCheckedContinuation { continuation in
                release = continuation
                fetching.fulfill()
            }
        }
        let command = Task {
            try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        }
        await fulfillment(of: [fetching], timeout: 5)
        command.cancel()
        release?.resume(returning: fixture.environment.records)
        do {
            try await command.value
            XCTFail("A cancelled command must not activate")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
    }

    func testFreshSnapshotSupersedesAnOlderInboxPayloadForTheSameRecord() async throws {
        let fixture = try fixture()
        let pending = try fixture.cloudEdit(notes: "obsolete pending payload")
        pending.fuelingRecords[0][CloudRecordCodec.CloudFieldKey.FuelingRecord.modifiedAt] = Date(
            timeIntervalSince1970: 5_000_000)
        try await SyncPersistenceStore(container: fixture.container).capture(
            modifications: pending.fuelingRecords, deletions: [])
        fixture.environment.records = try fixture.cloudEdit(notes: "current server value")
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "current server value")
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<PendingRemoteChange>()), 0)
    }

    func testDeferredCurrentPayloadIsRetainedInsteadOfItsOlderInboxVersion() async throws {
        let fixture = try fixture()
        let store = SyncPersistenceStore(container: fixture.container)
        try await store.capture(modifications: fixture.environment.records.fuelingRecords, deletions: [])
        let current = try fixture.cloudEdit(notes: "current malformed evidence")
        current.fuelingRecords[0][CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount] = nil
        fixture.environment.records = current
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        let pending = try XCTUnwrap(fixture.context.fetch(FetchDescriptor<PendingRemoteChange>()).first)
        let retained = try XCTUnwrap(SyncPersistenceStore.PendingPayload.decode(pending.recordData).record())
        XCTAssertEqual(
            retained[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] as? String, "current malformed evidence")
        XCTAssertNil(retained[CloudRecordCodec.CloudFieldKey.FuelingRecord.fuelAmount])
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "original")
        XCTAssertEqual(fixture.state.syncStatus, .reviewRequired)
    }

    func testFailedUseCloudCommitRestoresTheOriginalDatasetAndOutgoingWork() async throws {
        let fixture = try fixture()
        let source = try self.fixture()
        try await fixture.edit(notes: "preserve on disk failure")
        let generation = try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation
        fixture.environment.records = source.environment.records
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.commits.fail = true
        do {
            try await fixture.service.enableSync(strategy: .useCloud, proposal: proposal)
            XCTFail("Replacement must roll back if its single commit fails")
        } catch Failure.diskFull {}
        XCTAssertEqual(try fixture.record(in: fixture.context).notes, "preserve on disk failure")
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation, generation)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SyncCheckpoint>()), 0)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
    }

    func testDuplicateConfirmationCannotReconcileAnAlreadyEnabledStoreAgain() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        let status = fixture.state.syncStatus
        do {
            try await fixture.service.enableSync(strategy: .replaceCloud, proposal: proposal)
            XCTFail("An already completed confirmation cannot replace data again")
        } catch InitialSyncError.alreadyEnabled {}
        XCTAssertEqual(fixture.commits.attempts, 1)
        XCTAssertEqual(fixture.environment.zoneReplacements, 0)
        XCTAssertEqual(fixture.state.syncStatus, status)
    }

    func testExplicitMergeIntoAnotherAccountReplacesOldSystemFields() async throws {
        let fixture = try fixture()
        let store = SyncPersistenceStore(container: fixture.container)
        try await store.prepare(accountID: "previous-account")
        let context = fixture.context
        let cloudRecord = fixture.environment.records.fuelingRecords[0]
        let key = "FuelingRecord:\(cloudRecord.recordID.recordName)"
        context.insert(CloudRecordMetadata(key: key, systemFieldsData: Data("previous account metadata".utf8)))
        try context.save()
        let proposal = try await fixture.service.prepareInitialSync()
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        let metadata = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<CloudRecordMetadata>()).first { $0.key == key })
        let decoder = try NSKeyedUnarchiver(forReadingFrom: metadata.systemFieldsData)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        XCTAssertEqual(CKRecord(coder: decoder)?.recordID, cloudRecord.recordID)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 2)
        XCTAssertEqual(
            try fixture.context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, fixture.environment.userID)
    }

    func testAccountSwitchAfterCommitPausesBeforeStartingAnEngineForTheOtherAccount() async throws {
        let fixture = try fixture()
        fixture.environment.records = CloudSyncSnapshot()
        let originalAccount = fixture.environment.userID
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.commits.afterSave = { fixture.environment.userID = "other-account" }
        try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertFalse(fixture.state.initialSyncCompleted)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.accountID, originalAccount)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<SyncChange>()), 2)
        XCTAssertEqual(try fixture.record(in: fixture.context).odometer.bitPattern, 1000.123456789.bitPattern)
    }

    func testLegacyCloudReplacementStagesOneActivationAndUsesTheEngineOutbox() async throws {
        let fixture = try fixture()
        let cloudSource = try self.fixture()
        fixture.environment.records = cloudSource.environment.records
        let proposal = try await fixture.service.prepareInitialSync()
        fixture.commits.beforeSave = {
            XCTAssertEqual(fixture.environment.zoneReplacements, 1)
            XCTAssertTrue(fixture.environment.drivers.isEmpty)
            XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        }
        fixture.commits.observe = { actor in
            let context = actor.modelContext
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<CloudRecordMetadata>()), 0)
            XCTAssertEqual(try fixture.record(in: context).odometer.bitPattern, 1000.123456789.bitPattern)
            XCTAssertTrue(try context.fetch(FetchDescriptor<SyncCheckpoint>()).first?.bootstrapCompleted == true)
        }
        try await fixture.service.enableSync(strategy: .replaceCloud, proposal: proposal)
        XCTAssertEqual(fixture.commits.attempts, 1)
        XCTAssertEqual(fixture.environment.snapshotReads, 1)
        let batch = await fixture.driver.batch()
        XCTAssertEqual(batch?.recordsToSave.count, 2)
        XCTAssertTrue(batch?.recordIDsToDelete.isEmpty == true)
        XCTAssertEqual(try fixture.context.fetch(FetchDescriptor<FuelingRecord>()).map(\.id), [fixture.recordID])
    }

    func testInvalidLocalReplacementSourceIsRejectedBeforeDeletingCloudData() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        let context = fixture.context
        try fixture.record(in: context).vehicle.unitSystemRaw = "unsupported-unit"
        try context.save()
        do {
            try await fixture.service.enableSync(strategy: .replaceCloud, proposal: proposal)
            XCTFail("Validate the trusted local source before touching the cloud")
        } catch CloudSnapshotValidator.ValidationError.invalidVehicleRecord {}
        XCTAssertEqual(fixture.environment.zoneReplacements, 0)
        XCTAssertEqual(fixture.commits.attempts, 0)
        XCTAssertFalse(fixture.state.iCloudSyncEnabled)
        XCTAssertTrue(fixture.environment.drivers.isEmpty)
    }

    func testDeletionCommittedDuringLegacyReplacementRetainsItsExactGeneration() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        var generation: String?
        fixture.environment.replacementHandler = {
            let context = fixture.context
            let record = try fixture.record(in: context)
            try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
            context.delete(record)
            try context.save()
            generation = try context.fetch(FetchDescriptor<SyncChange>()).first?.generation
        }
        try await fixture.service.enableSync(strategy: .replaceCloud, proposal: proposal)
        let journal = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<SyncChange>()).first { $0.recordName == fixture.recordID.uuidString })
        XCTAssertEqual(journal.generation, generation)
        XCTAssertEqual(journal.operationRaw, "delete")
        let batch = await fixture.driver.batch()
        XCTAssertEqual(batch?.recordIDsToDelete.map(\.recordName), [fixture.recordID.uuidString])
        XCTAssertFalse(batch?.recordsToSave.contains { $0.recordID.recordName == fixture.recordID.uuidString } == true)
    }

    func testEditCommittedDuringLegacyReplacementRetainsItsExactGenerationAndValues() async throws {
        let fixture = try fixture()
        let proposal = try await fixture.service.prepareInitialSync()
        var generation: String?
        fixture.environment.replacementHandler = {
            try await fixture.edit(notes: "edit during replacement")
            generation = try fixture.context.fetch(FetchDescriptor<SyncChange>()).first?.generation
        }
        try await fixture.service.enableSync(strategy: .replaceCloud, proposal: proposal)
        let journal = try XCTUnwrap(
            fixture.context.fetch(FetchDescriptor<SyncChange>()).first { $0.recordName == fixture.recordID.uuidString })
        XCTAssertEqual(journal.generation, generation)
        let batch = await fixture.driver.batch()
        let record = try XCTUnwrap(batch?.recordsToSave.first { $0.recordID.recordName == fixture.recordID.uuidString })
        XCTAssertEqual(record[CloudRecordCodec.CloudFieldKey.FuelingRecord.notes] as? String, "edit during replacement")
    }

    func testInitialMergePreservesThe800RecordFixtureExactlyThroughSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("representative.store")
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "SchemaV3", withExtension: "store", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: url)
        let schema = Schema(versionedSchema: SchemaV4.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        func businessValues(in context: ModelContext) throws -> [UUID: [UInt64]] {
            Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<FuelingRecord>()).map { record in
                    (
                        record.id,
                        [
                            record.odometer.bitPattern, record.pricePerFuelUnit.bitPattern,
                            record.fuelAmount.bitPattern, record.totalCost.bitPattern,
                            record.date.timeIntervalSinceReferenceDate.bitPattern,
                            record.createdAt.timeIntervalSinceReferenceDate.bitPattern,
                            record.modifiedAt?.timeIntervalSinceReferenceDate.bitPattern ?? UInt64.max,
                        ]
                    )
                })
        }
        var expected: [UUID: [UInt64]] = [:]
        var owners: [UUID: UUID] = [:]
        var notes: [UUID: String?] = [:]
        var units: [UUID: String] = [:]
        var expectedOutbox: [String: [String?]] = [:]
        do {
            let container = try ModelContainer(
                for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [config])
            let context = ModelContext(container)
            let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
            let records = try context.fetch(FetchDescriptor<FuelingRecord>())
            XCTAssertEqual(records.count, 800)
            expected = try businessValues(in: context)
            expectedOutbox = Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<SyncChange>()).map {
                    ($0.key, [$0.generation, $0.operationRaw, $0.originRaw])
                })
            owners = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.vehicle.id) })
            notes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.notes) })
            units = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.id, $0.unitSystemRaw) })
            let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
            let environment = TestingCloudSyncEnvironment()
            environment.automaticDelivery = false
            environment.records = CloudSyncSnapshot(
                vehicles: vehicles.map { codec.vehicleToCKRecord($0) },
                fuelingRecords: records.map {
                    codec.fuelingRecordToCKRecord($0, vehicleRecordID: codec.vehicleToCKRecord($0.vehicle).recordID)
                })
            let state = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "Initial800.\(UUID())")))
            state.iCloudSyncEnabled = false
            state.initialSyncCompleted = false
            let service = CloudSyncService(
                writer: OwnedModelStore(container: container), stateManager: state, environment: environment)
            let proposal = try await service.prepareInitialSync()
            try await service.enableSync(strategy: .merge, proposal: proposal)
            XCTAssertEqual(try businessValues(in: ModelContext(container)), expected)
            XCTAssertEqual(
                try ModelContext(container).fetchCount(FetchDescriptor<CloudRecordMetadata>()), 800 + vehicles.count)
            let outbox = try ModelContext(container).fetch(FetchDescriptor<SyncChange>())
            XCTAssertEqual(
                Dictionary(
                    uniqueKeysWithValues: outbox.map { ($0.key, [$0.generation, $0.operationRaw, $0.originRaw]) }),
                expectedOutbox)
            await service.stopMonitoring()
        }
        let reopened = try ModelContainer(
            for: schema, migrationPlan: PumpTallyMigrationPlan.self, configurations: [config])
        let context = ModelContext(reopened)
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        XCTAssertEqual(try businessValues(in: context), expected)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.vehicle.id) }), owners)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.notes) }), notes)
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<Vehicle>()).map { ($0.id, $0.unitSystemRaw) }),
            units)
    }

    func testCommittedActivationReopensWithoutASecondFullReconciliation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("initial.store")
        do {
            let fixture = try fixture(url: url)
            fixture.environment.records = CloudSyncSnapshot()
            let proposal = try await fixture.service.prepareInitialSync()
            try await fixture.service.enableSync(strategy: .merge, proposal: proposal)
            await fixture.service.stopMonitoring()
        }
        let schema = Schema(versionedSchema: SchemaV4.self)
        let reopened = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let environment = TestingCloudSyncEnvironment()
        environment.snapshotError = Failure.offline
        let state = SyncStateManager(defaults: try XCTUnwrap(UserDefaults(suiteName: "InitialReopen.\(UUID())")))
        state.iCloudSyncEnabled = true
        state.initialSyncCompleted = true
        let service = CloudSyncService(
            writer: OwnedModelStore(container: reopened), stateManager: state, environment: environment)
        await service.startMonitoring()
        XCTAssertEqual(environment.snapshotReads, 0)
        XCTAssertEqual(environment.drivers.count, 1)
        XCTAssertEqual(environment.drivers[0].pendingRecordZoneChanges.count, 2)
        XCTAssertEqual(
            try ModelContext(reopened).fetch(FetchDescriptor<FuelingRecord>()).first?.odometer.bitPattern,
            1000.123456789.bitPattern)
        await service.stopMonitoring()
    }
}
