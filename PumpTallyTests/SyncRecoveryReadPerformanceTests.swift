import XCTest

@testable import PumpTally

/// Fixtures are prepared outside measurement. Each iteration creates a fresh
/// native context and includes inbox decoding plus scoped review assessment.
@MainActor
final class SyncRecoveryReadPerformanceTests: XCTestCase {
    private func measureAssessment(localCount: Int, incomingCount: Int) throws {
        let fixture = try RecoveryReadFixture(localCount: localCount, incomingCount: incomingCount)
        let container = fixture.history.container
        let options = XCTMeasureOptions()
        options.iterationCount = 4
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let completed = expectation(description: "Assess a retained inbox off MainActor")
            Task {
                do {
                    let result = try await SyncRecoveryReader.read(container: container) {
                        try SyncReviewService.assessment(in: $0.modelContext)
                    }
                    XCTAssertEqual(result.unitConfirmations.count, incomingCount)
                    XCTAssertEqual(result.metrics.inbox.loads, 1)
                    XCTAssertEqual(result.metrics.inbox.payloadsDecoded, incomingCount)
                    XCTAssertEqual(result.metrics.inbox.recordsUnarchived, incomingCount)
                    XCTAssertEqual(result.metrics.vehiclesRead, 1)
                    XCTAssertEqual(result.metrics.fuelingRecordsRead, incomingCount)
                } catch { XCTFail("\(error)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 60)
        }
    }

    func testRetainedInbox800() throws { try measureAssessment(localCount: 800, incomingCount: 800) }
    func testRetainedInbox3200() throws { try measureAssessment(localCount: 3200, incomingCount: 3200) }
    func testRetainedInbox12800() throws { try measureAssessment(localCount: 12800, incomingCount: 12800) }
    func testSinglePendingChangeWith12800LocalRecords() throws {
        try measureAssessment(localCount: 12800, incomingCount: 1)
    }
}
