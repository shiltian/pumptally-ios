import SwiftData
import XCTest
import os

@testable import PumpTally

@MainActor
final class CSVImportServiceTests: XCTestCase {
    private enum TestError: Error {
        case commitFailed
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: SchemaV5.self)
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
        let csv =
            "date,odometer,price,fuel,cost\r\n"
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
            ),
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

    func testImportCommitsRecordsAndCachesOnce() async throws {
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
        let commitCount = OSAllocatedUnfairLock(initialState: 0)

        let imported = try await FuelingRecordPersistenceService(
            container: context.container,
            commit: {
                commitCount.withLock { $0 += 1 }
                try $0.modelContext.save()
            }
        ).importRecords(records, vehicleID: vehicle.id, storageUnit: vehicle.unitSystem)

        XCTAssertEqual(commitCount.withLock { $0 }, 1)
        XCTAssertEqual(imported.count, 2)
        let saved = ModelContext(context.container)
        XCTAssertEqual(try saved.fetch(FetchDescriptor<Vehicle>()).first?.cachedRecordCount, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 2)
    }

    func testImportRejectsChronologyBeforeMutatingContext() async throws {
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

        do {
            _ =
                try await FuelingRecordPersistenceService(container: context.container).importRecords(
                    invalid,
                    vehicleID: vehicle.id,
                    storageUnit: vehicle.unitSystem
                )

            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(vehicle.fuelingRecords?.map(\.id), [existing.id])
        XCTAssertFalse(context.hasChanges)
    }

    func testFailedImportCommitLeavesNoPartialRecordsOrCacheChanges() async throws {
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

        do {
            _ =
                try await FuelingRecordPersistenceService(
                    container: context.container, commit: { _ in throw TestError.commitFailed }
                )
                .importRecords(records, vehicleID: vehicle.id, storageUnit: vehicle.unitSystem)

            XCTFail("Expected operation to throw")
        } catch let caughtError {
            _ = caughtError
        }

        XCTAssertTrue((vehicle.fuelingRecords ?? []).isEmpty)
        XCTAssertNil(vehicle.cachedRecordCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        XCTAssertFalse(context.hasChanges)
    }

    func testNotesPreserveWhitespaceUnicodeAndAllEmbeddedLineEndings() throws {
        let note = "  café 😀\r\nsecond\rthird\nfourth\t  "
        let csv = CSVService.csvHeader + "\r\n2024-01-15,100,3,10,30,full,\"\(note)\"\r\n"
        let row = try XCTUnwrap(CSVImportService.parse(csv).first)
        XCTAssertEqual(Array(try XCTUnwrap(row.notes).utf8), Array(note.utf8))
    }

    func testUnquotedNotesKeepLeadingAndTrailingWhitespaceWhileNumbersAreTrimmed() throws {
        let note = "  café\t  "
        let csv = CSVService.csvHeader + "\n2024-01-15, 100 , 3 , 10 , 30 ,full," + note
        let row = try XCTUnwrap(CSVImportService.parse(csv).first)
        XCTAssertEqual(Array(try XCTUnwrap(row.notes).utf8), Array(note.utf8))
        XCTAssertEqual(row.odometer, 100)
    }

    func testLegacyVariableWidthRowsAndEmptyFinalCellsAtEOF() throws {
        let csv =
            CSVService.csvHeader
            + "\n2024-01-15,100,3,10,30\n2024-01-16,200,3,10,30,partial\n2024-01-17,300,3,10,30,full,\"\""
        let rows = try CSVImportService.parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.fillUpType), [.full, .partial, .full])
        XCTAssertTrue(rows.allSatisfy { $0.notes == nil })
        let trailingComma = try CSVImportService.parse(CSVService.csvHeader + "\n2024-01-15,100,3,10,30,full,")
        XCTAssertNil(trailingComma.first?.notes)
        let quotedNumbers = try CSVImportService.parse(
            CSVService.csvHeader + "\n\"2024-01-15\",\"100\",\"3\",\"10\",\"30\",\"full\",Plain")
        XCTAssertEqual(quotedNumbers.first?.notes, "Plain")
    }

    func testMalformedQuotesNeverReturnAPartialImport() {
        for row in [
            "2024-01-15,100,3,10,30,full,\"unclosed",
            "2024-01-15,100,3,10,30,full,\"closed\"junk",
            "2024-01-15,100,3,10,30,full,unclosed\"",
        ] {
            XCTAssertThrowsError(try CSVImportService.parse(CSVService.csvHeader + "\n" + row))
        }
    }

    func testBOMAliasesAndPhysicalLinesAfterMultilineNotes() throws {
        let csv = "\u{FEFF}\nDate,Odometer,Price,Fuel,Cost\r\n\r\n2024-01-15,100,3,10,30\r\n"
        XCTAssertEqual(try CSVImportService.parse(csv).first?.lineNumber, 4)
        let invalid = CSVService.csvHeader + "\n2024-01-15,100,3,10,30,full,\"a\r\nb\nc\"\n\ninvalid,200,3,10,30"
        XCTAssertThrowsError(try CSVImportService.parse(invalid)) { error in
            guard case CSVImportError.invalidRow(let line, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(line, 6)
        }
    }

    func testAnUnorderableLegacyHistoryStopsImportValidation() throws {
        let rows = try CSVImportService.parse(validCSV(rows: "2024-01-15,100,3,10,30,full,CSV"))
        for reading in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(
                try CSVImportService.validateChronology(
                    rows,
                    existingRecords: [.init(id: UUID(), date: Date(), odometer: reading)]))
        }
    }

    func testRepeatExportSurfacesDuplicatesAndSkippingPerformsNoSave() async throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Original")
        context.insert(vehicle)
        let record = FuelingRecord(
            date: Date(timeIntervalSince1970: 1000.875), odometer: 100.123456789,
            pricePerFuelUnit: 3.123456789, fuelAmount: 10.123456789, totalCost: 30.123456789,
            fillUpType: .full, notes: "  original\r\n ", vehicle: vehicle)
        context.insert(record)
        try context.save()
        let originalBits = [record.odometer.bitPattern, record.fuelAmount.bitPattern, record.totalCost.bitPattern]
        let csv = CSVService.exportRecords([CSVService.RecordSnapshot(record: record)])
        let count = OSAllocatedUnfairLock(initialState: 0)
        let service = FuelingRecordPersistenceService(
            container: context.container,
            commit: {
                count.withLock { $0 += 1 }; try $0.modelContext.save()
            })
        let plan = try await service.prepareImport(
            CSVImportService.parse(csv), vehicleID: vehicle.id, sourceUnit: .imperial)
        XCTAssertEqual(plan.possibleDuplicateIDs.count, 1)
        let ids = try await service.importRecords(plan: plan, duplicates: .skipPossibleDuplicates)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(count.withLock { $0 }, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertEqual(
            [record.odometer.bitPattern, record.fuelAmount.bitPattern, record.totalCost.bitPattern], originalBits)
    }

    func testIdenticalLookingRowsRequireAChoiceAndCanBeImportedExplicitly() async throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Original")
        context.insert(vehicle); try context.save()
        let row = "2024-01-15,100,3,10,30,full,Same"
        let service = FuelingRecordPersistenceService(container: context.container)
        let plan = try await service.prepareImport(
            CSVImportService.parse(validCSV(rows: row + "\n" + row)),
            vehicleID: vehicle.id, sourceUnit: .imperial)
        XCTAssertEqual(plan.possibleDuplicateIDs.count, 1)
        XCTAssertEqual(plan.selectedRecords(.skipPossibleDuplicates).count, 1)
        let ids = try await service.importRecords(plan: plan, duplicates: .importAll)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 2)
    }

    func testSourceUnitsAreConvertedIndependentlyOfDisplayPreference() async throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Original", unitSystem: .imperial)
        vehicle.displayUnitSystem = .metric
        context.insert(vehicle); try context.save()
        let service = FuelingRecordPersistenceService(container: context.container)
        let plan = try await service.prepareImport(
            CSVImportService.parse(validCSV(rows: "2024-01-15,160.9344,2,37.85411784,75.70823568,full,Metric")),
            vehicleID: vehicle.id, sourceUnit: .metric)
        XCTAssertEqual(try XCTUnwrap(plan.records.first).odometer, 100, accuracy: 0.000001)
        let ids = try await service.importRecords(plan: plan, duplicates: .importAll)
        let saved = ModelContext(context.container)
        let record = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.id, ids.first)
        XCTAssertEqual(record.odometer, 100, accuracy: 0.000001)
        XCTAssertEqual(
            record.fuelAmount, Measurement(value: 37.85411784, unit: UnitVolume.liters).converted(to: .gallons).value)
        XCTAssertEqual(record.totalCost, 75.70823568)
    }

    func testConcurrentHistoryEditInvalidatesThePlanWithoutPartialImport() async throws {
        let context = try makeContext()
        let vehicle = Vehicle(name: "Original")
        context.insert(vehicle); try context.save()
        let service = FuelingRecordPersistenceService(container: context.container)
        let plan = try await service.prepareImport(
            CSVImportService.parse(validCSV(rows: "2024-01-15,200,3,10,30,full,CSV")),
            vehicleID: vehicle.id, sourceUnit: .imperial)
        let new = FuelingRecord(
            date: Date(timeIntervalSince1970: 1000), odometer: 100,
            pricePerFuelUnit: 3, fuelAmount: 10, totalCost: 30, vehicle: vehicle)
        context.insert(new); try context.save()
        do {
            _ = try await service.importRecords(plan: plan, duplicates: .importAll)
            XCTFail("Expected stale plan")
        } catch { XCTAssertEqual(error as? CSVImportError, .stalePlan) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 1)
        XCTAssertFalse(context.hasChanges)
        let refreshed = try await service.prepareImport(
            CSVImportService.parse(validCSV(rows: "2024-01-15,200,3,10,30,full,CSV")),
            vehicleID: vehicle.id, sourceUnit: .imperial)
        let ids = try await service.importRecords(plan: refreshed, duplicates: .importAll)
        XCTAssertEqual(ids.count, 1)
    }

    func testAnImportPlanCannotBeUsedWithAnotherStore() async throws {
        let left = try makeContext(); let right = try makeContext()
        let id = UUID()
        left.insert(Vehicle(id: id, name: "Left")); try left.save()
        right.insert(Vehicle(id: id, name: "Right")); try right.save()
        let first = FuelingRecordPersistenceService(container: left.container)
        let second = FuelingRecordPersistenceService(container: right.container)
        let plan = try await first.prepareImport(
            CSVImportService.parse(validCSV(rows: "2024-01-15,100,3,10,30,full,CSV")),
            vehicleID: id, sourceUnit: .imperial)
        do {
            _ = try await second.importRecords(plan: plan, duplicates: .importAll); XCTFail("Expected store mismatch")
        } catch { XCTAssertEqual(error as? CSVImportError, .stalePlan) }
        XCTAssertEqual(try right.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
    }

    func testSelectedFileIsStagedAndReviewedBeforeImportWithoutTheOriginalFile() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Selected-\(UUID()).csv")
        let content = validCSV(rows: "2024-01-15,100,3,10,30,full,\"  original\r\nquoted \"\"note\"\"  \"")
        try content.write(to: source, atomically: true, encoding: .utf8)
        let staged = try await CSVImportFile.stage(source)
        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }
        XCTAssertNotEqual(staged.url, source)
        try FileManager.default.removeItem(at: source)
        let stagedText = try String(contentsOf: staged.url, encoding: .utf8)
        XCTAssertEqual(Array(stagedText.utf8), Array(content.utf8))
        let context = try makeContext()
        let vehicle = Vehicle(name: "Import target")
        context.insert(vehicle); try context.save()
        let service = FuelingRecordPersistenceService(container: context.container)
        let plan = try await service.prepareImport(
            CSVImportService.parse(stagedText), vehicleID: vehicle.id, sourceUnit: .imperial)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FuelingRecord>()), 0)
        let ids = try await service.importRecords(plan: plan, duplicates: .importAll)
        let saved = ModelContext(context.container)
        let record = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(ids, [record.id])
        XCTAssertEqual(record.notes, "  original\r\nquoted \"note\"  ")
    }
}

