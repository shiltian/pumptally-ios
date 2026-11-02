import Foundation
import SwiftData

/// Typed commands commit business values, affected caches and outgoing intent
/// together. Only IDs and immutable results leave the owned transaction.
struct FuelingRecordPersistenceService: Sendable {
    private let store: OwnedModelStore

    init(writer: OwnedModelStore) { store = writer }

    func create(values: FuelingRecordValues, storageUnit: UnitSystem, vehicleID: UUID) async throws
        -> SavedFuelingRecord
    {
        try await store.transaction { actor in
            let context = actor.modelContext
            let vehicle = try owner(vehicleID, storageUnit: storageUnit, in: context)
            try validate(values)
            let readings = (vehicle.fuelingRecords ?? []).map(OdometerReadingSnapshot.init(record:))
            guard
                OdometerChronologyValidator.validate(date: values.date, odometer: values.odometer, records: readings)
                    .isValid
            else { throw FuelingRecordEditingError.invalidInput }
            let record = FuelingRecord(
                date: values.date, odometer: values.odometer,
                pricePerFuelUnit: values.pricePerFuelUnit, fuelAmount: values.fuelAmount, totalCost: values.totalCost,
                fillUpType: readings.isEmpty ? .partial : values.fillUpType, notes: values.notes, vehicle: vehicle)
            record.modifiedAt = Date()
            context.insert(record)
            context.processPendingChanges()
            StatisticsCacheService.updateForNewRecord(record, vehicle: vehicle)
            try SyncChangeJournal.enqueue(record, in: context)
            return SavedFuelingRecord(record: record)
        }
    }

