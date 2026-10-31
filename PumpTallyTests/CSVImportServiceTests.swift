import XCTest
import SwiftData
@testable import PumpTally

@MainActor
final class CSVImportServiceTests: XCTestCase {
    private enum TestError: Error {
        case commitFailed
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV3.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func validCSV(rows: String) -> String {
        """
        date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes
        \(rows)
        """
    }

    func testParseReturnsValueSnapshotsForEveryValidRow() throws {
        let records = try CSVImportService.parse(
            validCSV(
                rows: """
                2024-01-15,100,3.459,10.5,36.32,full,First
                01/22/2024,200,3.599,11,39.59,true,Second
                """
            )
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.lineNumber), [2, 3])
        XCTAssertEqual(records.map(\.odometer), [100, 200])
        XCTAssertEqual(records.map(\.fillUpType), [.full, .partial])
    }

    func testParseRejectsEntireFileWhenOneRowIsMalformed() {
        let csv = validCSV(
            rows: """
            2024-01-15,100,3.459,10.5,36.32,full,Valid
            invalid-date,200,3.599,11,39.59,full,Invalid
            2024-01-29,300,3.699,12,44.39,full,Would otherwise be valid
            """
        )

        XCTAssertThrowsError(try CSVImportService.parse(csv)) { error in
            guard case CSVImportError.invalidRow(let line, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    func testParseRejectsNonFiniteAndNonPositiveNumbers() {
        for invalidValue in ["0", "-1", "nan", "inf"] {
            let csv = validCSV(
                rows: "2024-01-15,100,3.459,\(invalidValue),36.32,full,Invalid"
            )
            XCTAssertThrowsError(try CSVImportService.parse(csv))
        }
    }

    func testParseRejectsUnsupportedHeaderOrderAndExtraColumns() {
        let wrongHeader = """
        odometer,date,pricePerFuelUnit,fuelAmount,totalCost
        100,2024-01-15,3.459,10.5,36.32
        """
        XCTAssertThrowsError(try CSVImportService.parse(wrongHeader))

        let extraColumn = validCSV(
            rows: "2024-01-15,100,3.459,10.5,36.32,full,Note,Unexpected"
        )
        XCTAssertThrowsError(try CSVImportService.parse(extraColumn))
    }

    func testParsePreservesEscapedQuotesAndRejectsUnclosedQuotes() throws {
        let records = try CSVImportService.parse(
            validCSV(
                rows: "2024-01-15,100,3.459,10.5,36.32,full,\"A \"\"quoted\"\" note\""
            )
        )
        XCTAssertEqual(records.first?.notes, "A \"quoted\" note")

        let unclosed = validCSV(
            rows: "2024-01-15,100,3.459,10.5,36.32,full,\"Unclosed"
        )
        XCTAssertThrowsError(try CSVImportService.parse(unclosed))
    }

    func testExportImportRoundTripPreservesMultilineNote() throws {
        let vehicle = Vehicle(name: "Test Car")
        let original = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_000),
            odometer: 100,
            pricePerFuelUnit: 3,
            fuelAmount: 10,
            totalCost: 30,
            notes: "First line\nSecond line with \"quotes\"",
            vehicle: vehicle
        )

        let csv = CSVService.exportRecords([
            CSVService.RecordSnapshot(record: original)
        ])
        let imported = try CSVImportService.parse(csv)

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.notes, original.notes)
    }

