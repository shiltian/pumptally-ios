import Foundation
import SwiftData

@Model
final class Vehicle {
    var id: UUID = UUID()
    var name: String = ""
    var make: String?
    var model: String?
    var year: Int?
    var createdAt: Date = Date()
    var modifiedAt: Date?

    /// Unit system for this vehicle: "imperial" or "metric"
    var unitSystemRaw: String = UnitSystem.imperial.rawValue
    var displayUnitSystemRaw: String?

    @Relationship(deleteRule: .cascade, inverse: \FuelingRecord.vehicle)
    var fuelingRecords: [FuelingRecord]?

    // MARK: - Cached Statistics (for performance)
    // These are pre-computed and stored to avoid recalculating on every view render
    var cachedTotalSpent: Double?
    var cachedTotalDistance: Double?
    var cachedTotalFuel: Double?
    var cachedAverageEfficiency: Double?
    var cachedAverageCostPerDistance: Double?
    var cachedAverageFillUpCost: Double?
    var cachedAveragePricePerFuelUnit: Double?
    var cachedBestEfficiency: Double?
    var cachedWorstEfficiency: Double?
    var cachedHighestPricePerFuelUnit: Double?
    var cachedLowestPricePerFuelUnit: Double?
    var cachedRecordCount: Int?
    var cacheLastUpdated: Date?

    // MARK: - Unit System Accessor

    var unitSystem: UnitSystem {
        get { UnitSystem(rawValue: unitSystemRaw) ?? .imperial }
        set { unitSystemRaw = newValue.rawValue }
    }

    /// The persisted measurement basis is independent of presentation.
    var displayUnitSystem: UnitSystem {
        get { displayUnitSystemRaw.flatMap(UnitSystem.init(rawValue:)) ?? unitSystem }
        set { displayUnitSystemRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        make: String? = nil,
        model: String? = nil,
        year: Int? = nil,
        createdAt: Date = Date(),
        unitSystem: UnitSystem = .imperial
    ) {
        self.id = id
        self.name = name
        self.make = make
        self.model = model
        self.year = year
        self.createdAt = createdAt
        self.unitSystemRaw = unitSystem.rawValue
    }

    var displayName: String {
        if let make = make, let model = model {
            if let year = year {
                return "\(year) \(make) \(model)"
            }
            return "\(make) \(model)"
        }
        return name
    }

    var sortedRecords: [FuelingRecord] {
        (fuelingRecords ?? []).sorted {
            OdometerChronologyValidator.areInIncreasingOrder($1, $0)
        }
    }

    var lastRecord: FuelingRecord? {
        (fuelingRecords ?? []).max(
            by: OdometerChronologyValidator.areInIncreasingOrder
        )
    }

    var displayRecordCount: Int {
        cachedRecordCount ?? fuelingRecords?.count ?? 0
    }

    // MARK: - Cache Status

    /// Check if cache needs to be rebuilt (no cache or records changed)
    var needsCacheRebuild: Bool {
        guard cacheLastUpdated != nil else { return true }
        guard let cachedCount = cachedRecordCount else { return true }
        return cachedCount != (fuelingRecords?.count ?? 0)
    }

    /// Invalidate the cache (call before full recalculation)
    func invalidateCache() {
        cachedTotalSpent = nil
        cachedTotalDistance = nil
        cachedTotalFuel = nil
        cachedAverageEfficiency = nil
        cachedAverageCostPerDistance = nil
        cachedAverageFillUpCost = nil
        cachedAveragePricePerFuelUnit = nil
        cachedBestEfficiency = nil
        cachedWorstEfficiency = nil
        cachedHighestPricePerFuelUnit = nil
        cachedLowestPricePerFuelUnit = nil
        cachedRecordCount = nil
        cacheLastUpdated = nil
    }
}
