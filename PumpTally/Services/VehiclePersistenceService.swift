import Foundation
import SwiftData

enum VehiclePersistenceError: LocalizedError {
    case invalidName, vehicleUnavailable, vehicleChanged

    var errorDescription: String? {
        switch self {
        case .invalidName: return String(localized: "Enter a vehicle name.")
        case .vehicleUnavailable: return String(localized: "This vehicle is no longer available.")
        case .vehicleChanged:
            return String(
                localized: "This vehicle changed while you were editing. Reopen it to review the latest values.")
        }
    }
}

/// Vehicle commands accept values/IDs. Their transaction models never become
/// UI objects, and failed contexts need no manual graph restoration.
struct VehiclePersistenceService: Sendable {
    private let store: OwnedModelStore

    init(writer: OwnedModelStore) { store = writer }

    func create(values: VehicleSettingsValues, storageUnit: UnitSystem) async throws -> UUID {
        try await store.transaction { actor in
            let context = actor.modelContext
            guard !values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VehiclePersistenceError.invalidName
            }
            let vehicle = Vehicle(
                name: values.name, make: values.make, model: values.model, year: values.year, unitSystem: storageUnit)
            vehicle.displayUnitSystem = values.displayUnit
            vehicle.modifiedAt = Date()
            context.insert(vehicle)
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
            try SyncChangeJournal.enqueue(vehicle, in: context)
            return vehicle.id
        }
    }

    @discardableResult
    func update(vehicleID: UUID, update: VehicleSettingsUpdate) async throws -> Bool {
        try await store.transaction { actor in
            let context = actor.modelContext
            let vehicle = try vehicle(vehicleID, in: context)
            let current = VehicleSettingsValues(vehicle: vehicle)
            let values = try update.merging(into: current)
            guard values != current else { return false }
            guard !values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VehiclePersistenceError.invalidName
            }
            vehicle.name = values.name
            vehicle.make = values.make
            vehicle.model = values.model
            vehicle.year = values.year
            vehicle.displayUnitSystem = values.displayUnit
            vehicle.modifiedAt = Date()
            try SyncChangeJournal.enqueue(vehicle, in: context)
            return true
        }
    }

    func delete(vehicleID: UUID) async throws {
        try await store.transaction { actor in
            let context = actor.modelContext
            let vehicle = try vehicle(vehicleID, in: context)
            for record in vehicle.fuelingRecords ?? [] {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
            }
            try SyncChangeJournal.enqueue(vehicle, operation: .delete, in: context)
            VehiclePersistenceService.stageDeletion(vehicle, in: context)
        }
    }

    func clearFuelingHistory(vehicleID: UUID) async throws {
        try await store.transaction { actor in
            let context = actor.modelContext
            let vehicle = try vehicle(vehicleID, in: context)
            let records = vehicle.fuelingRecords ?? []
            guard !records.isEmpty else { return }
            for record in records {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
                context.delete(record)
            }
            context.processPendingChanges()
            StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        }
    }

    func deleteAllData() async throws {
        try await store.transaction { actor in
            let context = actor.modelContext
            for record in try context.fetch(FetchDescriptor<FuelingRecord>()) {
                try SyncChangeJournal.enqueue(record, operation: .delete, in: context)
            }
            for vehicle in try context.fetch(FetchDescriptor<Vehicle>()) {
                try SyncChangeJournal.enqueue(vehicle, operation: .delete, in: context)
                VehiclePersistenceService.stageDeletion(vehicle, in: context)
            }
        }
    }

    /// Delete the whole graph in the caller's transaction. iOS 17 doesn't
    /// reliably cascade; detach first so newer runtimes never traverse deleted children.
    static func stageDeletion(_ vehicle: Vehicle, in context: ModelContext) {
        let children = vehicle.fuelingRecords ?? []
        vehicle.fuelingRecords = []
        for child in children { context.delete(child) }
        context.delete(vehicle)
    }

    /// Staged by review in its owned transaction after revalidating the exact
    /// inbox payload. Adopting legacy storage units never queues a bulk upload.
    static func stageLegacyStorageUnit(
        vehicle: Vehicle, metadata: CloudSnapshotValidator.VehicleSnapshot, inboxKey: String, context: ModelContext
    ) throws {
        let source = vehicle.unitSystem
        let display = vehicle.displayUnitSystem
        let converted = (vehicle.fuelingRecords ?? []).map {
            ($0, FuelingRecordValues(record: $0).converted(from: source, to: metadata.unitSystem))
        }
        guard
            converted.allSatisfy({
                $0.1.odometer.isFinite && $0.1.fuelAmount.isFinite && $0.1.pricePerFuelUnit.isFinite
            })
        else { throw FuelingRecordEditingError.invalidInput }
        for (record, values) in converted {
            record.odometer = values.odometer
            record.fuelAmount = values.fuelAmount
            record.pricePerFuelUnit = values.pricePerFuelUnit
        }
        vehicle.unitSystem = metadata.unitSystem
        vehicle.displayUnitSystem = display
        vehicle.name = metadata.name
        vehicle.make = metadata.make
        vehicle.model = metadata.model
        vehicle.year = metadata.year
        vehicle.modifiedAt = metadata.modifiedAt
        if let preference = metadata.displayUnitSystemRaw { vehicle.displayUnitSystemRaw = preference }
        StatisticsCacheService.recalculateAllStatistics(for: vehicle)
        for entry in try context.fetch(
            FetchDescriptor<PendingRemoteChange>(predicate: #Predicate { $0.key == inboxKey }))
        { context.delete(entry) }
    }

    private func vehicle(_ id: UUID, in context: ModelContext) throws -> Vehicle {
        var query = FetchDescriptor<Vehicle>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        guard let vehicle = try context.fetch(query).first else { throw VehiclePersistenceError.vehicleUnavailable }
        return vehicle
    }
}
