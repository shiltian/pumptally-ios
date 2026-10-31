import Foundation
import SwiftData
import os

enum FuelingRecordPersistenceError: LocalizedError {
    case insertedRelationshipUnavailable
    case deletedRelationshipUnavailable

    var errorDescription: String? {
        switch self {
        case .insertedRelationshipUnavailable:
            return "The new fueling record relationship was not available before saving."
        case .deletedRelationshipUnavailable:
            return "The deleted fueling record relationship was not updated before saving."
        }
    }
}

/// Coordinates a record mutation and its derived cache updates as one save.
///
/// No stored model or schema changes are involved. A clean rollback boundary is
/// established first, pending inverse relationships are processed in memory,
/// then the mutation and all cache fields are committed by one `save()`.
@MainActor
enum FuelingRecordPersistenceService {
    typealias Commit = (ModelContext) throws -> Void

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "RecordPersistence"
    )

    static func insert(
        into vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() },
        makeRecord: () -> FuelingRecord
    ) throws -> FuelingRecord {
        let rollbackSnapshot = RollbackSnapshot(vehicle: vehicle)
        var insertedRecord: FuelingRecord?
        var didMutate = false

        do {
            return try perform(
                in: context,
                commit: commit,
                mutation: {
                    didMutate = true
                    let record = makeRecord()
                    insertedRecord = record
                    context.insert(record)
                    return record
                },
                afterPendingChanges: { record in
                    guard (vehicle.fuelingRecords ?? []).contains(where: { $0.id == record.id }) else {
                        throw FuelingRecordPersistenceError.insertedRelationshipUnavailable
                    }
                    StatisticsCacheService.updateForNewRecord(record, vehicle: vehicle)
                    try SyncChangeJournal.enqueue(record, in: context)
                }
            )
        } catch {
            logger.error("Failed to insert fueling record: \(error.localizedDescription, privacy: .public)")
            if didMutate {
                restoreAfterFailedMutation(
                    in: context,
                    snapshot: rollbackSnapshot
                ) {
                    if let insertedRecord {
                        vehicle.fuelingRecords?.removeAll { $0.id == insertedRecord.id }
                    }
                }
            }
            throw error
        }
    }

    static func insertBatch(
        into vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() },
        makeRecords: () -> [FuelingRecord]
    ) throws -> [FuelingRecord] {
        let rollbackSnapshot = RollbackSnapshot(vehicle: vehicle)
        var insertedRecords: [FuelingRecord] = []
        var didMutate = false

        do {
            return try perform(
                in: context,
                commit: commit,
                mutation: {
                    didMutate = true
                    insertedRecords = makeRecords()
                    for record in insertedRecords {
                        context.insert(record)
                    }
                    return insertedRecords
                },
                afterPendingChanges: { records in
                    let insertedIDs = Set(records.map(\.id))
                    let relatedIDs = Set((vehicle.fuelingRecords ?? []).map(\.id))
                    guard insertedIDs.isSubset(of: relatedIDs) else {
                        throw FuelingRecordPersistenceError.insertedRelationshipUnavailable
                    }
                    StatisticsCacheService.recalculateAllStatistics(for: vehicle)
                    for record in records {
                        try SyncChangeJournal.enqueue(record, in: context)
                    }
                }
            )
        } catch {
            logger.error("Failed to insert fueling record batch: \(error.localizedDescription, privacy: .public)")
            if didMutate {
                let insertedIDs = Set(insertedRecords.map(\.id))
                restoreAfterFailedMutation(
                    in: context,
                    snapshot: rollbackSnapshot
                ) {
                    vehicle.fuelingRecords?.removeAll {
                        insertedIDs.contains($0.id)
                    }
                }
            }
            throw error
        }
    }

    static func saveEdits(
        to record: FuelingRecord,
        in vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() },
        applyChanges: () -> Void
    ) throws {
        let rollbackSnapshot = RollbackSnapshot(vehicle: vehicle, editedRecord: record)
        var didMutate = false

        do {
            _ = try perform(
                in: context,
                commit: commit,
                mutation: {
                    didMutate = true
                    applyChanges()
                    return record
                },
                afterPendingChanges: { _ in
                    StatisticsCacheService.updateForEditedRecord(vehicle: vehicle)
                    try SyncChangeJournal.enqueue(record, in: context)
                }
            )
        } catch {
            logger.error("Failed to edit fueling record: \(error.localizedDescription, privacy: .public)")
            if didMutate {
                restoreAfterFailedMutation(in: context, snapshot: rollbackSnapshot)
            }
            throw error
        }
    }

    static func delete(
        _ record: FuelingRecord,
        from vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() }
    ) throws {
        let rollbackSnapshot = RollbackSnapshot(vehicle: vehicle)
        var didMutate = false

        do {
            _ = try perform(
                in: context,
                commit: commit,
                mutation: {
                    didMutate = true
                    context.delete(record)
                    return record.id
                },
                afterPendingChanges: { deletedID in
                    guard !(vehicle.fuelingRecords ?? []).contains(where: { $0.id == deletedID }) else {
                        throw FuelingRecordPersistenceError.deletedRelationshipUnavailable
                    }
                    StatisticsCacheService.updateForDeletedRecord(vehicle: vehicle)
                    try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
                }
            )
        } catch {
            logger.error("Failed to delete fueling record: \(error.localizedDescription, privacy: .public)")
            if didMutate {
                restoreAfterFailedMutation(in: context, snapshot: rollbackSnapshot)
            }
            throw error
        }
    }

    private static func perform<Result>(
        in context: ModelContext,
        commit: Commit,
        mutation: () throws -> Result,
        afterPendingChanges: (Result) throws -> Void
    ) throws -> Result {
        // Do not let rollback discard unrelated pending UI changes. If this
        // boundary save fails, mutation has not started and those changes are
        // deliberately left pending for their owner to resolve.
        if context.hasChanges {
            try context.save()
        }

        let result = try mutation()
        context.processPendingChanges()
        try afterPendingChanges(result)
        try commit(context)
        return result
    }

    private static func restoreAfterFailedMutation(
        in context: ModelContext,
        snapshot: RollbackSnapshot,
        repairRelationship: () -> Void = {}
    ) {
        // First rollback restores the store transaction. SwiftData can leave
        // registered objects stale after `processPendingChanges`, so repair
        // those values from the snapshot; the final rollback then clears the
        // dirty flags created by that repair while retaining restored values.
        context.rollback()
        repairRelationship()
        snapshot.restore()
        context.rollback()
    }

    /// SwiftData rollback restores the store transaction, but after
    /// `processPendingChanges()` registered objects can retain stale in-memory
    /// values. Capture all values this service may mutate so UI state is also
    /// restored after a failed commit.
    ///
    /// IMPORTANT: This snapshot is intentionally coupled to every stored field
    /// changed by record editing or statistics recalculation. Any new mutable
    /// record field or cache property must be added here as well.
    private struct RollbackSnapshot {
        let vehicle: Vehicle
        let vehicleCache: VehicleCacheSnapshot
        let recordCaches: [RecordCacheSnapshot]
        let editedRecord: EditedRecordSnapshot?

        init(vehicle: Vehicle, editedRecord: FuelingRecord? = nil) {
            self.vehicle = vehicle
            vehicleCache = VehicleCacheSnapshot(vehicle: vehicle)
            recordCaches = (vehicle.fuelingRecords ?? []).map(RecordCacheSnapshot.init(record:))
            self.editedRecord = editedRecord.map(EditedRecordSnapshot.init(record:))
        }

        func restore() {
            vehicleCache.restore(on: vehicle)
            for snapshot in recordCaches {
                snapshot.restore()
            }
            editedRecord?.restore()
        }
    }

    private struct VehicleCacheSnapshot {
        let cachedTotalSpent: Double?
        let cachedTotalDistance: Double?
        let cachedTotalFuel: Double?
        let cachedAverageEfficiency: Double?
        let cachedAverageCostPerDistance: Double?
        let cachedAverageFillUpCost: Double?
        let cachedAveragePricePerFuelUnit: Double?
        let cachedBestEfficiency: Double?
        let cachedWorstEfficiency: Double?
        let cachedHighestPricePerFuelUnit: Double?
        let cachedLowestPricePerFuelUnit: Double?
        let cachedRecordCount: Int?
        let cacheLastUpdated: Date?

        init(vehicle: Vehicle) {
            cachedTotalSpent = vehicle.cachedTotalSpent
            cachedTotalDistance = vehicle.cachedTotalDistance
            cachedTotalFuel = vehicle.cachedTotalFuel
            cachedAverageEfficiency = vehicle.cachedAverageEfficiency
            cachedAverageCostPerDistance = vehicle.cachedAverageCostPerDistance
            cachedAverageFillUpCost = vehicle.cachedAverageFillUpCost
            cachedAveragePricePerFuelUnit = vehicle.cachedAveragePricePerFuelUnit
            cachedBestEfficiency = vehicle.cachedBestEfficiency
            cachedWorstEfficiency = vehicle.cachedWorstEfficiency
            cachedHighestPricePerFuelUnit = vehicle.cachedHighestPricePerFuelUnit
            cachedLowestPricePerFuelUnit = vehicle.cachedLowestPricePerFuelUnit
            cachedRecordCount = vehicle.cachedRecordCount
            cacheLastUpdated = vehicle.cacheLastUpdated
        }

        func restore(on vehicle: Vehicle) {
            vehicle.cachedTotalSpent = cachedTotalSpent
            vehicle.cachedTotalDistance = cachedTotalDistance
            vehicle.cachedTotalFuel = cachedTotalFuel
            vehicle.cachedAverageEfficiency = cachedAverageEfficiency
            vehicle.cachedAverageCostPerDistance = cachedAverageCostPerDistance
            vehicle.cachedAverageFillUpCost = cachedAverageFillUpCost
            vehicle.cachedAveragePricePerFuelUnit = cachedAveragePricePerFuelUnit
            vehicle.cachedBestEfficiency = cachedBestEfficiency
            vehicle.cachedWorstEfficiency = cachedWorstEfficiency
            vehicle.cachedHighestPricePerFuelUnit = cachedHighestPricePerFuelUnit
            vehicle.cachedLowestPricePerFuelUnit = cachedLowestPricePerFuelUnit
            vehicle.cachedRecordCount = cachedRecordCount
            vehicle.cacheLastUpdated = cacheLastUpdated
        }
    }

    private struct RecordCacheSnapshot {
        let record: FuelingRecord
        let cachedPreviousOdometer: Double?
        let cachedDistanceDriven: Double?
        let cachedEfficiency: Double?
        let cachedCostPerDistance: Double?

        init(record: FuelingRecord) {
            self.record = record
            cachedPreviousOdometer = record.cachedPreviousOdometer
            cachedDistanceDriven = record.cachedDistanceDriven
            cachedEfficiency = record.cachedEfficiency
            cachedCostPerDistance = record.cachedCostPerDistance
        }

        func restore() {
            record.cachedPreviousOdometer = cachedPreviousOdometer
            record.cachedDistanceDriven = cachedDistanceDriven
            record.cachedEfficiency = cachedEfficiency
            record.cachedCostPerDistance = cachedCostPerDistance
        }
    }

    private struct EditedRecordSnapshot {
        let record: FuelingRecord
        let date: Date
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpTypeRaw: String
        let notes: String?
        let modifiedAt: Date?

        init(record: FuelingRecord) {
            self.record = record
            date = record.date
            odometer = record.odometer
            pricePerFuelUnit = record.pricePerFuelUnit
            fuelAmount = record.fuelAmount
            totalCost = record.totalCost
            fillUpTypeRaw = record.fillUpTypeRaw
            notes = record.notes
            modifiedAt = record.modifiedAt
        }

        func restore() {
            record.date = date
            record.odometer = odometer
            record.pricePerFuelUnit = pricePerFuelUnit
            record.fuelAmount = fuelAmount
            record.totalCost = totalCost
            record.fillUpTypeRaw = fillUpTypeRaw
            record.notes = notes
            record.modifiedAt = modifiedAt
        }
    }
}