/// Runner-specific native measurements, separate from functional CI tests.
final class CSVImportPerformanceTests: XCTestCase {
    func testParse800() { measureParsing(800) }
    func testParse3200() { measureParsing(3200) }
    func testParse12800() { measureParsing(12800) }
    func testChronology800() { measureChronology(800) }
    func testChronology3200() { measureChronology(3200) }
    func testChronology12800() { measureChronology(12800) }

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        return options
    }

    private func measureParsing(_ count: Int) {
        let csv =
            CSVService.csvHeader + "\n"
            + (0..<count).map {
                "2024-01-15,\($0 + 100),3.123456789,10.123456789,30.123456789,full,\"  café \"\"note\"\"\r\nline  \""
            }.joined(separator: "\n")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do {
                let parsed = try CSVImportService.parse(csv)
                XCTAssertEqual(parsed.count, count)
            } catch { XCTFail("\(error)") }
        }
    }

    private func measureChronology(_ count: Int) {
        let rows = (0..<count).map {
            CSVImportRecordSnapshot(
                id: UUID(), lineNumber: $0 + 2,
                date: Date(timeIntervalSince1970: Double($0)), odometer: Double($0 + 100),
                pricePerFuelUnit: 3, fuelAmount: 10, totalCost: 30, fillUpType: .full, notes: nil)
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do { try CSVImportService.validateChronology(rows, existingRecords: []) } catch { XCTFail("\(error)") }
        }
    }
}