    func testCRLFInputReportsPhysicalLineNumber() {
        let csv = "date,odometer,price,fuel,cost\r\n"
            + "2024-01-15,100,3,10,30\r\n"
            + "invalid-date,200,3,10,30\r\n"

        XCTAssertThrowsError(try CSVImportService.parse(csv)) { error in
            guard case CSVImportError.invalidRow(let line, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    func testLegacyZeroPriceAndCostRemainImportable() throws {
        let records = try CSVImportService.parse(
            validCSV(
                rows: "2024-01-15,100,0,10,0,full,Free fill-up"
            )
        )

        XCTAssertEqual(records.first?.pricePerFuelUnit, 0)
        XCTAssertEqual(records.first?.totalCost, 0)
    }

    func testParseAllowsBlankLinesBeforeHeaderAndBetweenRows() throws {
        let csv = """

        date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes

        2024-01-15,100,3.459,10.5,36.32,full,First

        2024-01-22,200,3.599,11,39.59,full,Second
        """

        let records = try CSVImportService.parse(csv)
        XCTAssertEqual(records.map(\.lineNumber), [4, 6])
    }

    func testChronologyValidationChecksExistingAndImportedRecordsTogether() throws {
        let existing = [
            OdometerReadingSnapshot(
                id: UUID(),
                date: Date(timeIntervalSince1970: 100),
                odometer: 100
            )
        ]
        let records = [
            CSVImportRecordSnapshot(
                id: UUID(),
                lineNumber: 2,
                date: Date(timeIntervalSince1970: 200),
                odometer: 300,
                pricePerFuelUnit: 3,
                fuelAmount: 10,
                totalCost: 30,
                fillUpType: .full,
                notes: nil
            ),
            CSVImportRecordSnapshot(
                id: UUID(),
                lineNumber: 3,
                date: Date(timeIntervalSince1970: 300),
                odometer: 200,
                pricePerFuelUnit: 3,
                fuelAmount: 10,
                totalCost: 30,
                fillUpType: .full,
                notes: nil
            )
        ]

        XCTAssertThrowsError(
            try CSVImportService.validateChronology(
                records,
                existingRecords: existing
            )
        ) { error in
            guard case CSVImportError.invalidChronology = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testImportCommitsRecordsAndCachesOnce() throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Test Car")
        context.insert(vehicle)
        try context.save()
        let records = try CSVImportService.parse(
            validCSV(
                rows: """
                2024-01-15,100,3.459,10.5,36.32,full,First
                2024-01-22,200,3.599,11,39.59,full,Second
                """
            )
        )
        var commitCount = 0

        let imported = try CSVImportService.importRecords(
            records,
            into: vehicle,
            context: context,
            commit: {
                commitCount += 1
                try $0.save()
            }
        )

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(vehicle.cachedRecordCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 2)
    }

    func testImportRejectsChronologyBeforeMutatingContext() throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Test Car")
        context.insert(vehicle)
        let existing = FuelingRecord(
            date: Date(timeIntervalSince1970: 100),
            odometer: 100,
            pricePerFuelUnit: 3,
            fuelAmount: 10,
            totalCost: 30,
            vehicle: vehicle
        )
        context.insert(existing)
        try context.save()

        let invalid = [
            CSVImportRecordSnapshot(
                id: UUID(),
                lineNumber: 2,
                date: Date(timeIntervalSince1970: 200),
                odometer: 50,
                pricePerFuelUnit: 3,
                fuelAmount: 10,
                totalCost: 30,
                fillUpType: .full,
                notes: nil
            )
        ]

        XCTAssertThrowsError(
            try CSVImportService.importRecords(
                invalid,
                into: vehicle,
                context: context
            )
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [existing.id])
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedImportCommitLeavesNoPartialRecordsOrCacheChanges() throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Test Car")
        context.insert(vehicle)
        try context.save()
        let records = try CSVImportService.parse(
            validCSV(
                rows: """
                2024-01-15,100,3.459,10.5,36.32,full,First
                2024-01-22,200,3.599,11,39.59,full,Second
                """
            )
        )

        XCTAssertThrowsError(
            try CSVImportService.importRecords(
                records,
                into: vehicle,
                context: context,
                commit: { _ in throw TestError.commitFailed }
            )
        )

        XCTAssertTrue((vehicle.fuelingRecords ?? []).isEmpty)
        XCTAssertNil(vehicle.cachedRecordCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }
}
