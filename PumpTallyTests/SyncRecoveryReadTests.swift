import CloudKit
import Combine
import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
struct RecoveryReadFixture {
    let history: VehicleHistoryFixture
    let inboxBytes: [String: Data]

    init(localCount: Int, incomingCount: Int, unrelated: Int = 0) throws {
        history = try VehicleHistoryFixture(count: localCount, unrelated: unrelated)
        let context = ModelContext(history.container)
        context.autosaveEnabled = false
        let owner = history.vehicleID
        let records = try context.fetch(
            FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.vehicle.id == owner }))
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        var bytes: [String: Data] = [:]
        for (index, record) in records.prefix(incomingCount).enumerated() {
            let incoming = codec.fuelingRecordToCKRecord(
                record, vehicleRecordID: codec.vehicleToCKRecord(record.vehicle).recordID)
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
            incoming[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = record.odometer + 0.5
            let archive = try CloudRecordCodec.archiveFullRecord(incoming)
            let data =
                index == 0
                ? archive
                : try JSONEncoder().encode(
                    SyncPersistenceStore.PendingPayload(
                        kind: .modification, recordName: incoming.recordID.recordName,
                        recordType: incoming.recordType, archivedRecord: archive))
            let key = "FuelingRecord:\(record.id)"
            context.insert(PendingRemoteChange(key: key, recordData: data))
            bytes[key] = data
        }
        try context.save()
        inboxBytes = bytes
    }
}

@MainActor
final class SyncRecoveryReadTests: XCTestCase {
    private enum Failure: Error { case diskFull }

    func testAssessmentIsReadOnlyOffMainAndFetchesOnlyRelevantHistory() async throws {
        let fixture = try RecoveryReadFixture(localCount: 800, incomingCount: 1, unrelated: 3200)
        let responded = OSAllocatedUnfairLock(initialState: false)
        let assessment = try await SyncRecoveryReader.read(container: fixture.history.container) { reader in
            XCTAssertFalse(Thread.isMainThread)
            try observeOnMainActor { responded.withLock { $0 = true } }
            let value = try SyncReviewService.assessment(in: reader.modelContext)
            XCTAssertFalse(reader.modelContext.hasChanges)
            return value
        }
        XCTAssertTrue(responded.withLock { $0 })
        XCTAssertEqual(assessment.unitConfirmations.count, 1)
        XCTAssertEqual(assessment.metrics.vehiclesRead, 1)
        XCTAssertEqual(assessment.metrics.fuelingRecordsRead, 1)
        XCTAssertEqual(assessment.metrics.inbox.loads, 1)
        XCTAssertEqual(assessment.metrics.inbox.payloadsDecoded, 1)
        XCTAssertEqual(assessment.metrics.inbox.recordsUnarchived, 1)
        let context = ModelContext(fixture.history.container)
        XCTAssertEqual(try inboxBytes(in: context), fixture.inboxBytes)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
        let source = try await fixture.history.source()
        for record in source.records {
            let expected = try XCTUnwrap(fixture.history.values[record.id])
            XCTAssertEqual(record.values.odometer.bitPattern, expected.odometer.bitPattern)
            XCTAssertEqual(record.values.pricePerFuelUnit.bitPattern, expected.pricePerFuelUnit.bitPattern)
            XCTAssertEqual(record.values.fuelAmount.bitPattern, expected.fuelAmount.bitPattern)
            XCTAssertEqual(record.values.totalCost.bitPattern, expected.totalCost.bitPattern)
        }
    }

    func testLargeMixedEnvelopeQueueIsDecodedOnceAndUnrelatedRowsStayUnloaded() async throws {
        let fixture = try RecoveryReadFixture(localCount: 400, incomingCount: 300, unrelated: 800)
        let assessment = try await SyncRecoveryReader.read(container: fixture.history.container) {
            try SyncReviewService.assessment(in: $0.modelContext)
        }
        XCTAssertEqual(assessment.unitConfirmations.count, 300)
        XCTAssertTrue(assessment.diagnostics.isEmpty)
        XCTAssertEqual(assessment.metrics.vehiclesRead, 1)
        XCTAssertEqual(assessment.metrics.fuelingRecordsRead, 300)
        XCTAssertEqual(assessment.metrics.inbox.payloadsDecoded, 300)
        XCTAssertEqual(assessment.metrics.inbox.recordsUnarchived, 300)
        XCTAssertEqual(try inboxBytes(in: ModelContext(fixture.history.container)), fixture.inboxBytes)
    }

