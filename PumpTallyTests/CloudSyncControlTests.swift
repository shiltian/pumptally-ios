import CloudKit
import XCTest

@testable import PumpTally

@MainActor
final class CloudSyncControlTests: XCTestCase {
    private let zone = NativeCloudSyncEnvironment.zoneID

    func testBusinessSuccessRequiresItsAtomicControlAcknowledgement() throws {
        let control = try CloudSyncControl.baseline(in: zone)
        let record = CKRecord(recordType: "Vehicle", recordID: CKRecord.ID(recordName: "chosen", zoneID: zone))
        XCTAssertThrowsError(try control.outcome(of: .init(savedRecords: [record]))) {
            XCTAssertEqual($0 as? CloudRecoveryError, .incompleteBatch)
        }
        XCTAssertThrowsError(try control.outcome(of: .init(deletedRecordIDs: [record.recordID])))
        let result = try control.outcome(of: .init(savedRecords: [control.batchRecord(), record]))
        XCTAssertEqual(result.business.savedRecords.map(\.recordID), [record.recordID])
    }

    func testSameGenerationControlConflictRequeuesAbortedSavesAndDeletes() throws {
        let control = try CloudSyncControl.baseline(in: zone)
        let save = CKRecord(recordType: "Vehicle", recordID: CKRecord.ID(recordName: "save", zoneID: zone))
        let deletion = CKRecord.ID(recordName: "delete", zoneID: zone)
        let server = control.batchRecord()
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let outcome = try control.outcome(
            of: .init(
                failedSaves: [(control.batchRecord(), conflict), (save, CKError(.batchRequestFailed))],
                failedDeletes: [deletion: CKError(.batchRequestFailed)]))
        XCTAssertEqual(outcome.retryIDs, [save.recordID, deletion])
        XCTAssertTrue(outcome.business.failedSaves.isEmpty)
        XCTAssertTrue(outcome.business.failedDeletes.isEmpty)
        XCTAssertEqual(outcome.control.record["transaction"] as? String, server["transaction"] as? String)
    }

    func testBusinessConflictResolvesRootAndRequeuesAtomicallyAbortedPeers() throws {
        let control = try CloudSyncControl.baseline(in: zone)
        let save = CKRecord(recordType: "Vehicle", recordID: CKRecord.ID(recordName: "save", zoneID: zone))
        let deletion = CKRecord.ID(recordName: "delete", zoneID: zone)
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: save])
        let outcome = try control.outcome(
            of: .init(
                failedSaves: [(control.batchRecord(), CKError(.batchRequestFailed)), (save, conflict)],
                failedDeletes: [deletion: CKError(.batchRequestFailed)]))
        XCTAssertEqual(outcome.business.failedSaves.first?.record.recordID, save.recordID)
        XCTAssertEqual(outcome.business.failedSaves.first?.error.code, .serverRecordChanged)
        XCTAssertEqual(outcome.retryIDs, [deletion])
        XCTAssertTrue(outcome.business.failedDeletes.isEmpty)
    }

    func testReplacementControlNeverPermitsRetryingOldIntent() throws {
        let control = try CloudSyncControl.baseline(in: zone)
        for phase in [CloudSyncControl.Phase.replacing, .ready] {
            let server = try control.changing(generation: UUID().uuidString, phase: phase)
            let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server.record])
            XCTAssertThrowsError(try control.outcome(of: .init(failedSaves: [(control.batchRecord(), conflict)]))) {
                XCTAssertEqual($0 as? CloudRecoveryError, phase == .ready ? .generationChanged : .replacementInProgress)
            }
        }
    }

    func testUnsupportedControlFailsClosed() throws {
        let record = try CloudSyncControl.baseline(in: zone).record
        record["version"] = 2
        XCTAssertThrowsError(try CloudSyncControl(record: record, zone: zone)) {
            XCTAssertEqual($0 as? CloudRecoveryError, .invalidControl)
        }
    }
}
