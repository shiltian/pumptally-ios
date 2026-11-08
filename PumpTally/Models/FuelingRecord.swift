import SwiftUI
import SwiftData

/// Represents the type of fill-up for a fueling record
enum FillUpType: String, Codable, CaseIterable, Sendable {
    case full = "full"        // Normal full tank fill-up
    case partial = "partial"  // Didn't fill the tank completely (affects NEXT record's MPG)
    case reset = "reset"      // Missed recording previous fill-up(s) (invalidates THIS record's MPG)

    var displayName: String {
        switch self {
        case .full: return String(localized: "Full Tank")
        case .partial: return String(localized: "Partial Fill")
        case .reset: return String(localized: "Missed Fueling")
        }
    }

    var description: String {
        switch self {
        case .full: return String(localized: "Filled the tank completely")
        case .partial: return String(localized: "Didn't fill completely (affects next efficiency calculation)")
        case .reset: return String(localized: "Missed recording previous fill-up(s)")
        }
    }

    var icon: String {
        switch self {
        case .full: return "fuelpump.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .reset: return "arrow.counterclockwise.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .full: return .green
        case .partial: return .yellow
        case .reset: return .red
        }
    }
}

@Model
final class FuelingRecord {
    var id: UUID = UUID()
    var date: Date = Date()
    var odometer: Double = 0
    var pricePerFuelUnit: Double = 0
    var fuelAmount: Double = 0
    var totalCost: Double = 0
    var fillUpTypeRaw: String = FillUpType.full.rawValue  // Stored as String for SwiftData compatibility
    var notes: String?
    var createdAt: Date = Date()
    var modifiedAt: Date?

    @Relationship(originalName: "vehicle")
    var vehicleRelationship: Vehicle?

    /// App commands construct records with an owner. The optional backing
    /// relationship lets iOS 17 maintain its inverse correctly.
    var vehicle: Vehicle {
        get {
            guard let vehicleRelationship else { preconditionFailure("Fueling record has no vehicle") }
            return vehicleRelationship
        }
        set { vehicleRelationship = newValue }
    }

    // MARK: - Cached Computed Values (for performance)
    // These are pre-computed and stored to avoid O(n²) lookups
    var cachedPreviousOdometer: Double?
    var cachedDistanceDriven: Double?
    var cachedEfficiency: Double?
    var cachedCostPerDistance: Double?

    // MARK: - Fill-up Type Accessor
    var fillUpType: FillUpType {
        get { FillUpType(rawValue: fillUpTypeRaw) ?? .full }
        set { fillUpTypeRaw = newValue.rawValue }
    }

    // Convenience computed properties for checking fill-up type
    var isPartialFillUp: Bool { fillUpType == .partial }
    var isFullFillUp: Bool { fillUpType == .full }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        odometer: Double,
        pricePerFuelUnit: Double,
        fuelAmount: Double,
        totalCost: Double,
        fillUpType: FillUpType = .full,
        notes: String? = nil,
        createdAt: Date = Date(),
        vehicle: Vehicle
    ) {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.pricePerFuelUnit = pricePerFuelUnit
        self.fuelAmount = fuelAmount
        self.totalCost = totalCost
        self.fillUpTypeRaw = fillUpType.rawValue
        self.notes = notes
        self.createdAt = createdAt
        self.vehicleRelationship = vehicle
    }

    // MARK: - Cached Value Accessors
    // Use cached values if available, otherwise compute on-demand

    /// Get previous odometer reading (cached or fallback)
    func getPreviousOdometer(fallback: Double = 0) -> Double {
        cachedPreviousOdometer ?? fallback
    }

    /// Get distance driven (cached or computed)
    func getDistanceDriven() -> Double {
        if let cached = cachedDistanceDriven {
            return cached
        }
        guard let prevOdometer = cachedPreviousOdometer, prevOdometer > 0 else { return 0 }
        return odometer - prevOdometer
    }

    /// Get efficiency ratio (cached or computed)
    /// Returns distance/fuel ratio (higher = better, regardless of unit system)
    /// For display, use vehicle.unitSystem.efficiencyDisplayValue(from:) to convert
    func getEfficiency() -> Double {
        if let cached = cachedEfficiency {
            return cached
        }

        // A complete interval with nil efficiency is an intentional result
        // (for example a partial fill), not a request to rescan the history.
        if cachedPreviousOdometer != nil, cachedDistanceDriven != nil { return 0 }

        let records = Array(vehicle.sortedRecords.reversed())
        guard let index = records.firstIndex(where: { $0.id == id }),
              index > 0 else {
            return 0
        }

        let previousRecord = records[index - 1]
        return FuelEfficiencyPolicy.rawEfficiency(
            distanceDriven: odometer - previousRecord.odometer,
            fuelAmount: fuelAmount,
            currentFillUpType: fillUpType,
            previousFillUpType: previousRecord.fillUpType,
            previousIsFirstRecord: index == 1
        ) ?? 0
    }

    /// Get cost per distance unit (cached or computed)
    func getCostPerDistance() -> Double {
        if let cached = cachedCostPerDistance {
            return cached
        }
        let distance = getDistanceDriven()
        guard distance > 0 else { return 0 }
        return totalCost / distance
    }

}