    func testMultipleDeletedParentsReuseOneInboxAndRetainOtherPendingChanges() async throws {
        for count in [1, 32] {
            let fixture = try deletionFixture(owners: count)
            let effects = try await OwnedModelStore(container: fixture.container).transaction {
                try SyncDatabase(codec: fixture.codec).applyInbox(in: $0.modelContext)
            }
            XCTAssertEqual(effects.inboxMetrics.loads, 1)
            XCTAssertEqual(effects.inboxMetrics.payloadsDecoded, count * 2 + 1)
            XCTAssertEqual(effects.inboxMetrics.recordsUnarchived, count + 1)
            XCTAssertEqual(effects.removals.count, count)
            let context = ModelContext(fixture.container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
            XCTAssertEqual(try inboxBytes(in: context), fixture.retained)
            let journal = try context.fetch(FetchDescriptor<SyncChange>())
            XCTAssertEqual(journal.count, count * 2)
            XCTAssertTrue(journal.allSatisfy { $0.operationRaw == "delete" && $0.originRaw != nil })
            let blocked = try SyncDatabase(codec: fixture.codec).blockedVehicleNames(in: context)
            XCTAssertEqual(blocked, [fixture.remainingOwner.uuidString])
        }
    }

    func testFailedCommitRollsBackAllParentCleanupAndKeepsRawInbox() async throws {
        let fixture = try deletionFixture(owners: 3)
        let before = try inboxBytes(in: ModelContext(fixture.container))
        do {
            _ = try await OwnedModelStore(container: fixture.container).transaction(
                commit: { _ in throw Failure.diskFull }
            ) { try SyncDatabase(codec: fixture.codec).applyInbox(in: $0.modelContext) }
            XCTFail("Expected failed commit")
        } catch Failure.diskFull {}
        let context = ModelContext(fixture.container)
        XCTAssertEqual(try inboxBytes(in: context), before)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Vehicle>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
        for record in try context.fetch(FetchDescriptor<FuelingRecord>()) {
            XCTAssertEqual(record.odometer.bitPattern, 1000.123456789.bitPattern)
            XCTAssertEqual(record.totalCost.bitPattern, 35.123456789.bitPattern)
        }
    }

    func testUnreadableOrMismatchedEnvelopeFailsBeforeAnyDeletion() async throws {
        for mismatch in [false, true] {
            let fixture = try deletionFixture(owners: 2)
            let context = ModelContext(fixture.container)
            let data: Data
            if mismatch {
                let vehicle = try XCTUnwrap(context.fetch(FetchDescriptor<Vehicle>()).first)
                let record = fixture.codec.vehicleToCKRecord(vehicle)
                data = try JSONEncoder().encode(
                    SyncPersistenceStore.PendingPayload(
                        kind: .modification, recordName: UUID().uuidString, recordType: record.recordType,
                        archivedRecord: CloudRecordCodec.archiveFullRecord(record)))
            } else {
                data = Data("Unchanged unreadable evidence".utf8)
            }
            context.insert(PendingRemoteChange(key: "damaged", recordData: data))
            try context.save()
            let before = try inboxBytes(in: context)
            XCTAssertThrowsError(try SyncDatabase(codec: fixture.codec).applyInbox(in: context))
            XCTAssertFalse(context.hasChanges)
            XCTAssertEqual(try inboxBytes(in: context), before)
            let assessment = try SyncReviewService.assessment(in: context)
            XCTAssertEqual(assessment.diagnostics.map(\.reason), [.unreadableChange])
            XCTAssertEqual(assessment.unitConfirmations.count, 3)
        }
    }

    func testGenerationFenceRejectsWholeInboxBeforeCleanup() throws {
        let fixture = try deletionFixture(owners: 2)
        let context = ModelContext(fixture.container)
        let control = try CloudSyncControl.baseline(in: fixture.codec.zoneID).changing(
            generation: UUID().uuidString, phase: .ready
        ).record
        try SyncPersistenceStore.stageInbound(
            .init(
                kind: .modification, recordName: control.recordID.recordName,
                recordType: control.recordType, archivedRecord: CloudRecordCodec.archiveFullRecord(control)),
            in: context)
        try context.save()
        let before = try inboxBytes(in: context)
        XCTAssertThrowsError(try SyncDatabase(codec: fixture.codec).applyInbox(in: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try inboxBytes(in: context), before)
    }

    private actor Gate {
        let entered: XCTestExpectation
        var continuation: CheckedContinuation<SyncReviewService.Assessment, Never>?
        var calls = 0
        init(entered: XCTestExpectation) { self.entered = entered }
        func load() async -> SyncReviewService.Assessment {
            calls += 1
            if calls > 1 { return .init(legacyDeletionCount: 2) }
            return await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func release() {
            continuation?.resume(returning: .init(legacyDeletionCount: 1))
            continuation = nil
        }
    }

    func testSaveWithTheSameInboxKeyRejectsAnAssessmentAlreadyInFlight() async throws {
        let fixture = try RecoveryReadFixture(localCount: 1, incomingCount: 1)
        let context = ModelContext(fixture.history.container)
        let entered = expectation(description: "Assessment held before publication")
        let gate = Gate(entered: entered)
        let model = SyncRecoveryModel { _ in await gate.load() }
        let pending = Task { await model.reload(in: context) }
        await fulfillment(of: [entered], timeout: 5)
        try await OwnedModelStore(container: context.container).transaction { actor in
            let row = try XCTUnwrap(actor.modelContext.fetch(FetchDescriptor<PendingRemoteChange>()).first)
            row.recordData = Data("A newer incoming payload for the same key".utf8)
        }
        await gate.release()
        await pending.value
        XCTAssertEqual(model.assessment.legacyDeletionCount, 0)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.revision > 0 }, object: nil)
        await fulfillment(of: [changed], timeout: 5)
        await model.reload(in: context)
        XCTAssertEqual(model.assessment.legacyDeletionCount, 2)
    }

    func testCancelledAndSupersededAssessmentsCannotReplaceNewerResults() async throws {
        let fixture = try RecoveryReadFixture(localCount: 1, incomingCount: 1)
        for cancelled in [false, true] {
            let entered = expectation(description: "Assessment waiting")
            let gate = Gate(entered: entered)
            let model = SyncRecoveryModel { _ in await gate.load() }
            let context = ModelContext(fixture.history.container)
            let pending = Task { await model.reload(in: context) }
            await fulfillment(of: [entered], timeout: 5)
            if cancelled { pending.cancel() }
            await model.reload(in: context)
            await gate.release()
            await pending.value
            XCTAssertEqual(model.assessment.legacyDeletionCount, 2)
            XCTAssertNil(model.loadError)
        }
    }

    func testFailedAssessmentCanRetryAndIgnoresOtherContainerAndCheckpointSaves() async throws {
        let fixture = try RecoveryReadFixture(localCount: 1, incomingCount: 1)
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let model = SyncRecoveryModel { _ in
            let count = attempts.withLock {
                $0 += 1
                return $0
            }
            if count == 1 { throw Failure.diskFull }
            return .init(legacyDeletionCount: 1)
        }
        let context = ModelContext(fixture.history.container)
        await model.reload(in: context)
        XCTAssertNotNil(model.loadError)
        await model.reload(in: context)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.assessment.legacyDeletionCount, 1)
        let unexpected = expectation(description: "Unrelated saves do not reload review")
        unexpected.isInverted = true
        let subscription = model.$revision.dropFirst().sink { _ in unexpected.fulfill() }
        defer { subscription.cancel() }
        try await SyncPersistenceStore(writer: OwnedModelStore(container: context.container)).saveEncodedState(
            Data([1]))
        _ = try VehicleHistoryFixture(count: 1)
        await fulfillment(of: [unexpected], timeout: 0.3)
        XCTAssertEqual(model.revision, 0)
    }

