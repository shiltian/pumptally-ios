import SwiftData
import XCTest

@testable import PumpTally

final class FuelingRecordDraftTests: XCTestCase {
    func testOdometerUsesTheLocaleAndConsumesTheWholeInput() throws {
        for (identifier, text) in [
            ("en_US", "87,654.32"), ("es_ES", "87.654,32"),
            ("fr_FR", "87\u{202f}654,32"), ("ar_EG", "٨٧٬٦٥٤٫٣٢"),
        ] {
            var draft = FuelingRecordDraft(values: values(), locale: Locale(identifier: identifier))
            draft.odometerString = text
            XCTAssertEqual(try XCTUnwrap(draft.odometer), 87654.32, accuracy: 0.000001, identifier)
            XCTAssertEqual(try draft.makeValues().odometer, 87654.32, accuracy: 0.000001, identifier)
            draft.odometerString += "invalid"
            XCTAssertNil(draft.odometer, identifier)
            XCTAssertFalse(draft.isValid, identifier)
            XCTAssertThrowsError(try draft.makeValues(), identifier)
        }
        for text in ["", "123abc", "1.2.3", "1,23.4", "NaN", "∞"] {
            var draft = FuelingRecordDraft(values: values(), locale: Locale(identifier: "en_US"))
            draft.odometerString = text
            XCTAssertFalse(draft.isValid, text)
            XCTAssertThrowsError(try draft.makeValues(), text)
        }
    }

    func testLocalizedNotesEditsPreserveExactMeasurementsAcrossUnitSystems() throws {
        for identifier in ["en_US", "es_ES", "fr_FR", "ar_EG", "zh_CN"] {
            let locale = Locale(identifier: identifier)
            for storage in UnitSystem.allCases {
                for display in UnitSystem.allCases {
                    let original = values()
                    var draft = FuelingRecordDraft(
                        values: original, storageUnit: storage, inputUnit: display, locale: locale)
                    XCTAssertTrue(draft.odometerString.contains(locale.decimalSeparator!), identifier)
                    XCTAssertTrue(try draft.makeUpdate().isEmpty, identifier)
                    draft.notes = "Updated localized note"
                    let saved = try draft.makeValues()
                    XCTAssertEqual(saved.odometer.bitPattern, original.odometer.bitPattern, identifier)
                    XCTAssertEqual(saved.fuelAmount.bitPattern, original.fuelAmount.bitPattern, identifier)
                    XCTAssertEqual(saved.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern, identifier)
                    XCTAssertEqual(saved.totalCost.bitPattern, original.totalCost.bitPattern, identifier)
                }
            }
        }
    }

    func testEditedLocalizedOdometerConvertsToTheStorageUnit() throws {
        var draft = FuelingRecordDraft(
            values: values(), storageUnit: .imperial, inputUnit: .metric,
            locale: Locale(identifier: "es_ES"))
        draft.odometerString = "160.934,4"
        XCTAssertEqual(try draft.makeValues().odometer, 100000, accuracy: 0.000001)
    }

