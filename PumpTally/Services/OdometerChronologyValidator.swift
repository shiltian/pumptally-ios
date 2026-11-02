import Foundation

/// Value-only representation used to validate chronology without mutating or
/// depending on SwiftData models.
struct OdometerReadingSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let odometer: Double

    init(record: FuelingRecord) {
        id = record.id
        date = record.date
        odometer = record.odometer
    }

    init(id: UUID, date: Date, odometer: Double) {
        self.id = id
        self.date = date
        self.odometer = odometer
    }
}

struct OdometerChronologyNeighbors: Equatable, Sendable {
    let predecessor: OdometerReadingSnapshot?
    let successor: OdometerReadingSnapshot?
}

enum OdometerChronologyIssue: Equatable, Sendable {
    case invalidReading
    case notGreaterThanPredecessor(OdometerReadingSnapshot)
    case notLessThanSuccessor(OdometerReadingSnapshot)
}

struct OdometerChronologyValidation: Equatable, Sendable {
    let neighbors: OdometerChronologyNeighbors
    let issue: OdometerChronologyIssue?

    var isValid: Bool { issue == nil }
}

enum OdometerChronologyValidator {

    /// Finds records immediately before and after a proposed timestamp.
    ///
    /// The edited record is excluded by ID. Records at the exact same timestamp
    /// are ordered by odometer, preserving support for multiple fill-ups during
    /// the same stop without making cache calculations nondeterministic.
    static func neighbors(
        for candidateDate: Date,
        odometer candidateOdometer: Double,
        records: [OdometerReadingSnapshot],
        excludingRecordID: UUID? = nil
    ) -> OdometerChronologyNeighbors {
        let candidates = records.filter { $0.id != excludingRecordID }

        let predecessor = candidates
            .filter {
                $0.date < candidateDate
                    || ($0.date == candidateDate && $0.odometer < candidateOdometer)
            }
            .max(by: areInIncreasingOrder)

        let successor = candidates
            .filter {
                $0.date > candidateDate
                    || ($0.date == candidateDate && $0.odometer > candidateOdometer)
            }
            .min(by: areInIncreasingOrder)

        return OdometerChronologyNeighbors(
            predecessor: predecessor,
            successor: successor
        )
    }

    /// Validates a proposed reading against both chronological neighbors.
    ///
    /// An unchanged edit is deliberately grandfathered even if legacy data
    /// violates current rules. This lets users edit non-chronology fields
    /// without rewriting or being blocked by existing data.
    static func validate(
        date candidateDate: Date,
        odometer candidateOdometer: Double,
        records: [OdometerReadingSnapshot],
        originalRecord: OdometerReadingSnapshot? = nil
    ) -> OdometerChronologyValidation {
        let neighbors = neighbors(
            for: candidateDate,
            odometer: candidateOdometer,
            records: records,
            excludingRecordID: originalRecord?.id
        )

        if let originalRecord,
           candidateDate == originalRecord.date,
           candidateOdometer == originalRecord.odometer {
            return OdometerChronologyValidation(neighbors: neighbors, issue: nil)
        }

        return validate(odometer: candidateOdometer, neighbors: neighbors)
    }

    static func validate(
        odometer candidateOdometer: Double, neighbors: OdometerChronologyNeighbors
    ) -> OdometerChronologyValidation {
        let issue: OdometerChronologyIssue?
        if !candidateOdometer.isFinite || candidateOdometer <= 0 {
            issue = .invalidReading
        } else if let predecessor = neighbors.predecessor,
                  candidateOdometer <= predecessor.odometer {
            issue = .notGreaterThanPredecessor(predecessor)
        } else if let successor = neighbors.successor,
                  candidateOdometer >= successor.odometer {
            issue = .notLessThanSuccessor(successor)
        } else {
            issue = nil
        }

        return OdometerChronologyValidation(neighbors: neighbors, issue: issue)
    }

    /// Shared deterministic chronology: timestamp, then odometer, then UUID.
    /// The UUID tie-breaker stabilizes pre-existing records whose timestamp and
    /// reading are both equal without rejecting or rewriting them.
    static func areInIncreasingOrder(
        _ lhs: OdometerReadingSnapshot,
        _ rhs: OdometerReadingSnapshot
    ) -> Bool {
        areInIncreasingOrder(
            lhsDate: lhs.date,
            lhsOdometer: lhs.odometer,
            lhsID: lhs.id,
            rhsDate: rhs.date,
            rhsOdometer: rhs.odometer,
            rhsID: rhs.id
        )
    }

    static func areInIncreasingOrder(
        _ lhs: FuelingRecord,
        _ rhs: FuelingRecord
    ) -> Bool {
        areInIncreasingOrder(
            lhsDate: lhs.date,
            lhsOdometer: lhs.odometer,
            lhsID: lhs.id,
            rhsDate: rhs.date,
            rhsOdometer: rhs.odometer,
            rhsID: rhs.id
        )
    }

    static func areInIncreasingOrder(
        lhsDate: Date,
        lhsOdometer: Double,
        lhsID: UUID,
        rhsDate: Date,
        rhsOdometer: Double,
        rhsID: UUID
    ) -> Bool {
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        if lhsOdometer != rhsOdometer { return lhsOdometer < rhsOdometer }
        return lhsID.uuidString < rhsID.uuidString
    }
}

/// One sorted history serves every row in a bulk import. Equal timestamp and
/// odometer groups are skipped together, exactly as the single-edit policy does.
struct OdometerChronologyIndex {
    private let readings: [OdometerReadingSnapshot]

    init(_ readings: [OdometerReadingSnapshot]) {
        self.readings = readings.sorted(by: OdometerChronologyValidator.areInIncreasingOrder)
    }

    func validate(_ candidate: OdometerReadingSnapshot) -> OdometerChronologyValidation {
        func boundary(afterEqual: Bool) -> Int {
            var lower = 0
            var upper = readings.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let value = readings[middle]
                let before =
                    value.date < candidate.date || (value.date == candidate.date && value.odometer < candidate.odometer)
                let equal = value.date == candidate.date && value.odometer == candidate.odometer
                if before || (afterEqual && equal) { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        let before = boundary(afterEqual: false)
        let after = boundary(afterEqual: true)
        return OdometerChronologyValidator.validate(
            odometer: candidate.odometer,
            neighbors: .init(
                predecessor: before > 0 ? readings[before - 1] : nil,
                successor: after < readings.count ? readings[after] : nil))
    }
}