    private struct DeletionFixture: Sendable {
        let container: ModelContainer
        let codec: CloudRecordCodec
        let remainingOwner: UUID
        let retained: [String: Data]
    }

    private func deletionFixture(owners: Int) throws -> DeletionFixture {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let codec = CloudRecordCodec(zoneID: NativeCloudSyncEnvironment.zoneID)
        var retained: [String: Data] = [:]
        var remainingOwner = UUID()
        for index in 0...owners {
            let vehicle = Vehicle(name: "Owner \(index)")
            let local = FuelingRecord(
                odometer: 1000.123456789, pricePerFuelUnit: 3.459876543,
                fuelAmount: 10.123456789, totalCost: 35.123456789, vehicle: vehicle)
            context.insert(vehicle)
            context.insert(local)
            let template = codec.fuelingRecordToCKRecord(
                local, vehicleRecordID: codec.vehicleToCKRecord(vehicle).recordID)
            let remoteID = UUID().uuidString
            let record = CKRecord(
                recordType: "FuelingRecord", recordID: CKRecord.ID(recordName: remoteID, zoneID: codec.zoneID))
            for key in template.allKeys() { record[key] = template[key] }
            record[CloudRecordCodec.CloudFieldKey.FuelingRecord.id] = remoteID
            record[CloudRecordCodec.CloudFieldKey.FuelingRecord.odometer] = 1300.0
            record[CloudRecordCodec.CloudFieldKey.FuelingRecord.measurements] = nil
            try SyncPersistenceStore.stageInbound(
                .init(
                    kind: .modification, recordName: record.recordID.recordName,
                    recordType: record.recordType, archivedRecord: CloudRecordCodec.archiveFullRecord(record)),
                in: context)
            if index < owners {
                try SyncPersistenceStore.stageInbound(
                    .init(
                        kind: .deletion, recordName: vehicle.id.uuidString,
                        recordType: "Vehicle", archivedRecord: nil), in: context)
            } else {
                remainingOwner = vehicle.id
            }
        }
        try context.save()
        let key = "FuelingRecord:"
        for row in try context.fetch(FetchDescriptor<PendingRemoteChange>()) where row.key.hasPrefix(key) {
            let payload = try SyncPersistenceStore.PendingPayload.decode(row.recordData)
            if try payload.record()?[CloudRecordCodec.CloudFieldKey.FuelingRecord.vehicleRef] as? String
                == remainingOwner.uuidString
            {
                retained[row.key] = row.recordData
            }
        }
        return DeletionFixture(container: container, codec: codec, remainingOwner: remainingOwner, retained: retained)
    }

    private func inboxBytes(in context: ModelContext) throws -> [String: Data] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<PendingRemoteChange>()).map {
                ($0.key, $0.recordData)
            })
    }
}
