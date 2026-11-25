import XCTest
@testable import PumpTally

@MainActor
final class HistoryRecordsQueryTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        idSuffix: Int,
        day: Int,
        cost: Double,
        odometer: Double,
        notes: String? = nil
    ) -> FuelingHistoryRecord {
        let record = FuelingRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            date: baseDate.addingTimeInterval(Double(day) * 86_400),
            odometer: odometer, pricePerFuelUnit: 3, fuelAmount: 10, totalCost: cost,
            notes: notes, vehicle: Vehicle(name: "History query fixture")
        )
        return FuelingHistoryRecord(record: record, storageUnit: .imperial)
    }

    private func recordIDs(from records: [FuelingHistoryRecord], searchText: String, sortOrder: HistorySortOrder)
        -> [UUID]
    {
        let chronological = records.sorted(by: FuelingHistoryRecord.precedes)
        var index = HistoryRecordsIndex(chronologicalRecords: chronological, displayUnit: .imperial)
        return index.positions(searchText: searchText, sortOrder: sortOrder).map { chronological[$0].id }
    }

    func testSearchMatchesNotesCostAndOdometer() {
        let notes = snapshot(idSuffix: 1, day: 1, cost: 20, odometer: 1_000, notes: "Road Trip")
        let cost = snapshot(idSuffix: 2, day: 2, cost: 12.50, odometer: 2_000)
        let odometer = snapshot(idSuffix: 3, day: 3, cost: 30, odometer: 12_345)
        let records = [notes, cost, odometer]

        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "ROAD",
                sortOrder: .dateDescending
            ),
            [notes.id]
        )
        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "12.50",
                sortOrder: .dateDescending
            ),
            [cost.id]
        )
        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "12345",
                sortOrder: .dateDescending
            ),
            [odometer.id]
        )
    }

    func testEverySortOrder() {
        let oldestExpensive = snapshot(idSuffix: 1, day: 1, cost: 80, odometer: 1_000)
        let middleCheap = snapshot(idSuffix: 2, day: 2, cost: 20, odometer: 2_000)
        let newestMedium = snapshot(idSuffix: 3, day: 3, cost: 50, odometer: 3_000)
        let records = [middleCheap, newestMedium, oldestExpensive]

        XCTAssertEqual(
            recordIDs(from: records, searchText: "", sortOrder: .dateDescending),
            [newestMedium.id, middleCheap.id, oldestExpensive.id]
        )
        XCTAssertEqual(
            recordIDs(from: records, searchText: "", sortOrder: .dateAscending),
            [oldestExpensive.id, middleCheap.id, newestMedium.id]
        )
        XCTAssertEqual(
            recordIDs(from: records, searchText: "", sortOrder: .costHighest),
            [oldestExpensive.id, newestMedium.id, middleCheap.id]
        )
        XCTAssertEqual(
            recordIDs(from: records, searchText: "", sortOrder: .costLowest),
            [middleCheap.id, newestMedium.id, oldestExpensive.id]
        )
    }

    func testSameTimestampReversesFullCanonicalOrder() {
        let lowerOdometer = snapshot(idSuffix: 2, day: 1, cost: 20, odometer: 1_000)
        let lowerID = snapshot(idSuffix: 1, day: 1, cost: 20, odometer: 2_000)
        let higherID = snapshot(idSuffix: 3, day: 1, cost: 20, odometer: 2_000)
        let records = [higherID, lowerID, lowerOdometer]

        let ascending = [lowerOdometer.id, lowerID.id, higherID.id]
        let descending = [higherID.id, lowerID.id, lowerOdometer.id]

        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "",
                sortOrder: .dateAscending
            ),
            ascending
        )
        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "",
                sortOrder: .dateDescending
            ),
            descending
        )
        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "",
                sortOrder: .costLowest
            ),
            ascending
        )
        XCTAssertEqual(
            recordIDs(
                from: records,
                searchText: "",
                sortOrder: .costHighest
            ),
            descending
        )
    }
}