    func testNotesOnlyEditPreservesUntouchedLegacyZeroAndNegativeValues() throws {
        for legacy in [0.0, -1.0] {
            var original = values()
            original.odometer = legacy
            original.fuelAmount = legacy
            original.pricePerFuelUnit = legacy
            original.totalCost = legacy
            var draft = FuelingRecordDraft(values: original)
            draft.notes = "Updated legacy note"
            XCTAssertTrue(draft.isValid)
            let saved = try draft.makeValues()
            XCTAssertEqual(saved.odometer.bitPattern, original.odometer.bitPattern)
            XCTAssertEqual(saved.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
            XCTAssertEqual(saved.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
            XCTAssertEqual(saved.totalCost.bitPattern, original.totalCost.bitPattern)
            XCTAssertEqual(saved.notes, "Updated legacy note")
            XCTAssertTrue(FuelingRecordValidation.isValid(saved, preserving: original))
            XCTAssertFalse(FuelingRecordValidation.isValid(saved))
        }
    }

    func testChangingLegacyValueToAnotherInvalidValueIsRejected() throws {
        var original = values()
        original.fuelAmount = 0
        var draft = FuelingRecordDraft(values: original)
        draft.edit(.fuelAmount, input: -1000)
        XCTAssertFalse(draft.isValid)
        XCTAssertThrowsError(try draft.makeValues())
        draft.edit(.fuelAmount, input: 10_000)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(try draft.makeValues().fuelAmount, 10)
    }

    func testNewEntryRequiresTwoSourceInputsRatherThanTreatingMissingPricesAsFreeFuel() {
        var draft = FuelingRecordDraft()
        draft.odometerString = "1000"
        draft.edit(.fuelAmount, input: 10_000)
        XCTAssertFalse(draft.isValid)
        draft.edit(.pricePerFuelUnit, input: 3500)
        XCTAssertTrue(draft.isValid)
    }

    func testExplicitZeroPriceAndCostUseTheSamePolicyAsPersistence() throws {
        var draft = FuelingRecordDraft()
        draft.odometerString = "1000"
        draft.edit(.pricePerFuelUnit, input: 3500)
        draft.edit(.fuelAmount, input: 10_000)
        draft.edit(.pricePerFuelUnit, input: 0)
        draft.edit(.totalCost, input: 0)
        XCTAssertTrue(draft.isValid)
        let saved = try draft.makeValues()
        XCTAssertEqual(saved.fuelAmount, 10)
        XCTAssertEqual(saved.pricePerFuelUnit, 0)
        XCTAssertEqual(saved.totalCost, 0)
        XCTAssertNoThrow(try FuelingRecordValidation.validate(saved))
    }

    func testBusinessPolicyRejectsNewInvalidAndNonfiniteMeasurements() {
        for invalid in [0.0, -1.0, .infinity, .nan] {
            var proposed = values()
            proposed.fuelAmount = invalid
            XCTAssertFalse(FuelingRecordValidation.isValid(proposed))
            XCTAssertThrowsError(try FuelingRecordValidation.validate(proposed))
            proposed = values()
            proposed.odometer = invalid
            XCTAssertFalse(FuelingRecordValidation.isValid(proposed))
        }
        for invalid in [-1.0, .infinity, .nan] {
            var proposed = values()
            proposed.pricePerFuelUnit = invalid
            XCTAssertFalse(FuelingRecordValidation.isValid(proposed))
            proposed = values()
            proposed.totalCost = invalid
            XCTAssertFalse(FuelingRecordValidation.isValid(proposed))
        }
    }

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
    func testDraftNotesEditOfZeroFuelSurvivesDiskReopenWithoutRepairingMeasurements() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyDraft-\(UUID()).store")
        var original: FuelingRecordValues!
        do {
            let container = try makeStore(at: url)
            let context = ModelContext(container)
            let record = try insertFixture(in: context)
            record.fuelAmount = 0
            try context.save()
            original = FuelingRecordValues(record: record)
            var draft = FuelingRecordDraft(values: original, storageUnit: .imperial, inputUnit: .metric)
            draft.notes = "Updated zero-fuel note"
            XCTAssertTrue(draft.isValid)
            try await FuelingRecordPersistenceService(container: container).update(
                recordID: record.id, update: draft.makeUpdate())
        }
        let container = try makeStore(at: url)
        let record = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<FuelingRecord>()).first)
        XCTAssertEqual(record.fuelAmount.bitPattern, original.fuelAmount.bitPattern)
        XCTAssertEqual(record.odometer.bitPattern, original.odometer.bitPattern)
        XCTAssertEqual(record.pricePerFuelUnit.bitPattern, original.pricePerFuelUnit.bitPattern)
        XCTAssertEqual(record.totalCost.bitPattern, original.totalCost.bitPattern)
        XCTAssertEqual(record.notes, "Updated zero-fuel note")
    }

    private func makeStore(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV5.self)
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
