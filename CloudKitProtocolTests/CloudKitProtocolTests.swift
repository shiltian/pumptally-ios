import CloudKit
import XCTest

/// SDK contract tests, intentionally excluded from the ordinary offline suite.
/// The configured container must be separately provisioned for development.
@MainActor
final class CloudKitProtocolTests: XCTestCase {
    private enum ProbeError: Error { case productionContainer, missingResult }
    private let productionContainerID = "iCloud.me.tianshilei.fuelio"

    private func withIsolatedZone(_ operation: (CKDatabase, CKRecordZone.ID) async throws -> Void) async throws {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitTestContainer") as? String ?? ""
        guard !identifier.isEmpty else {
            throw XCTSkip(
                "Supply CLOUDKIT_TEST_CONTAINER_IDENTIFIER for a separately provisioned development container.")
        }
        guard identifier != productionContainerID else {
            XCTFail("The protocol probe refuses the production container.")
            throw ProbeError.productionContainer
        }
        let container = CKContainer(identifier: identifier)
        let status = try await container.accountStatus()
        XCTAssertEqual(status, .available, "Sign the isolated host and use a test iCloud account.")
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
        let saved = try await save([control] + records, database: database)
        return (try XCTUnwrap(saved[control.recordID]), try records.map { try XCTUnwrap(saved[$0.recordID]) })
    }

    private func assertBaseline(_ records: [CKRecord], database: CKDatabase) async throws {
        for original in records {
            let fetched = try await database.record(for: original.recordID)
            XCTAssertEqual(fetched["value"] as? String, "baseline", original.recordID.recordName)
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

/// A single native batch, with no application retry, conflict resolver or fake
/// CloudKit response. Never refreshes a failed control record and retries deletes.
@MainActor
private final class NativeBatchProbe: CKSyncEngineDelegate {
    private var batch: CKSyncEngine.RecordZoneChangeBatch?
    private var engine: CKSyncEngine!
    private(set) var savedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private(set) var failedSaves: [CKRecord.ID: CKError.Code] = [:]

    init(database: CKDatabase, batch: CKSyncEngine.RecordZoneChangeBatch) {
        self.batch = batch
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: nil, delegate: self)
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
        engine.state.add(
            pendingRecordZoneChanges: batch.recordsToSave.map { .saveRecord($0.recordID) }
                + batch.recordIDsToDelete.map { .deleteRecord($0) })
    }

    func send() async throws {
        do { try await engine.sendChanges() } catch {
            await engine.cancelOperations()
            throw error
        }
        await engine.cancelOperations()
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async
        -> CKSyncEngine.RecordZoneChangeBatch?
    {
        defer { batch = nil }
        return batch
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .sentRecordZoneChanges(let result) = event {
            savedIDs += result.savedRecords.map(\.recordID)
            deletedIDs += result.deletedRecordIDs
            for failure in result.failedRecordSaves { failedSaves[failure.record.recordID] = failure.error.code }
        }
    }
}
