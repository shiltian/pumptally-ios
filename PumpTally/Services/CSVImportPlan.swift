import Foundation
import SwiftData

enum CSVImportDuplicateDecision: String, CaseIterable, Sendable {
    case skipPossibleDuplicates
    case importAll
}

/// A preview is bound to one store, vehicle, unit basis and exact business
/// history. Derived-cache changes do not invalidate a user's import decision.
struct CSVImportRevision: Equatable, Sendable {
    struct Record: Equatable, Sendable {
        let id: UUID
        let numericBits: [UInt64]
        let fillUpType: FillUpType
        let notes: String?
    }

    let storeID: ObjectIdentifier
    let storageUnit: UnitSystem
    let records: [Record]

    init(storeID: ObjectIdentifier, storageUnit: UnitSystem, records: [CSVImportExistingRecord]) {
        self.storeID = storeID
        self.storageUnit = storageUnit
        self.records = records.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            Record(
                id: $0.id,
                numericBits: [
                    $0.values.date.timeIntervalSinceReferenceDate.bitPattern,
                    $0.values.odometer.bitPattern, $0.values.pricePerFuelUnit.bitPattern,
                    $0.values.fuelAmount.bitPattern, $0.values.totalCost.bitPattern,
                ],
                fillUpType: $0.values.fillUpType, notes: $0.values.notes)
        }
    }
}

struct CSVImportExistingRecord: Sendable {
    let id: UUID
    let values: FuelingRecordValues

    init(record: FuelingRecord) {
        id = record.id
        values = FuelingRecordValues(record: record)
    }

    var reading: OdometerReadingSnapshot {
        .init(id: id, date: values.date, odometer: values.odometer)
    }
}

struct CSVImportPlan: Sendable {
    let vehicleID: UUID
    let sourceUnit: UnitSystem
    let revision: CSVImportRevision
    let records: [CSVImportRecordSnapshot]
    let possibleDuplicateIDs: Set<UUID>

    func selectedRecords(_ decision: CSVImportDuplicateDecision) -> [CSVImportRecordSnapshot] {
        decision == .importAll ? records : records.filter { !possibleDuplicateIDs.contains($0.id) }
    }

    init(
        records: [CSVImportRecordSnapshot], vehicleID: UUID, sourceUnit: UnitSystem,
        revision: CSVImportRevision, existing: [CSVImportExistingRecord]
    ) throws {
        self.vehicleID = vehicleID
        self.sourceUnit = sourceUnit
        self.revision = revision
        self.records = records.map { row in
            let target = revision.storageUnit
            return CSVImportRecordSnapshot(
                id: row.id, lineNumber: row.lineNumber, date: row.date,
                odometer: target.distanceValue(row.odometer, from: sourceUnit),
                pricePerFuelUnit: target.priceValue(row.pricePerFuelUnit, from: sourceUnit),
                fuelAmount: target.fuelValue(row.fuelAmount, from: sourceUnit), totalCost: row.totalCost,
                fillUpType: row.fillUpType, notes: row.notes)
        }
        var seen = Set(existing.map { DuplicateKey(values: $0.values) })
        var duplicates = Set<UUID>()
        for row in self.records {
            if !seen.insert(DuplicateKey(values: row.values)).inserted { duplicates.insert(row.id) }
        }
        possibleDuplicateIDs = duplicates
        // Candidates are reviewed before attempting to insert them. Legacy
        // exports truncate timestamps, so even an exact-looking row may not
        // fit chronology if the user elects to import it again.
        try CSVImportService.validateChronology(
            selectedRecords(.skipPossibleDuplicates),
            existingRecords: existing.map(\.reading))
    }

    /// A candidate, never proof of identity: the legacy exchange has no IDs or
    /// fractional timestamps. Only an explicit user decision may skip a row.
    private struct DuplicateKey: Hashable {
        let second: Double
        let odometer: Double
        let price: Double
        let fuel: Double
        let cost: Double
        let fill: String
        let notes: String

        init(values: FuelingRecordValues) {
            second = values.date.timeIntervalSince1970.rounded(.down)
            odometer = values.odometer
            price = values.pricePerFuelUnit
            fuel = values.fuelAmount
            cost = values.totalCost
            fill = values.fillUpType.rawValue
            notes = values.notes ?? ""
        }
    }
}

extension CSVImportRecordSnapshot {
    var values: FuelingRecordValues {
        .init(
            date: date, odometer: odometer, pricePerFuelUnit: pricePerFuelUnit,
            fuelAmount: fuelAmount, totalCost: totalCost, fillUpType: fillUpType, notes: notes)
    }
}
