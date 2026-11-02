import XCTest
@testable import PumpTally

final class CSVServiceTests: XCTestCase {
    private let vehicle = Vehicle(name: "Test Car")

    private func record(
        idSuffix: Int,
        date: Date,
        odometer: Double,
        notes: String? = nil
    ) -> FuelingRecord {
        FuelingRecord(
            id: UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012d",
                idSuffix
            ))!,
            date: date,
            odometer: odometer,
            pricePerFuelUnit: 3.459,
            fuelAmount: 10.5,
            totalCost: 36.32,
            fillUpType: .full,
            notes: notes,
            vehicle: vehicle
        )
    }

    func testCSVHeaderContract() {
        XCTAssertEqual(
            CSVService.csvHeader,
            "date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes"
        )
    }

    func testExportEmptyRecordsContainsHeaderAndTrailingNewline() {
        XCTAssertEqual(
            CSVService.exportRecords([]),
            CSVService.csvHeader + "\n"
        )
    }

    func testSnapshotExportEscapesNotesAndPreservesFields() {
        let value = record(
            idSuffix: 1,
            date: Date(timeIntervalSince1970: 1_000),
            odometer: 12_500,
            notes: "Note with \"quotes\" and, commas"
        )

        let csv = CSVService.exportRecords([
            CSVService.RecordSnapshot(record: value)
        ])

        XCTAssertTrue(csv.hasPrefix(CSVService.csvHeader + "\n"))
        XCTAssertTrue(csv.contains("12500.0"))
        XCTAssertTrue(csv.contains("3.459"))
        XCTAssertTrue(csv.contains("10.5"))
        XCTAssertTrue(csv.contains("36.32"))
        XCTAssertTrue(csv.contains("full"))
        XCTAssertTrue(csv.contains("\"Note with \"\"quotes\"\" and, commas\""))
    }

    func testExportUsesCanonicalDateOdometerUUIDOrdering() {
        let date = Date(timeIntervalSince1970: 1_000)
        let lowestOdometer = record(idSuffix: 3, date: date, odometer: 100, notes: "first")
        let lowerID = record(idSuffix: 1, date: date, odometer: 200, notes: "second")
        let higherID = record(idSuffix: 2, date: date, odometer: 200, notes: "third")

        let csv = CSVService.exportRecords(
            [higherID, lowerID, lowestOdometer].map(CSVService.RecordSnapshot.init(record:))
        )
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].contains("\"first\""))
        XCTAssertTrue(lines[2].contains("\"second\""))
        XCTAssertTrue(lines[3].contains("\"third\""))
    }

    func testImportHandlesCommasAndEscapedQuotes() throws {
        let rows = try CSVImportService.parse(
            CSVService.csvHeader + "\n" + "2024-01-15,12500,3.459,10.5,36.32,full,\"A \"\"quoted\"\", note\"")
        XCTAssertEqual(rows.first?.notes, "A \"quoted\", note")
        XCTAssertEqual(rows.first?.odometer, 12500)
    }
}
