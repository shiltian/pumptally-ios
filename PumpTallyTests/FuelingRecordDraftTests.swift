import SwiftData
import XCTest

@testable import PumpTally

final class FuelingRecordDraftTests: XCTestCase {
    private func values(notes: String? = "Original") -> FuelingRecordValues {
        FuelingRecordValues(
            date: Date(timeIntervalSince1970: 1_700_000_000), odometer: 87_654.321098765,
            pricePerFuelUnit: 0.913770231, fuelAmount: 40.123456789,
            totalCost: 36.579123, fillUpType: .full, notes: notes
        )
    }

    func testNotesOnlyEditPreservesEveryNumericBitPattern() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        draft.notes = "Changed note"
        let result = try draft.makeValues()

        XCTAssertEqual(result.odometer.bitPattern, original.odometer.bitPattern)
        XCTAssertEqual(result.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
        XCTAssertEqual(result.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
        XCTAssertEqual(result.totalCost.bitPattern, original.totalCost.bitPattern)
        XCTAssertEqual(result.notes, "Changed note")
    }

    func testOpeningAndSavingIsAnEmptyUpdate() throws {
        XCTAssertTrue(try FuelingRecordDraft(values: values()).makeUpdate().isEmpty)
        XCTAssertTrue(try FuelingRecordDraft(values: values(notes: nil)).makeUpdate().isEmpty)
        XCTAssertTrue(try FuelingRecordDraft(values: values(notes: "")).makeUpdate().isEmpty)
    }

    func testEditingOneFieldDoesNotRecalculateUneditedMeasurements() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        draft.edit(.totalCost, input: 4000)
        let result = try draft.makeValues()

        XCTAssertEqual(result.totalCost, 40)
        XCTAssertEqual(result.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
        XCTAssertEqual(result.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
    }

    func testReturningToOriginalDisplayedValuePreservesOriginalPrecision() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        let initialInput = draft.input(for: .fuelAmount)
        draft.edit(.fuelAmount, input: initialInput + 1)
        draft.edit(.fuelAmount, input: initialInput)
        XCTAssertTrue(try draft.makeUpdate().isEmpty)
    }

    func testAnyTwoInputsCalculateTheRemainingField() throws {
        let cases: [(FuelingRecordDraft.Field, Int, FuelingRecordDraft.Field, Int, FuelingRecordDraft.Field, Int)] = [
            (.pricePerFuelUnit, 3500, .fuelAmount, 10_000, .totalCost, 3500),
            (.totalCost, 3500, .fuelAmount, 10_000, .pricePerFuelUnit, 3500),
            (.totalCost, 3500, .pricePerFuelUnit, 3500, .fuelAmount, 10_000),
        ]
        for (first, firstValue, second, secondValue, target, expected) in cases {
            var draft = FuelingRecordDraft()
            draft.edit(first, input: firstValue)
            draft.edit(second, input: secondValue)
            XCTAssertEqual(draft.input(for: target), expected, "\(target)")
        }
    }

    func testMostRecentTwoExplicitInputsDetermineCalculation() throws {
        var draft = FuelingRecordDraft()
        draft.edit(.pricePerFuelUnit, input: 3500)
        draft.edit(.fuelAmount, input: 10_000)
        draft.edit(.totalCost, input: 4000)
        XCTAssertEqual(draft.input(for: .pricePerFuelUnit), 4000)
        XCTAssertEqual(draft.input(for: .fuelAmount), 10_000)
        XCTAssertEqual(draft.input(for: .totalCost), 4000)
    }

    func testCalculationRoundsOnceUsingDecimalArithmetic() throws {
        var draft = FuelingRecordDraft()
        draft.edit(.pricePerFuelUnit, input: 3250)
        draft.edit(.fuelAmount, input: 10_002)
        XCTAssertEqual(draft.input(for: .totalCost), 3251)
    }

    func testOutOfRangeCalculationIsRejectedWithoutTrapping() throws {
        var draft = FuelingRecordDraft()
        draft.edit(.pricePerFuelUnit, input: 999_999_999)
        draft.edit(.fuelAmount, input: 999_999_999)
        XCTAssertFalse(draft.calculationIsValid)
        XCTAssertThrowsError(try draft.makeValues())
    }

    func testLegacyZeroCostCanBePreservedByNotesEdit() throws {
        var original = values()
        original.pricePerFuelUnit = 0
        original.totalCost = 0
        var draft = FuelingRecordDraft(values: original)
        draft.notes = "Updated"
        let result = try draft.makeValues()
        XCTAssertEqual(result.pricePerFuelUnit, 0)
        XCTAssertEqual(result.totalCost, 0)
    }

    func testNotesUpdateMergesWithoutClobberingNewerMeasurements() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        draft.notes = "My note"
        var current = original
        current.odometer += 100
        current.fuelAmount = 45.123456789
        let merged = try draft.makeUpdate().merging(into: current)
        XCTAssertEqual(merged.odometer, current.odometer)
        XCTAssertEqual(merged.fuelAmount.bitPattern, current.fuelAmount.bitPattern)
        XCTAssertEqual(merged.notes, "My note")
    }

