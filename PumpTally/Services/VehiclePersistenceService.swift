import Foundation
import SwiftData
import os

enum VehiclePersistenceError: LocalizedError {
    case clearedRelationshipUnavailable

    var errorDescription: String? {
        switch self {
        case .clearedRelationshipUnavailable:
            return "The fueling-record relationship was not updated before saving."
        }
    }
}

/// Coordinates vehicle and bulk-data mutations as explicit, rollback-safe saves.
///
/// This service changes no stored model or schema definitions. Callers retain
/// ownership of CloudKit push suspension so existing sync behavior is preserved.
@MainActor
enum VehiclePersistenceService {
    typealias Commit = (ModelContext) throws -> Void

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "me.tianshilei.fuelio",
        category: "VehiclePersistence"
    )

    static func insert(
        context: ModelContext,
        commit: Commit = { try $0.save() },
        makeVehicle: () -> Vehicle
    ) throws -> Vehicle {
        try establishCleanBoundary(in: context)

        let vehicle = makeVehicle()
        do {
            context.insert(vehicle)
            try SyncChangeJournal.enqueue(vehicle, in: context)
            try commit(context)
            return vehicle
        } catch {
            logger.error("Failed to insert vehicle: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            throw error
        }
    }

    static func delete(
        _ vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() }
    ) throws {
        try establishCleanBoundary(in: context)
        let snapshot = VehicleGraphSnapshot(vehicle: vehicle)
        let fuelingRecords = vehicle.fuelingRecords ?? []

        do {
            for record in fuelingRecords {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
            }
            try SyncChangeJournal.enqueue(vehicle, operation: .delete, in: context)
            context.delete(vehicle)
            context.processPendingChanges()
            try commit(context)
        } catch {
            logger.error("Failed to delete vehicle: \(error.localizedDescription, privacy: .public)")
            restoreAfterFailedMutation(in: context, snapshots: [snapshot])
            throw error
        }
    }

    static func saveSettings(
        for vehicle: Vehicle,
        name: String,
        make: String?,
        model: String?,
        year: Int?,
        unitSystem: UnitSystem,
        modifiedAt: Date,
        context: ModelContext,
        commit: Commit = { try $0.save() }
    ) throws {
        try establishCleanBoundary(in: context)
        let snapshot = VehicleGraphSnapshot(vehicle: vehicle)
        let oldUnit = vehicle.unitSystem

        do {
            vehicle.name = name
            vehicle.make = make
            vehicle.model = model
            vehicle.year = year
            vehicle.modifiedAt = modifiedAt

            if unitSystem != oldUnit {
                for record in vehicle.fuelingRecords ?? [] {
                    record.odometer = unitSystem.convertDistance(
                        from: oldUnit,
                        value: record.odometer
                    )
                    record.fuelAmount = unitSystem.convertFuel(
                        from: oldUnit,
                        value: record.fuelAmount
                    )
                    record.pricePerFuelUnit = unitSystem.convertPricePerFuel(
                        from: oldUnit,
                        value: record.pricePerFuelUnit
                    )
                    record.modifiedAt = modifiedAt
                }

                vehicle.unitSystem = unitSystem
                StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            }

            try SyncChangeJournal.enqueue(vehicle, in: context)
            if unitSystem != oldUnit {
                for record in vehicle.fuelingRecords ?? [] {
                    try SyncChangeJournal.enqueue(record, in: context)
                }
            }
            try commit(context)
        } catch {
            logger.error("Failed to save vehicle settings: \(error.localizedDescription, privacy: .public)")
            restoreAfterFailedMutation(in: context, snapshots: [snapshot])
            throw error
        }
    }

    static func clearFuelingHistory(
        for vehicle: Vehicle,
        context: ModelContext,
        commit: Commit = { try $0.save() }
    ) throws {
        try establishCleanBoundary(in: context)
        let snapshot = VehicleGraphSnapshot(vehicle: vehicle)
        let records = vehicle.fuelingRecords ?? []

        do {
            for record in records {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
                context.delete(record)
            }
            context.processPendingChanges()

            guard (vehicle.fuelingRecords ?? []).isEmpty else {
                throw VehiclePersistenceError.clearedRelationshipUnavailable
            }

            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            try commit(context)
        } catch {
            logger.error("Failed to clear fueling history: \(error.localizedDescription, privacy: .public)")
            restoreAfterFailedMutation(in: context, snapshots: [snapshot])
            throw error
        }
    }

    static func deleteAllData(
        context: ModelContext,
        commit: Commit = { try $0.save() }
    ) throws {
        try establishCleanBoundary(in: context)

        let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
        let records = try context.fetch(FetchDescriptor<FuelingRecord>())
        let snapshots = vehicles.map(VehicleGraphSnapshot.init(vehicle:))

        do {
            for record in records {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
                context.delete(record)
            }
            for vehicle in vehicles {
                try SyncChangeJournal.enqueue(vehicle, operation: .delete, in: context)
                context.delete(vehicle)
            }
            context.processPendingChanges()
            try commit(context)
        } catch {
            logger.error("Failed to delete all data: \(error.localizedDescription, privacy: .public)")
            restoreAfterFailedMutation(in: context, snapshots: snapshots)
            throw error
        }
    }

    private static func establishCleanBoundary(in context: ModelContext) throws {
        // Match the record mutation boundary: never let rollback discard
        // unrelated pending changes owned by another UI flow.
        if context.hasChanges {
            try context.save()
        }
    }

    private static func restoreAfterFailedMutation(
        in context: ModelContext,
        snapshots: [VehicleGraphSnapshot]
    ) {
        context.rollback()
        for snapshot in snapshots {
            snapshot.restore()
        }
        context.rollback()
    }

    /// Captures every stored value that settings conversion, cache rebuilding,
    /// or destructive bulk operations can leave stale in registered objects.
    private struct VehicleGraphSnapshot {
        let vehicle: Vehicle
        let name: String
        let make: String?
        let model: String?
        let year: Int?
        let unitSystemRaw: String
        let modifiedAt: Date?

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

        let records: [RecordSnapshot]

        init(vehicle: Vehicle) {
            self.vehicle = vehicle
            name = vehicle.name
            make = vehicle.make
            model = vehicle.model
            year = vehicle.year
            unitSystemRaw = vehicle.unitSystemRaw
            modifiedAt = vehicle.modifiedAt

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

            records = (vehicle.fuelingRecords ?? []).map(RecordSnapshot.init(record:))
        }

        func restore() {
            vehicle.name = name
            vehicle.make = make
            vehicle.model = model
            vehicle.year = year
            vehicle.unitSystemRaw = unitSystemRaw
            vehicle.modifiedAt = modifiedAt

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

            for record in records {
                record.restore()
            }
        }
    }

    private struct RecordSnapshot {
        let record: FuelingRecord
        let date: Date
        let odometer: Double
        let pricePerFuelUnit: Double
        let fuelAmount: Double
        let totalCost: Double
        let fillUpTypeRaw: String
        let notes: String?
        let modifiedAt: Date?

        let cachedPreviousOdometer: Double?
        let cachedDistanceDriven: Double?
        let cachedEfficiency: Double?
        let cachedCostPerDistance: Double?

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

            cachedPreviousOdometer = record.cachedPreviousOdometer
            cachedDistanceDriven = record.cachedDistanceDriven
            cachedEfficiency = record.cachedEfficiency
            cachedCostPerDistance = record.cachedCostPerDistance
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

            record.cachedPreviousOdometer = cachedPreviousOdometer
            record.cachedDistanceDriven = cachedDistanceDriven
            record.cachedEfficiency = cachedEfficiency
            record.cachedCostPerDistance = cachedCostPerDistance
        }
    }
}
