import Foundation

extension UnitSystem {
    private var lengthUnit: UnitLength { self == .imperial ? .miles : .kilometers }
    private var volumeUnit: UnitVolume { self == .imperial ? .gallons : .liters }

    func distanceValue(_ value: Double, from source: UnitSystem) -> Double {
        guard source != self else { return value }
        return Measurement(value: value, unit: source.lengthUnit).converted(to: lengthUnit).value
    }

    func fuelValue(_ value: Double, from source: UnitSystem) -> Double {
        guard source != self else { return value }
        return Measurement(value: value, unit: source.volumeUnit).converted(to: volumeUnit).value
    }

    func priceValue(_ value: Double, from source: UnitSystem) -> Double {
        value / fuelValue(1, from: source)
    }

    func efficiencyValue(_ value: Double, from source: UnitSystem) -> Double {
        distanceValue(value, from: source) / fuelValue(1, from: source)
    }

    func costPerDistanceValue(_ value: Double, from source: UnitSystem) -> Double {
        value / distanceValue(1, from: source)
    }
}

/// Controls how Metric fuel efficiency is presented on this device.
///
/// This is a local display preference, not part of the persisted vehicle or
/// fueling-record data model.
enum MetricEfficiencyFormat: String, Codable, CaseIterable, Sendable {
    case litersPer100Kilometers
    case kilometersPerLiter

    static let defaultFormat: MetricEfficiencyFormat = .litersPer100Kilometers

    private static let storageKeyPrefix = "metricEfficiencyFormat."

    static func storageKey(for vehicleID: UUID) -> String {
        storageKeyPrefix + vehicleID.uuidString
    }

    static func stored(
        for vehicleID: UUID,
        defaults: UserDefaults = .standard
    ) -> MetricEfficiencyFormat {
        guard
            let rawValue = defaults.string(forKey: storageKey(for: vehicleID)),
            let format = MetricEfficiencyFormat(rawValue: rawValue)
        else {
            return defaultFormat
        }
        return format
    }

    func store(
        for vehicleID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(rawValue, forKey: Self.storageKey(for: vehicleID))
    }

    var unit: String {
        switch self {
        case .litersPer100Kilometers: return "L/100km"
        case .kilometersPerLiter: return "km/L"
        }
    }

    var name: String {
        switch self {
        case .litersPer100Kilometers:
            return String(localized: "Liters per 100 km")
        case .kilometersPerLiter:
            return String(localized: "Kilometers per Liter")
        }
    }

    var unitSystemDescription: String {
        switch self {
        case .litersPer100Kilometers:
            return String(localized: "Kilometers, Liters, L/100km")
        case .kilometersPerLiter:
            return String(localized: "Kilometers, Liters, km/L")
        }
    }

    func displayValue(from rawEfficiency: Double) -> Double {
        switch self {
        case .litersPer100Kilometers:
            return 100.0 / rawEfficiency
        case .kilometersPerLiter:
            return rawEfficiency
        }
    }
}

/// Represents the measurement unit system for a vehicle
enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case imperial // miles, gallons, MPG
    case metric   // km, liters, L/100km

    // MARK: - Display Labels

    /// Short distance unit: "mi" or "km"
    var distanceUnit: String {
        switch self {
        case .imperial: return "mi"
        case .metric: return "km"
        }
    }

    /// Full distance name: "Miles" or "Kilometers"
    var distanceName: String {
        switch self {
        case .imperial: return String(localized: "Miles")
        case .metric: return String(localized: "Kilometers")
        }
    }

    /// Short fuel unit: "gal" or "L"
    var fuelUnit: String {
        switch self {
        case .imperial: return "gal"
        case .metric: return "L"
        }
    }

    /// Full fuel name: "Gallons" or "Liters"
    var fuelName: String {
        switch self {
        case .imperial: return String(localized: "Gallons")
        case .metric: return String(localized: "Liters")
        }
    }

    /// Efficiency unit: "MPG" or the selected metric unit
    func efficiencyUnit(for metricFormat: MetricEfficiencyFormat) -> String {
        switch self {
        case .imperial: return "MPG"
        case .metric: return metricFormat.unit
        }
    }

    /// Full efficiency name: "Miles Per Gallon" or the selected metric name
    func efficiencyName(for metricFormat: MetricEfficiencyFormat) -> String {
        switch self {
        case .imperial: return String(localized: "Miles Per Gallon")
        case .metric: return metricFormat.name
        }
    }

    /// Label for price per fuel unit: "Price per Gallon" or "Price per Liter"
    var pricePerFuelLabel: String {
        switch self {
        case .imperial: return String(localized: "Price per Gallon")
        case .metric: return String(localized: "Price per Liter")
        }
    }

    /// Short price per fuel unit: "$/gal" or "$/L"
    var pricePerFuelShort: String {
        switch self {
        case .imperial: return "/gal"
        case .metric: return "/L"
        }
    }

    /// Label for cost per distance: "Cost per Mile" or "Cost per km"
    var costPerDistanceLabel: String {
        switch self {
        case .imperial: return String(localized: "Cost per Mile")
        case .metric: return String(localized: "Cost per km")
        }
    }

    /// Short cost per distance: "/mile" or "/km"
    var costPerDistanceShort: String {
        switch self {
        case .imperial: return "/mile"
        case .metric: return "/km"
        }
    }

    /// Average cost per distance label for dashboard: "Avg $/Mile" or "Avg $/km"
    var avgCostPerDistanceLabel: String {
        switch self {
        case .imperial: return String(localized: "Avg $/Mile")
        case .metric: return String(localized: "Avg $/km")
        }
    }

    /// Display name for the unit system itself
    var displayName: String {
        switch self {
        case .imperial: return String(localized: "Imperial")
        case .metric: return String(localized: "Metric")
        }
    }

    /// Description of what the unit system uses
    func displayDescription(for metricFormat: MetricEfficiencyFormat) -> String {
        switch self {
        case .imperial: return String(localized: "Miles, Gallons, MPG")
        case .metric: return metricFormat.unitSystemDescription
        }
    }

    /// Short label for price per fuel unit: "Price/Gallon" or "Price/Liter"
    var pricePerFuelShortLabel: String {
        switch self {
        case .imperial: return String(localized: "Price/Gallon")
        case .metric: return String(localized: "Price/Liter")
        }
    }

    // MARK: - Efficiency Display

    /// Convert raw efficiency value (distance/fuel ratio) to a display value.
    ///
    /// The cache always stores `distance / fuel` regardless of unit system.
    /// - Imperial: return as-is (MPG, higher = better)
    /// - Metric: use the selected local display format
    func efficiencyDisplayValue(
        from rawEfficiency: Double,
        metricFormat: MetricEfficiencyFormat = .defaultFormat
    ) -> Double {
        guard rawEfficiency > 0 else { return 0 }
        switch self {
        case .imperial:
            return rawEfficiency
        case .metric:
            return metricFormat.displayValue(from: rawEfficiency)
        }
    }

    /// Compute efficiency display value from distance and fuel amounts
    func efficiencyDisplayValue(
        distance: Double,
        fuel: Double,
        metricFormat: MetricEfficiencyFormat = .defaultFormat
    ) -> Double {
        guard distance > 0, fuel > 0 else { return 0 }
        let rawRatio = distance / fuel
        return efficiencyDisplayValue(from: rawRatio, metricFormat: metricFormat)
    }

}