    @discardableResult
    func update(recordID: UUID, update: FuelingRecordUpdate) async throws -> Bool {
        try await store.transaction { actor in
            let context = actor.modelContext
            let record = try record(recordID, in: context)
            guard update.storageUnit == nil || update.storageUnit == record.vehicle.unitSystem else {
                throw FuelingRecordEditingError.recordChanged
            }
            let current = FuelingRecordValues(record: record)
            let values = try update.merging(into: current)
            guard values != current else { return false }
            try validate(values, preserving: current)
            let readings = (record.vehicle.fuelingRecords ?? []).map(OdometerReadingSnapshot.init(record:))
            guard
                OdometerChronologyValidator.validate(
                    date: values.date, odometer: values.odometer, records: readings,
                    originalRecord: OdometerReadingSnapshot(record: record)
                ).isValid
            else { throw FuelingRecordEditingError.invalidInput }
            func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<FuelingRecord, Value>, _ value: Value) {
                if record[keyPath: keyPath] != value { record[keyPath: keyPath] = value }
            }
            assign(\.date, values.date)
            assign(\.odometer, values.odometer)
            assign(\.pricePerFuelUnit, values.pricePerFuelUnit)
            assign(\.fuelAmount, values.fuelAmount)
            assign(\.totalCost, values.totalCost)
            assign(\.fillUpType, values.fillUpType)
            assign(\.notes, values.notes)
            record.modifiedAt = Date()
            if current.date != values.date || current.odometer != values.odometer
                || current.pricePerFuelUnit != values.pricePerFuelUnit || current.fuelAmount != values.fuelAmount
                || current.totalCost != values.totalCost || current.fillUpType != values.fillUpType
            {
                StatisticsCacheService.updateForEditedRecord(vehicle: record.vehicle)
            }
            try SyncChangeJournal.enqueue(record, in: context)
            return true
        }
    }

    func delete(recordID: UUID) async throws {
        try await store.transaction { actor in
            let context = actor.modelContext
            let record = try record(recordID, in: context)
            let vehicle = record.vehicle
            try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
            context.delete(record)
            context.processPendingChanges()
            StatisticsCacheService.updateForDeletedRecord(vehicle: vehicle)
        }
    }

    func prepareImport(_ snapshots: [CSVImportRecordSnapshot], vehicleID: UUID, sourceUnit: UnitSystem) async throws
        -> CSVImportPlan
    {
        try await store.transaction { actor in
            let vehicle = try importOwner(vehicleID, in: actor.modelContext)
            let existing = (vehicle.fuelingRecords ?? []).map(CSVImportExistingRecord.init(record:))
            for row in snapshots { try validate(row.values) }
            let revision = CSVImportRevision(
                storeID: ObjectIdentifier(actor.modelContainer),
                storageUnit: vehicle.unitSystem, records: existing)
            let plan = try CSVImportPlan(
                records: snapshots, vehicleID: vehicleID, sourceUnit: sourceUnit,
                revision: revision, existing: existing)
            for row in plan.records { try validate(row.values) }
            return plan
        }
    }

    func importRecords(plan: CSVImportPlan, duplicates: CSVImportDuplicateDecision) async throws -> [UUID] {
        try await store.transaction { actor in
            let context = actor.modelContext
            let vehicle = try importOwner(plan.vehicleID, in: context)
            let existing = (vehicle.fuelingRecords ?? []).map(CSVImportExistingRecord.init(record:))
            let revision = CSVImportRevision(
                storeID: ObjectIdentifier(actor.modelContainer),
                storageUnit: vehicle.unitSystem, records: existing)
            guard revision == plan.revision else { throw CSVImportError.stalePlan }
            let snapshots = plan.selectedRecords(duplicates)
            let ids = snapshots.map(\.id)
            guard Set(ids).count == ids.count else { throw FuelingRecordEditingError.recordChanged }
            if !ids.isEmpty,
                try context.fetchCount(FetchDescriptor<FuelingRecord>(predicate: #Predicate { ids.contains($0.id) }))
                    > 0
            {
                throw FuelingRecordEditingError.recordChanged
            }
            try CSVImportService.validateChronology(
                snapshots, existingRecords: (vehicle.fuelingRecords ?? []).map(OdometerReadingSnapshot.init(record:)))
            let values = snapshots.map(\.values)
            // Validate the complete input before constructing any models.
            for value in values { try validate(value) }
            guard !snapshots.isEmpty else { return [] }
            let modifiedAt = Date()
            for (snapshot, value) in zip(snapshots, values) {
                let record = FuelingRecord(
                    id: snapshot.id, date: value.date, odometer: value.odometer,
                    pricePerFuelUnit: value.pricePerFuelUnit, fuelAmount: value.fuelAmount,
                    totalCost: value.totalCost, fillUpType: value.fillUpType, notes: value.notes, vehicle: vehicle)
                record.modifiedAt = modifiedAt
                context.insert(record)
                try SyncChangeJournal.enqueue(record, in: context)
            }
            context.processPendingChanges()
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            return snapshots.map(\.id)
        }
    }

    private func importOwner(_ id: UUID, in context: ModelContext) throws -> Vehicle {
        var query = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let vehicle = try context.fetch(query).first else { throw CSVImportError.stalePlan }
        return vehicle
    }

    private func owner(_ id: UUID, storageUnit: UnitSystem, in context: ModelContext) throws -> Vehicle {
        var query = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let vehicle = try context.fetch(query).first else { throw FuelingRecordEditingError.recordUnavailable }
        guard vehicle.unitSystem == storageUnit else { throw FuelingRecordEditingError.recordChanged }
        return vehicle
    }

    private func record(_ id: UUID, in context: ModelContext) throws -> FuelingRecord {
        var query = FetchDescriptor<FuelingRecord>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let record = try context.fetch(query).first else { throw FuelingRecordEditingError.recordUnavailable }
        return record
    }

    private func validate(_ values: FuelingRecordValues, preserving original: FuelingRecordValues? = nil) throws {
        // Existing legacy values are grandfathered when untouched. Validation
        // cannot turn a notes edit into a rewrite or repair of old measurements.
        guard original?.date == values.date || values.date.timeIntervalSince1970.isFinite,
            original?.odometer == values.odometer || (values.odometer.isFinite && values.odometer > 0),
            original?.pricePerFuelUnit == values.pricePerFuelUnit
                || (values.pricePerFuelUnit.isFinite && values.pricePerFuelUnit >= 0),
            original?.fuelAmount == values.fuelAmount || (values.fuelAmount.isFinite && values.fuelAmount > 0),
            original?.totalCost == values.totalCost || (values.totalCost.isFinite && values.totalCost >= 0)
        else { throw FuelingRecordEditingError.invalidInput }
    }
}