    func testOverlappingEditsProduceAnExplicitConflict() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        draft.notes = "My note"
        var current = original
        current.notes = "Another device"
        XCTAssertThrowsError(try draft.makeUpdate().merging(into: current)) { error in
            XCTAssertEqual(error as? FuelingRecordEditingError, .recordChanged)
        }
    }

    func testAlreadyAppliedUpdateIsIdempotent() throws {
        let original = values()
        var draft = FuelingRecordDraft(values: original)
        draft.notes = "Updated"
        let proposed = try draft.makeValues()
        XCTAssertEqual(try draft.makeUpdate().merging(into: proposed), proposed)
    }

    func testClearingNotesIsDifferentFromLeavingNotesAlone() throws {
        var draft = FuelingRecordDraft(values: values())
        draft.notes = ""
        XCTAssertNil(try draft.makeValues().notes)
        XCTAssertFalse(try draft.makeUpdate().isEmpty)
    }
}

@MainActor
final class FuelingRecordEditingPersistenceTests: XCTestCase {
    private func makeStore(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV4.self)
        let configuration =
            url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func insertFixture(in context: ModelContext) throws -> FuelingRecord {
        let vehicle = Vehicle(name: "Precision fixture")
        context.insert(vehicle)
        let record = FuelingRecord(
            odometer: 12345.678901234, pricePerFuelUnit: 0.913770231,
            fuelAmount: 40.123456789, totalCost: 36.579123, notes: "Original", vehicle: vehicle
        )
        context.insert(record)
        try context.save()
        return record
    }

    func testNotesEditSurvivesDiskReopenWithExactMeasurements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        var original: FuelingRecordValues!
        var id: UUID!
        do {
            let container = try makeStore(at: url)
            let context = ModelContext(container)
            let record = try insertFixture(in: context)
            id = record.id
            original = FuelingRecordValues(record: record)
            var draft = FuelingRecordDraft(values: original)
            draft.notes = "Notes only"
            try await FuelingRecordPersistenceService(container: context.container).update(
                recordID: id, update: draft.makeUpdate())
        }
        let reopened = try makeStore(at: url)
        let context = ModelContext(reopened)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.odometer.bitPattern, original.odometer.bitPattern)
        XCTAssertEqual(record.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
        XCTAssertEqual(record.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
        XCTAssertEqual(record.totalCost.bitPattern, original.totalCost.bitPattern)
        XCTAssertEqual(record.notes, "Notes only")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 1)
    }

    func testNoOpDoesNotCommitOrEnqueueOrChangeTimestamp() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        let record = try insertFixture(in: context)
        let draft = FuelingRecordDraft(values: FuelingRecordValues(record: record))
        let changed = try await FuelingRecordPersistenceService(
            container: context.container,
            commit: { _ in XCTFail("A no-op must not save") }
        ).update(recordID: record.id, update: draft.makeUpdate())
        XCTAssertFalse(changed)
        XCTAssertNil(record.modifiedAt)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncChange>()), 0)
    }

    func testNotesEditPreservesNewerPersistedNumericUpdate() async throws {
        let container = try makeStore()
        let context = ModelContext(container)
        let record = try insertFixture(in: context)
        var draft = FuelingRecordDraft(values: FuelingRecordValues(record: record))
        draft.notes = "My notes"
        record.fuelAmount = 45.987654321
        try context.save()
        try await FuelingRecordPersistenceService(container: context.container).update(
            recordID: record.id, update: draft.makeUpdate())
        let saved = ModelContext(container)
        let updated = try XCTUnwrap(saved.fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(updated.fuelAmount, 45.987654321)
        XCTAssertEqual(updated.notes, "My notes")
    }
}
