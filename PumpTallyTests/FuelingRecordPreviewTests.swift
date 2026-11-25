import SwiftData
import XCTest

@testable import PumpTally

@MainActor
final class FuelingRecordPreviewTests: XCTestCase {
    func testPreviewMatchesSavedIntervalsAcrossFillTypesBaselinesAndDisplayUnits() throws {
        for previousIsFirst in [true, false] {
            for previousType in FillUpType.allCases {
                for currentType in FillUpType.allCases {
                    for displayUnit in UnitSystem.allCases {
                        for storageUnit in UnitSystem.allCases {
                            try assertPreviewMatchesSaved(
                                previousIsFirst: previousIsFirst,
                                previousType: previousType, currentType: currentType,
                                storageUnit: storageUnit, displayUnit: displayUnit)
                        }
                    }
                }
            }
        }
    }

    private func assertPreviewMatchesSaved(
        previousIsFirst: Bool, previousType: FillUpType,
        currentType: FillUpType, storageUnit: UnitSystem, displayUnit: UnitSystem
    ) throws {
        let schema = Schema(versionedSchema: SchemaV6.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let vehicle = Vehicle(name: "Preview fixture", unitSystem: storageUnit)
        context.insert(vehicle)
        var prior: [FuelingRecord] = []
        if !previousIsFirst {
            let first = FuelingRecord(
                date: Date(timeIntervalSince1970: 1_000_000), odometer: 1000,
                pricePerFuelUnit: 3.5, fuelAmount: 10, totalCost: 35, fillUpType: .partial, vehicle: vehicle)
            context.insert(first)
            prior.append(first)
        }
        let previous = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_100_000), odometer: 1300,
            pricePerFuelUnit: 3.5, fuelAmount: 10, totalCost: 35, fillUpType: previousType, vehicle: vehicle)
        context.insert(previous)
        prior.append(previous)
        let current = FuelingRecord(
            date: Date(timeIntervalSince1970: 1_200_000), odometer: 1600,
            pricePerFuelUnit: 3.5, fuelAmount: 10, totalCost: 35, fillUpType: currentType, vehicle: vehicle)
        let draft = FuelingRecordDraft(
            values: FuelingRecordValues(record: current),
            storageUnit: storageUnit, inputUnit: displayUnit)
        let history = FuelingRecordEditorHistory(records: prior)
        let validation = history.validate(date: current.date, odometer: current.odometer)
        let preview = try XCTUnwrap(draft.preview(after: history.interval(for: validation)))
        context.insert(current)
        context.processPendingChanges()
        StatisticsCacheService.refresh(for: vehicle)
        try context.save()
        let eligible = currentType == .full && (previousIsFirst || previousType == .full)
        XCTAssertEqual(preview.efficiency != nil, eligible)
        XCTAssertEqual(
            preview.efficiency,
            current.cachedEfficiency.map {
                displayUnit.efficiencyValue($0, from: storageUnit)
            })
        XCTAssertEqual(
            preview.distanceDriven,
            displayUnit.distanceValue(try XCTUnwrap(current.cachedDistanceDriven), from: storageUnit))
        XCTAssertEqual(
            preview.costPerDistance,
            current.cachedCostPerDistance.map {
                displayUnit.costPerDistanceValue($0, from: storageUnit)
            })
        XCTAssertEqual(current.getEfficiency(), current.cachedEfficiency ?? 0)
    }

    func testFirstRecordHasNoIntervalPreview() {
        var draft = FuelingRecordDraft()
        draft.odometerString = "1300"
        XCTAssertNil(draft.preview(after: nil))
    }

    func testDistanceAppearsBeforeNumericEntryWithoutInventingEfficiencyOrCost() throws {
        var draft = FuelingRecordDraft()
        draft.odometerString = "1300"
        let preview = try XCTUnwrap(
            draft.preview(
                after:
                    FuelingIntervalContext(odometer: 1000, fillUpType: .full, isFirstRecord: false)))
        XCTAssertEqual(preview.distanceDriven, 300)
        XCTAssertNil(preview.efficiency)
        XCTAssertNil(preview.costPerDistance)
        XCTAssertFalse(draft.isValid)
    }

    func testInvalidChronologyDoesNotProduceAnIntervalContext() {
        let successor = OdometerReadingSnapshot(id: UUID(), date: Date(), odometer: 1000)
        let validation = OdometerChronologyValidation(
            neighbors: .init(predecessor: nil, successor: successor), issue: .notLessThanSuccessor(successor))
        XCTAssertNil(FuelingRecordEditorHistory(records: []).interval(for: validation))
    }

    func testEditorValidationTracksOdometerAndHistoryChanges() throws {
        let vehicle = Vehicle(name: "Preview fixture")
        let date = Date(timeIntervalSince1970: 1_000_000)
        let previous = FuelingRecord(
            date: date, odometer: 1_200, pricePerFuelUnit: 3, fuelAmount: 10, totalCost: 30,
            fillUpType: .partial, vehicle: vehicle)
        let proposedDate = date.addingTimeInterval(86_400)
        let history = FuelingRecordEditorHistory(records: [previous])
        let initial = try XCTUnwrap(history.validate(date: proposedDate, odometer: 1_300))
        XCTAssertTrue(initial.isValid)
        XCTAssertEqual(history.interval(for: initial)?.fillUpType, .partial)
        XCTAssertFalse(try XCTUnwrap(history.validate(date: proposedDate, odometer: 1_100)).isValid)

        previous.odometer = 1_250
        previous.fillUpType = .full
        let updatedHistory = FuelingRecordEditorHistory(records: [previous])
        let updated = updatedHistory.validate(date: proposedDate, odometer: 1_300)
        XCTAssertEqual(updatedHistory.interval(for: updated)?.odometer, 1_250)
        XCTAssertEqual(updatedHistory.interval(for: updated)?.fillUpType, .full)
    }
}
