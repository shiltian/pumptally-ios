import CloudKit
import XCTest
@testable import CloudKitProbe

/// SDK contract tests, intentionally excluded from the ordinary offline suite.
/// The configured container must be separately provisioned for development.
@MainActor
final class CloudKitProtocolTests: XCTestCase {
    private enum ProbeError: Error { case invalidConfiguration, missingResult }
    private let testContainerID = "iCloud.me.tianshilei.fuelio.CloudKitProbe"
    private let businessBatchSize = 128

    private func withIsolatedZone(_ operation: (CKDatabase, CKRecordZone.ID) async throws -> Void) async throws {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitTestContainer") as? String
        guard identifier == testContainerID,
            Bundle.main.bundleIdentifier == "me.tianshilei.fuelio.CloudKitProbe"
        else {
            XCTFail("The protocol suite requires its separate probe app and approved test container.")
            throw ProbeError.invalidConfiguration
        }
        let container = CKContainer(identifier: testContainerID)
        let status = try await container.accountStatus()
        XCTAssertEqual(
            status, .available,
            "Run the signed probe on an iCloud-signed-in device; your existing account is sufficient.")
        guard status == .available else { throw CKError(.notAuthenticated) }
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "RecoveryProbe-\(UUID())")
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        guard let result = results.saveResults[zoneID] else { throw ProbeError.missingResult }
        _ = try result.get()
        print("CloudKit protocol probe zone: \(zoneID.zoneName)")
        do {
            try await operation(database, zoneID)
        } catch {
            try? await deleteZone(zoneID, database: database)
            throw error
        }
        try await deleteZone(zoneID, database: database)
    }

    private func deleteZone(_ zone: CKRecordZone.ID, database: CKDatabase) async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [zone])
        guard let result = results.deleteResults[zone] else { throw ProbeError.missingResult }
        _ = try result.get()
    }

    private func save(_ records: [CKRecord], database: CKDatabase) async throws -> [CKRecord.ID: CKRecord] {
        let results = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged)
        var saved: [CKRecord.ID: CKRecord] = [:]
        for record in records {
            guard let result = results.saveResults[record.recordID] else { throw ProbeError.missingResult }
            saved[record.recordID] = try result.get()
        }
        return saved
    }

    private func fixture(database: CKDatabase, zoneID: CKRecordZone.ID, count: Int) async throws -> (
        control: CKRecord, records: [CKRecord]
    ) {
        let control = CKRecord(
            recordType: "RecoveryProbeControl", recordID: CKRecord.ID(recordName: "control", zoneID: zoneID))
        control["generation"] = "initial"
        let records = (0..<count).map { index in
            let record = CKRecord(
                recordType: "RecoveryProbeItem", recordID: CKRecord.ID(recordName: "item-\(index)", zoneID: zoneID))
            record["value"] = "baseline"
            return record
        }
        var saved = try await save([control], database: database)
        for start in stride(from: 0, to: records.count, by: businessBatchSize) {
            let chunk = Array(records[start..<min(start + businessBatchSize, records.count)])
            saved.merge(try await save(chunk, database: database)) { _, current in current }
        }
        return (try XCTUnwrap(saved[control.recordID]), try records.map { try XCTUnwrap(saved[$0.recordID]) })
    }

    private func assertBaseline(_ records: [CKRecord], database: CKDatabase) async throws {
        for start in stride(from: 0, to: records.count, by: businessBatchSize) {
            let chunk = records[start..<min(start + businessBatchSize, records.count)]
            let fetched = try await database.records(for: chunk.map(\.recordID))
            for original in chunk {
                let result = try XCTUnwrap(fetched[original.recordID])
                XCTAssertEqual(try result.get()["value"] as? String, "baseline", original.recordID.recordName)
            }
        }
    }

    func testGuardedRecordsPreserveBusinessDoubleBitsAndWireDatePrecision() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 1)
            let record = initial.records[0]
            let numbers = [
                "odometer": 100_000_000.12345679, "fuel": 10.123456789,
                "price": 3.459876543, "cost": 35.123456789,
            ]
            let dates = [
                "date": Date(timeIntervalSinceReferenceDate: 765432100.1234568),
                "createdAt": Date(timeIntervalSince1970: 1700000000.1234567),
            ]
            for (key, value) in numbers { record[key] = value }
            for (key, value) in dates { record[key] = value }
            initial.control["generation"] = "precision-check"
            let driver = NativeBatchProbe(
                database: database,
                batch: .init(recordsToSave: [initial.control, record], atomicByZone: true))
            try await driver.send()
            let fetched = try await database.record(for: record.recordID)
            for (key, value) in numbers {
                XCTAssertEqual((fetched[key] as? Double)?.bitPattern, value.bitPattern, key)
            }
            for (key, value) in dates {
                let actual = try XCTUnwrap(fetched[key] as? Date)
                XCTAssertEqual(actual.timeIntervalSince1970.bitPattern, value.timeIntervalSince1970.bitPattern, key)
                print("Native date precision \(key): wire exact, reference epoch exact=\(actual == value)")
            }
        }
    }

    func testProductionGuardedSessionPublishesThroughTheNativeAdapter() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 800)
            let environment = NativeCloudSyncEnvironment(
                container: CKContainer(identifier: testContainerID), zoneID: zoneID)
            let account = try await environment.accountID()
            let baseline = try CloudSyncControl.baseline(in: zoneID)
            let claim = try baseline.changing(generation: UUID().uuidString, phase: .replacing)
            let claimed = try await GuardedCloudSession(environment: environment, accountID: account, control: claim)
                .send()
            let saves = Array(initial.records.prefix(400))
            for record in saves { record["value"] = "production writer" }
            let deletes = initial.records.suffix(400).map(\.recordID)
            let published = try await GuardedCloudSession(
                environment: environment, accountID: account, control: claimed,
                saving: saves, deleting: deletes
            ).send()
            XCTAssertEqual(published.generation, claimed.generation)
            let finished = try await GuardedCloudSession(
                environment: environment, accountID: account,
                control: published.changing(generation: claimed.generation, phase: .ready)
            ).send()
            XCTAssertEqual(finished.phase, .ready)
            try await assertPublication(
                initial.records,
                saved: Dictionary(uniqueKeysWithValues: saves.map { ($0.recordID, "production writer") }),
                deleted: Set(deletes), database: database)
            let server = try await database.record(for: CloudSyncControl.recordID(in: zoneID))
            XCTAssertEqual(server["phase"] as? String, "ready")
            XCTAssertEqual(server["generation"] as? String, claimed.generation)
        }
    }

    func testProductionGuardedSessionNeverRefreshesARejectedControlToReplayDeletes() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 2)
            let environment = NativeCloudSyncEnvironment(
                container: CKContainer(identifier: testContainerID), zoneID: zoneID)
            let account = try await environment.accountID()
            let claim = try CloudSyncControl.baseline(in: zoneID).changing(
                generation: UUID().uuidString, phase: .replacing)
            let stale = try await GuardedCloudSession(environment: environment, accountID: account, control: claim)
                .send()
            let replacement = try stale.changing(generation: UUID().uuidString, phase: .ready)
            _ = try await GuardedCloudSession(environment: environment, accountID: account, control: replacement).send()
            initial.records[0]["value"] = "obsolete overwrite"
            do {
                _ = try await GuardedCloudSession(
                    environment: environment, accountID: account, control: stale,
                    saving: [initial.records[0]], deleting: [initial.records[1].recordID]
                ).send()
                XCTFail("An obsolete production session must fail")
            } catch { /* The actual server state, checked below, is authoritative. */  }
            try await assertBaseline(initial.records, database: database)
            let server = try await database.record(for: CloudSyncControl.recordID(in: zoneID))
            XCTAssertEqual(server["generation"] as? String, replacement.generation)
        }
    }

    private func assertPublication(
        _ records: [CKRecord], saved: [CKRecord.ID: String], deleted: Set<CKRecord.ID>, database: CKDatabase
    ) async throws {
        for start in stride(from: 0, to: records.count, by: businessBatchSize) {
            let chunk = records[start..<min(start + businessBatchSize, records.count)]
            let fetched = try await database.records(for: chunk.map(\.recordID))
            for record in chunk {
                let result = try XCTUnwrap(fetched[record.recordID])
                if deleted.contains(record.recordID) {
                    guard case .failure(let error) = result else { XCTFail("Deletion not persisted"); continue }
                    XCTAssertEqual((error as? CKError)?.code, .unknownItem)
                } else {
                    XCTAssertEqual(try result.get()["value"] as? String, saved[record.recordID])
                }
            }
        }
    }

    func testEveryBoundedBatchIncludesAFreshControlAcross800Records() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 800)
            var control = initial.control
            var offset = 0
            var failed = false
            var expectedValues: [CKRecord.ID: String] = [:]
            var expectedDeletes = Set<CKRecord.ID>()
            let pending: [CKSyncEngine.PendingRecordZoneChange] =
                [.saveRecord(control.recordID)]
                + initial.records.enumerated().map { index, record in
                    index.isMultiple(of: 2) ? .saveRecord(record.recordID) : .deleteRecord(record.recordID)
                }
            let driver = NativeBatchProbe(
                database: database, pendingChanges: pending,
                nextBatch: {
                    guard !failed, offset < initial.records.count else { return nil }
                    let end = min(offset + self.businessBatchSize, initial.records.count)
                    var saves = [control]
                    var deletes: [CKRecord.ID] = []
                    control["generation"] = "batch-\(offset)"
                    for index in offset..<end {
                        let record = initial.records[index]
                        if index.isMultiple(of: 2) {
                            record["value"] = "replacement"
                            saves.append(record)
                            expectedValues[record.recordID] = "replacement"
                        } else {
                            deletes.append(record.recordID)
                            expectedDeletes.insert(record.recordID)
                        }
                    }
                    offset = end
                    return .init(recordsToSave: saves, recordIDsToDelete: deletes, atomicByZone: true)
                },
                didSend: { result in
                    guard result.failedRecordSaves.isEmpty, result.failedRecordDeletes.isEmpty,
                        let saved = result.savedRecords.first(where: { $0.recordID == control.recordID })
                    else { failed = true; return }
                    // Only the acknowledged native server tag may guard the next batch.
                    control = saved
                })
            try await driver.send()
            XCTAssertFalse(failed)
            XCTAssertEqual(driver.submittedBatches.count, 7)
            XCTAssertEqual(driver.sentBatchCount, 7)
            XCTAssertTrue(
                driver.submittedBatches.allSatisfy {
                    $0.atomicByZone && $0.recordsToSave.contains(where: { $0.recordID == initial.control.recordID })
                        && $0.recordsToSave.count + $0.recordIDsToDelete.count <= businessBatchSize + 1
                })
            XCTAssertEqual(Set(driver.savedIDs), Set(expectedValues.keys).union([control.recordID]))
            XCTAssertEqual(Set(driver.deletedIDs), expectedDeletes)
            try await assertPublication(
                initial.records, saved: expectedValues, deleted: expectedDeletes, database: database)
            let finalControl = try await database.record(for: control.recordID)
            XCTAssertEqual(finalControl["generation"] as? String, "batch-768")
        }
    }

    func testSDKSizeLimitedBatchesKeepTheControlWithEveryMutation() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 800)
            let controlID = initial.control.recordID
            var control = initial.control
            var failed = false
            var batchIndex = 0
            let recordsByID = Dictionary(uniqueKeysWithValues: initial.records.map { ($0.recordID, $0) })
            let expectedValues = Dictionary(
                uniqueKeysWithValues: initial.records.enumerated().compactMap { index, record in
                    if index.isMultiple(of: 2) {
                        record["value"] = "replacement"
                        return (record.recordID, "replacement")
                    }
                    return nil
                })
            let expectedDeletes = Set(
                initial.records.enumerated().compactMap { index, record in
                    index.isMultiple(of: 2) ? nil : record.recordID
                })
            var remaining: [CKSyncEngine.PendingRecordZoneChange] = initial.records.map { record in
                expectedDeletes.contains(record.recordID)
                    ? .deleteRecord(record.recordID) : .saveRecord(record.recordID)
            }
            let driver = NativeBatchProbe(
                database: database, pendingChanges: [.saveRecord(controlID)] + remaining,
                nextBatch: {
                    guard !failed, !remaining.isEmpty else { return nil }
                    let batchControl = control
                    batchControl["generation"] = "sdk-batch-\(batchIndex)"
                    // Put the guard first so the SDK's own size/count limiting
                    // always reserves room for it before choosing business work.
                    guard
                        var batch = await CKSyncEngine.RecordZoneChangeBatch(
                            pendingChanges: [.saveRecord(controlID)] + remaining,
                            recordProvider: { id in id == controlID ? batchControl : recordsByID[id] })
                    else { XCTFail("The SDK did not prepare pending changes"); return nil }
                    let selected = Set(batch.recordsToSave.map(\.recordID) + batch.recordIDsToDelete)
                    guard selected.contains(controlID), selected.count > 1 else {
                        XCTFail("The SDK-sized batch lost its control or made no progress")
                        return nil
                    }
                    batch.atomicByZone = true
                    remaining.removeAll { change in
                        switch change {
                        case .saveRecord(let id), .deleteRecord(let id): return selected.contains(id)
                        @unknown default: return false
                        }
                    }
                    batchIndex += 1
                    return batch
                },
                didSend: { result in
                    guard result.failedRecordSaves.isEmpty, result.failedRecordDeletes.isEmpty,
                        let saved = result.savedRecords.first(where: { $0.recordID == controlID })
                    else { failed = true; return }
                    control = saved
                })
            try await driver.send()
            XCTAssertFalse(failed)
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertGreaterThan(driver.submittedBatches.count, 1)
            XCTAssertEqual(driver.sentBatchCount, driver.submittedBatches.count)
            XCTAssertTrue(
                driver.submittedBatches.allSatisfy {
                    $0.atomicByZone && $0.recordsToSave.contains(where: { $0.recordID == controlID })
                })
            XCTAssertEqual(Set(driver.savedIDs), Set(expectedValues.keys).union([controlID]))
            XCTAssertEqual(Set(driver.deletedIDs), expectedDeletes)
            print(
                "SDK-sized guarded batches: \(driver.submittedBatches.map { $0.recordsToSave.count + $0.recordIDsToDelete.count })"
            )
            try await assertPublication(
                initial.records, saved: expectedValues, deleted: expectedDeletes, database: database)
        }
    }

    func testCancelledHeldBatchCannotMutateAnAdvancedGeneration() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 2)
            initial.control["generation"] = "obsolete"
            initial.records[0]["value"] = "obsolete"
            let requested = expectation(description: "Native engine requested the obsolete batch")
            let release = AsyncStream<Void>.makeStream()
            let oldWriter = NativeBatchProbe(
                database: database,
                batch: .init(
                    recordsToSave: [initial.control, initial.records[0]],
                    recordIDsToDelete: [initial.records[1].recordID], atomicByZone: true),
                beforeSend: {
                    requested.fulfill()
                    for await _ in release.stream { break }
                })
            let sending = Task { try await oldWriter.send() }
            await fulfillment(of: [requested], timeout: 30)
            do {
                // A second real SDK engine advances the server while the first
                // is held at its native delegate boundary. No fake cloud response.
                let control = try await database.record(for: initial.control.recordID)
                control["generation"] = "replacement"
                let replacement = NativeBatchProbe(
                    database: database, batch: .init(recordsToSave: [control], atomicByZone: true))
                try await replacement.send()
                XCTAssertEqual(replacement.savedIDs, [control.recordID])
            } catch {
                release.continuation.yield(())
                release.continuation.finish()
                _ = await sending.result
                throw error
            }
            let cancellation = Task { await oldWriter.cancelOperations() }
            release.continuation.yield(())
            release.continuation.finish()
            _ = await sending.result
            await cancellation.value
            XCTAssertEqual(oldWriter.submittedBatches.count, 1)
            XCTAssertTrue(oldWriter.savedIDs.isEmpty)
            XCTAssertTrue(oldWriter.deletedIDs.isEmpty)
            try await assertBaseline(initial.records, database: database)
            let control = try await database.record(for: initial.control.recordID)
            XCTAssertEqual(control["generation"] as? String, "replacement")
        }
    }

    func testStaleConditionalControlBlocksBothSavesAndDeletesInNativeAtomicBatch() async throws {
        try await withIsolatedZone { database, zoneID in
            // 129 changes exercises a mixed, bounded batch rather than a single
            // delete. Larger/multiple-batch behavior remains a separate gate.
            let initial = try await fixture(database: database, zoneID: zoneID, count: 128)
            let winner = try await database.record(for: initial.control.recordID)
            winner["generation"] = "replacement"
            _ = try await save([winner], database: database)
            initial.control["generation"] = "stale writer"
            let saves = Array(initial.records.prefix(64))
            for record in saves { record["value"] = "stale overwrite" }
            let deletes = initial.records.suffix(64).map(\.recordID)
            let driver = NativeBatchProbe(
                database: database,
                batch: .init(recordsToSave: [initial.control] + saves, recordIDsToDelete: deletes, atomicByZone: true))
            do { try await driver.send() } catch {
                print("Native stale-batch request outcome: \(error)")
            }
            XCTAssertEqual(driver.failedSaves[initial.control.recordID], .serverRecordChanged)
            XCTAssertTrue(driver.savedIDs.isEmpty)
            XCTAssertTrue(driver.deletedIDs.isEmpty)
            try await assertBaseline(initial.records, database: database)
            let control = try await database.record(for: initial.control.recordID)
            XCTAssertEqual(control["generation"] as? String, "replacement")
        }
    }

    func testFreshConditionalControlAllowsMixedNativeBatch() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 2)
            initial.control["generation"] = "replacement"
            initial.records[0]["value"] = "replacement"
            let deletedID = initial.records[1].recordID
            let driver = NativeBatchProbe(
                database: database,
                batch: .init(
                    recordsToSave: [initial.control, initial.records[0]], recordIDsToDelete: [deletedID],
                    atomicByZone: true))
            try await driver.send()
            XCTAssertEqual(Set(driver.savedIDs), Set([initial.control.recordID, initial.records[0].recordID]))
            XCTAssertEqual(driver.deletedIDs, [deletedID])
            let updated = try await database.record(for: initial.records[0].recordID)
            XCTAssertEqual(updated["value"] as? String, "replacement")
            do {
                _ = try await database.record(for: deletedID)
                XCTFail("The acknowledged deletion did not reach CloudKit.")
            } catch let error as CKError { XCTAssertEqual(error.code, .unknownItem) }
        }
    }

    func testOldControlCannotGuardASubsequentBatchAfterAnotherWriterAdvancesIt() async throws {
        try await withIsolatedZone { database, zoneID in
            let initial = try await fixture(database: database, zoneID: zoneID, count: 2)
            initial.control["generation"] = "first batch"
            initial.records[0]["value"] = "first batch"
            let first = NativeBatchProbe(
                database: database,
                batch: .init(recordsToSave: [initial.control, initial.records[0]], atomicByZone: true))
            try await first.send()
            let nextControl = try await database.record(for: initial.control.recordID)
            let otherWriter = try await database.record(for: initial.control.recordID)
            otherWriter["generation"] = "other writer"
            _ = try await save([otherWriter], database: database)
            nextControl["generation"] = "second batch"
            let second = NativeBatchProbe(
                database: database,
                batch: .init(
                    recordsToSave: [nextControl], recordIDsToDelete: [initial.records[1].recordID], atomicByZone: true))
            do { try await second.send() } catch { print("Native subsequent-batch outcome: \(error)") }
            XCTAssertEqual(second.failedSaves[nextControl.recordID], .serverRecordChanged)
            XCTAssertTrue(second.deletedIDs.isEmpty)
            try await assertBaseline([initial.records[1]], database: database)
        }
    }
}

