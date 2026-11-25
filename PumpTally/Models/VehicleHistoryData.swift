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

/// Date sorting reuses the source order. Cost sorting and search strings are
/// built on first use and reused for the life of that source.
struct HistoryRecordsIndex: Sendable {
    private struct SearchNumbers: Sendable {
        let cost: String
        let odometer: String
    }
    private let records: [FuelingHistoryRecord]
    private let displayUnit: UnitSystem
    private var searchNumbers: [SearchNumbers]?
    private var costAscending: [Int]?

    init(chronologicalRecords: [FuelingHistoryRecord], displayUnit: UnitSystem) {
        records = chronologicalRecords
        self.displayUnit = displayUnit
    }

    mutating func positions(searchText: String, sortOrder: HistorySortOrder) -> [Int] {
        let ordered: [Int]
        switch sortOrder {
        case .dateAscending:
            ordered = Array(records.indices)
        case .dateDescending:
            ordered = Array(records.indices.reversed())
        case .costLowest, .costHighest:
            let ascending =
                costAscending
                ?? records.indices.sorted {
                    let left = records[$0].values.totalCost
                    let right = records[$1].values.totalCost
                    if left != right { return left < right }
                    return $0 < $1
                }
            costAscending = ascending
            ordered = sortOrder == .costLowest ? ascending : Array(ascending.reversed())
        }
        guard !searchText.isEmpty else { return ordered }
        let numbers =
            searchNumbers
            ?? records.map { record in
                SearchNumbers(
                    cost: String(format: "%.2f", record.values.totalCost),
                    odometer: String(
                        format: "%.0f", displayUnit.distanceValue(record.values.odometer, from: record.storageUnit)))
            }
        searchNumbers = numbers
        let query = searchText.lowercased()
        return ordered.filter { position in
            records[position].values.notes?.localizedCaseInsensitiveContains(query) == true
                || numbers[position].cost.contains(query) || numbers[position].odometer.contains(query)
        }
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

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        OdometerChronologyValidator.areInIncreasingOrder(
            lhsDate: lhs.values.date, lhsOdometer: lhs.values.odometer, lhsID: lhs.id,
            rhsDate: rhs.values.date, rhsOdometer: rhs.values.odometer, rhsID: rhs.id)
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
