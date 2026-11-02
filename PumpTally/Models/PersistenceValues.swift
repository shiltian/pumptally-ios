import Foundation

/// A committed record's values and calculated result, independent of context
/// lifetime. Presentation never receives a transaction's live model.
struct SavedFuelingRecord: Identifiable, Sendable {
    let id: UUID
    let vehicleID: UUID
    let values: FuelingRecordValues
    let storageUnit: UnitSystem
    let previousOdometer: Double
    let distanceDriven: Double
    let efficiency: Double
    let costPerDistance: Double

    init(record: FuelingRecord) {
        id = record.id
        vehicleID = record.vehicle.id
        values = FuelingRecordValues(record: record)
        storageUnit = record.vehicle.unitSystem
        previousOdometer = record.cachedPreviousOdometer ?? 0
        distanceDriven = record.getDistanceDriven()
        efficiency = record.getEfficiency()
        costPerDistance = record.getCostPerDistance()
    }
}

struct VehicleSettingsValues: Equatable, Sendable {
    var name: String
    var make: String?
    var model: String?
    var year: Int?
    var displayUnit: UnitSystem

    init(vehicle: Vehicle) {
        name = vehicle.name
        make = vehicle.make
        model = vehicle.model
        year = vehicle.year
        displayUnit = vehicle.displayUnitSystem
    }

    init(name: String, make: String? = nil, model: String? = nil, year: Int? = nil, displayUnit: UnitSystem = .imperial)
    {
        self.name = name
        self.make = make
        self.model = model
        self.year = year
        self.displayUnit = displayUnit
    }
}

/// Preserve concurrent changes to untouched fields; reject a different edit to
/// the same field rather than overwriting the latest persisted value.
struct VehicleSettingsUpdate: Sendable {
    let original: VehicleSettingsValues
    let proposed: VehicleSettingsValues

    func merging(into current: VehicleSettingsValues) throws -> VehicleSettingsValues {
        func merge<Value: Equatable>(_ keyPath: KeyPath<VehicleSettingsValues, Value>) throws -> Value {
            let old = original[keyPath: keyPath]
            let new = proposed[keyPath: keyPath]
            let latest = current[keyPath: keyPath]
            guard old != new else { return latest }
            guard latest == old || latest == new else { throw VehiclePersistenceError.vehicleChanged }
            return new
        }
        return try VehicleSettingsValues(
            name: merge(\.name), make: merge(\.make), model: merge(\.model),
            year: merge(\.year), displayUnit: merge(\.displayUnit))
    }
}