/// Native batches with no application retry, conflict resolver or fake CloudKit
/// response. Never refreshes a failed control record and retries old deletions.
@MainActor
private final class NativeBatchProbe: CKSyncEngineDelegate {
    private let provideBatch: @MainActor () async -> CKSyncEngine.RecordZoneChangeBatch?
    private let didSend: @MainActor (CKSyncEngine.Event.SentRecordZoneChanges) -> Void
    private var engine: CKSyncEngine!
    private(set) var submittedBatches: [CKSyncEngine.RecordZoneChangeBatch] = []
    private(set) var sentBatchCount = 0
    private(set) var savedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private(set) var failedSaves: [CKRecord.ID: CKError.Code] = [:]

    convenience init(
        database: CKDatabase, batch: CKSyncEngine.RecordZoneChangeBatch,
        beforeSend: @escaping @MainActor () async -> Void = {}
    ) {
        var next: CKSyncEngine.RecordZoneChangeBatch? = batch
        self.init(
            database: database,
            pendingChanges: batch.recordsToSave.map { .saveRecord($0.recordID) }
                + batch.recordIDsToDelete.map { .deleteRecord($0) },
            nextBatch: {
                guard let batch = next else { return nil }
                next = nil
                await beforeSend()
                return batch
            })
    }

    init(
        database: CKDatabase, pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        nextBatch: @escaping @MainActor () async -> CKSyncEngine.RecordZoneChangeBatch?,
        didSend: @escaping @MainActor (CKSyncEngine.Event.SentRecordZoneChanges) -> Void = { _ in }
    ) {
        provideBatch = nextBatch
        self.didSend = didSend
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: nil, delegate: self)
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
        engine.state.add(pendingRecordZoneChanges: pendingChanges)
    }

    func send() async throws {
        do { try await engine.sendChanges() } catch {
            await engine.cancelOperations()
            throw error
        }
        await engine.cancelOperations()
    }

    func cancelOperations() async { await engine.cancelOperations() }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        let batch = await provideBatch()
        if let batch { submittedBatches.append(batch) }
        return batch
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .sentRecordZoneChanges(let result) = event {
            sentBatchCount += 1
            savedIDs += result.savedRecords.map(\.recordID)
            deletedIDs += result.deletedRecordIDs
            for failure in result.failedRecordSaves { failedSaves[failure.record.recordID] = failure.error.code }
            didSend(result)
        }
    }
}
