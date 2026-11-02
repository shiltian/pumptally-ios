import XCTest
@testable import PumpTally

final class OdometerChronologyValidatorTests: XCTestCase {
    func testBulkIndexMatchesSingleEditPolicyAcrossLegacyAndEqualTimeHistories() {
        var state: UInt64 = 47
        func number(_ bound: UInt64) -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int((state >> 32) % bound)
        }
        for _ in 0..<100 {
            let history = (0..<80).map { index in
                OdometerReadingSnapshot(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                    date: Date(timeIntervalSince1970: Double(number(15))), odometer: Double(number(20)))
            }
            let index = OdometerChronologyIndex(history)
            for _ in 0..<40 {
                let candidate = OdometerReadingSnapshot(
                    id: UUID(),
                    date: Date(timeIntervalSince1970: Double(number(16))), odometer: Double(number(22)))
                XCTAssertEqual(
                    index.validate(candidate),
                    OdometerChronologyValidator.validate(
                        date: candidate.date, odometer: candidate.odometer, records: history))
            }
        }
    }

    private let baseDate = Date(timeIntervalSince1970: 1_000_000)

    private func reading(_ idSuffix: Int, day: Int, odometer: Double) -> OdometerReadingSnapshot {
        OdometerReadingSnapshot(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            date: baseDate.addingTimeInterval(Double(day) * 86_400),
            odometer: odometer
        )
    }

    func testFirstRecordAcceptsPositiveReading() {
        let result = OdometerChronologyValidator.validate(
            date: baseDate,
            odometer: 100,
            records: []
        )

        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.neighbors.predecessor)
        XCTAssertNil(result.neighbors.successor)
    }

    func testLatestRecordMustBeGreaterThanPredecessor() {
        let previous = reading(1, day: 1, odometer: 100)

        let valid = OdometerChronologyValidator.validate(
            date: baseDate.addingTimeInterval(2 * 86_400),
            odometer: 101,
            records: [previous]
        )
        let invalid = OdometerChronologyValidator.validate(
            date: baseDate.addingTimeInterval(2 * 86_400),
            odometer: 100,
            records: [previous]
        )

        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(invalid.issue, .notGreaterThanPredecessor(previous))
    }

    func testBackdatedFirstRecordMustBeLessThanSuccessor() {
        let next = reading(2, day: 2, odometer: 200)

        let valid = OdometerChronologyValidator.validate(
            date: baseDate.addingTimeInterval(86_400),
            odometer: 150,
            records: [next]
        )
        let invalid = OdometerChronologyValidator.validate(
            date: baseDate.addingTimeInterval(86_400),
            odometer: 200,
            records: [next]
        )

        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(invalid.issue, .notLessThanSuccessor(next))
    }

    func testMiddleRecordMustFallStrictlyBetweenNeighbors() {
        let previous = reading(1, day: 1, odometer: 100)
        let next = reading(3, day: 3, odometer: 300)
        let date = baseDate.addingTimeInterval(2 * 86_400)

        XCTAssertTrue(OdometerChronologyValidator.validate(
            date: date,
            odometer: 200,
            records: [next, previous]
        ).isValid)
        XCTAssertEqual(
            OdometerChronologyValidator.validate(
                date: date,
                odometer: 100,
                records: [previous, next]
            ).issue,
            .notGreaterThanPredecessor(previous)
        )
        XCTAssertEqual(
            OdometerChronologyValidator.validate(
                date: date,
                odometer: 300,
                records: [previous, next]
            ).issue,
            .notLessThanSuccessor(next)
        )
    }

    func testDuplicateTimestampRemainsAllowedForMultipleFillUpsAtOneStop() {
        let existing = reading(1, day: 1, odometer: 100)

        let result = OdometerChronologyValidator.validate(
            date: existing.date,
            odometer: 150,
            records: [existing]
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.neighbors.predecessor, existing)
    }

    func testSameTimestampUsesOdometerToFindBothNeighbors() {
        let lower = reading(1, day: 1, odometer: 100)
        let higher = reading(2, day: 1, odometer: 300)

        let result = OdometerChronologyValidator.validate(
            date: lower.date,
            odometer: 200,
            records: [higher, lower]
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.neighbors.predecessor, lower)
        XCTAssertEqual(result.neighbors.successor, higher)
    }

    func testEditExcludesCurrentRecordWhenFindingNeighbors() {
        let previous = reading(1, day: 1, odometer: 100)
        let edited = reading(2, day: 2, odometer: 200)
        let next = reading(3, day: 3, odometer: 300)

        let result = OdometerChronologyValidator.validate(
            date: edited.date,
            odometer: 250,
            records: [previous, edited, next],
            originalRecord: edited
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.neighbors.predecessor, previous)
        XCTAssertEqual(result.neighbors.successor, next)
    }

    func testUnchangedLegacyInvalidRecordIsGrandfathered() {
        let previous = reading(1, day: 1, odometer: 200)
        let legacy = reading(2, day: 2, odometer: 100)
        let next = reading(3, day: 3, odometer: 150)

        let unchanged = OdometerChronologyValidator.validate(
            date: legacy.date,
            odometer: legacy.odometer,
            records: [previous, legacy, next],
            originalRecord: legacy
        )
        let changed = OdometerChronologyValidator.validate(
            date: legacy.date,
            odometer: 110,
            records: [previous, legacy, next],
            originalRecord: legacy
        )

        XCTAssertTrue(unchanged.isValid)
        XCTAssertEqual(changed.issue, .notGreaterThanPredecessor(previous))
    }

    func testMovingEditedRecordUsesNeighborsAtNewDate() {
        let first = reading(1, day: 1, odometer: 100)
        let edited = reading(3, day: 3, odometer: 300)
        let last = reading(4, day: 4, odometer: 400)
        let movedDate = baseDate.addingTimeInterval(2 * 86_400)

        let result = OdometerChronologyValidator.validate(
            date: movedDate,
            odometer: 200,
            records: [first, edited, last],
            originalRecord: edited
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.neighbors.predecessor, first)
        XCTAssertEqual(result.neighbors.successor, last)
    }

    func testNonPositiveAndNonFiniteReadingsAreRejected() {
        let invalidValues: [Double] = [0, -1, .infinity, -.infinity, .nan]
        for value in invalidValues {
            XCTAssertEqual(
                OdometerChronologyValidator.validate(
                    date: baseDate,
                    odometer: value,
                    records: []
                ).issue,
                .invalidReading
            )
        }
    }
}
