import Foundation

enum HistorySortOrder: String, CaseIterable, Sendable {
    case dateDescending = "Newest First"
    case dateAscending = "Oldest First"
    case costHighest = "Highest Cost"
    case costLowest = "Lowest Cost"

    var displayName: String {
        switch self {
        case .dateDescending: return String(localized: "Newest First")
        case .dateAscending: return String(localized: "Oldest First")
        case .costHighest: return String(localized: "Highest Cost")
        case .costLowest: return String(localized: "Lowest Cost")
        }
    }
}

struct HistoryRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let date: Date
    let totalCost: Double
    let odometer: Double
    let notes: String?

    init(id: UUID, date: Date, totalCost: Double, odometer: Double, notes: String?) {
        self.id = id
        self.date = date
        self.totalCost = totalCost
        self.odometer = odometer
        self.notes = notes
    }
}

enum HistoryRecordsQuery {
    static func recordIDs(from records: [HistoryRecordSnapshot], searchText: String, sortOrder: HistorySortOrder)
        -> [UUID]
    {
        HistoryRecordsIndex(records: records).recordIDs(searchText: searchText, sortOrder: sortOrder)
    }
}

/// Sorting and numeric search strings are prepared once for a source revision.
/// Keystrokes and subsequent pages do not read or format managed models.
struct HistoryRecordsIndex: Sendable {
    private struct SearchRecord: Sendable {
        let id: UUID
        let notes: String?
        let cost: String
        let odometer: String
    }
    private let searchRecords: [SearchRecord]
    private let chronological: [UUID]
    private let costAscending: [UUID]

    init(records: [HistoryRecordSnapshot]) {
        searchRecords = records.map {
            SearchRecord(
                id: $0.id, notes: $0.notes, cost: String(format: "%.2f", $0.totalCost),
                odometer: String(format: "%.0f", $0.odometer))
        }
        func precedes(_ lhs: HistoryRecordSnapshot, _ rhs: HistoryRecordSnapshot) -> Bool {
            OdometerChronologyValidator.areInIncreasingOrder(
                lhsDate: lhs.date, lhsOdometer: lhs.odometer, lhsID: lhs.id,
                rhsDate: rhs.date, rhsOdometer: rhs.odometer, rhsID: rhs.id)
        }
        chronological = records.sorted(by: precedes).map(\.id)
        costAscending = records.sorted {
            if $0.totalCost != $1.totalCost { return $0.totalCost < $1.totalCost }
            return precedes($0, $1)
        }.map(\.id)
    }

    func recordIDs(searchText: String, sortOrder: HistorySortOrder) -> [UUID] {
        let ordered: [UUID]
        switch sortOrder {
        case .dateAscending: ordered = chronological
        case .dateDescending: ordered = Array(chronological.reversed())
        case .costLowest: ordered = costAscending
        case .costHighest: ordered = Array(costAscending.reversed())
        }
        guard !searchText.isEmpty else { return ordered }
        let query = searchText.lowercased()
        let matches = Set(
            searchRecords.lazy.filter {
                $0.notes?.localizedCaseInsensitiveContains(query) == true || $0.cost.contains(query)
                    || $0.odometer.contains(query)
            }.map(\.id))
        return ordered.filter { matches.contains($0) }
    }
}

/// Stored measurements remain exact; views convert only while displaying them.
struct FuelingHistoryRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let values: FuelingRecordValues
    let storageUnit: UnitSystem
    let previousOdometer: Double
    let distanceDriven: Double
    let cachedEfficiency: Double?
    let hasIntervalCache: Bool

    init(record: FuelingRecord, storageUnit: UnitSystem) {
        id = record.id
        values = FuelingRecordValues(record: record)
        self.storageUnit = storageUnit
        previousOdometer = record.getPreviousOdometer()
        distanceDriven = record.getDistanceDriven()
        cachedEfficiency = record.cachedEfficiency
        hasIntervalCache = record.cachedPreviousOdometer != nil && record.cachedDistanceDriven != nil
    }
}

struct VehicleHistorySource: Sendable {
    let records: [FuelingHistoryRecord]
    let displayUnit: UnitSystem
    let averageEfficiency: Double
}

struct VehicleHistoryPresentation: Sendable {
    let version: UUID
    let recordCount: Int
    let latestRecord: FuelingHistoryRecord?
    let latestEfficiency: Double
    let chartData: PrecomputedChartData
}

struct VehicleHistoryPage: Sendable {
    static let size = 50
    let records: [FuelingHistoryRecord]
    let totalCount: Int
}
