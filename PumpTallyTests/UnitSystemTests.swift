import XCTest
@testable import PumpTally

final class UnitSystemTests: XCTestCase {

    // MARK: - Raw Values

    func testImperialRawValue() {
        XCTAssertEqual(UnitSystem.imperial.rawValue, "imperial")
    }

    func testMetricRawValue() {
        XCTAssertEqual(UnitSystem.metric.rawValue, "metric")
    }

    func testInitFromRawValue() {
        XCTAssertEqual(UnitSystem(rawValue: "imperial"), .imperial)
        XCTAssertEqual(UnitSystem(rawValue: "metric"), .metric)
        XCTAssertNil(UnitSystem(rawValue: "invalid"))
    }

    // MARK: - Display Labels (Imperial)

    func testImperialDistanceUnit() {
        XCTAssertEqual(UnitSystem.imperial.distanceUnit, "mi")
    }

    func testImperialDistanceName() {
        XCTAssertEqual(UnitSystem.imperial.distanceName, "Miles")
    }

    func testImperialFuelUnit() {
        XCTAssertEqual(UnitSystem.imperial.fuelUnit, "gal")
    }

    func testImperialFuelName() {
        XCTAssertEqual(UnitSystem.imperial.fuelName, "Gallons")
    }

    func testImperialEfficiencyUnit() {
        XCTAssertEqual(
            UnitSystem.imperial.efficiencyUnit(for: .defaultFormat),
            "MPG"
        )
    }

    func testImperialEfficiencyName() {
        XCTAssertEqual(
            UnitSystem.imperial.efficiencyName(for: .defaultFormat),
            "Miles Per Gallon"
        )
    }

    func testImperialPricePerFuelLabel() {
        XCTAssertEqual(UnitSystem.imperial.pricePerFuelLabel, "Price per Gallon")
    }

    func testImperialCostPerDistanceLabel() {
        XCTAssertEqual(UnitSystem.imperial.costPerDistanceLabel, "Cost per Mile")
    }

    // MARK: - Display Labels (Metric)

    func testMetricDistanceUnit() {
        XCTAssertEqual(UnitSystem.metric.distanceUnit, "km")
    }

    func testMetricDistanceName() {
        XCTAssertEqual(UnitSystem.metric.distanceName, "Kilometers")
    }

    func testMetricFuelUnit() {
        XCTAssertEqual(UnitSystem.metric.fuelUnit, "L")
    }

    func testMetricFuelName() {
        XCTAssertEqual(UnitSystem.metric.fuelName, "Liters")
    }

    func testMetricEfficiencyUnit() {
        XCTAssertEqual(
            UnitSystem.metric.efficiencyUnit(for: .defaultFormat),
            "L/100km"
        )
    }

    func testMetricEfficiencyName() {
        XCTAssertEqual(
            UnitSystem.metric.efficiencyName(for: .defaultFormat),
            "Liters per 100 km"
        )
    }

    func testMetricEfficiencyFormatLabels() {
        XCTAssertEqual(
            UnitSystem.metric.efficiencyUnit(for: .litersPer100Kilometers),
            "L/100km"
        )
        XCTAssertEqual(
            UnitSystem.metric.efficiencyName(for: .litersPer100Kilometers),
            "Liters per 100 km"
        )
        XCTAssertEqual(
            UnitSystem.metric.efficiencyUnit(for: .kilometersPerLiter),
            "km/L"
        )
        XCTAssertEqual(
            UnitSystem.metric.efficiencyName(for: .kilometersPerLiter),
            "Kilometers per Liter"
        )
    }

    func testMetricPricePerFuelLabel() {
        XCTAssertEqual(UnitSystem.metric.pricePerFuelLabel, "Price per Liter")
    }

    func testMetricCostPerDistanceLabel() {
        XCTAssertEqual(UnitSystem.metric.costPerDistanceLabel, "Cost per km")
    }

    // MARK: - Display Name / Description

    func testDisplayName() {
        XCTAssertEqual(UnitSystem.imperial.displayName, "Imperial")
        XCTAssertEqual(UnitSystem.metric.displayName, "Metric")
    }

    func testDisplayDescription() {
        XCTAssertEqual(
            UnitSystem.imperial.displayDescription(for: .defaultFormat),
            "Miles, Gallons, MPG"
        )
        XCTAssertEqual(
            UnitSystem.metric.displayDescription(for: .defaultFormat),
            "Kilometers, Liters, L/100km"
        )
        XCTAssertEqual(
            UnitSystem.metric.displayDescription(for: .kilometersPerLiter),
            "Kilometers, Liters, km/L"
        )
    }

    // MARK: - Metric Efficiency Format

    func testMetricEfficiencyFormatRawValues() {
        XCTAssertEqual(
            MetricEfficiencyFormat.litersPer100Kilometers.rawValue,
            "litersPer100Kilometers"
        )
        XCTAssertEqual(
            MetricEfficiencyFormat.kilometersPerLiter.rawValue,
            "kilometersPerLiter"
        )
    }

    func testMetricEfficiencyFormatAllCases() {
        XCTAssertEqual(MetricEfficiencyFormat.allCases.count, 2)
        XCTAssertTrue(MetricEfficiencyFormat.allCases.contains(.litersPer100Kilometers))
        XCTAssertTrue(MetricEfficiencyFormat.allCases.contains(.kilometersPerLiter))
    }

    func testMetricEfficiencyFormatCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for format in MetricEfficiencyFormat.allCases {
            let encoded = try encoder.encode(format)
            let decoded = try decoder.decode(MetricEfficiencyFormat.self, from: encoded)
            XCTAssertEqual(format, decoded)
        }
    }

    func testMetricEfficiencyFormatDefaultsToLitersPer100Kilometers() {
        XCTAssertEqual(
            MetricEfficiencyFormat.defaultFormat,
            .litersPer100Kilometers
        )
    }

    func testMetricEfficiencyFormatStorageDefaultsAndRejectsInvalidValues() {
        let suiteName = "MetricEfficiencyFormatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vehicleID = UUID()

        XCTAssertEqual(
            MetricEfficiencyFormat.stored(for: vehicleID, defaults: defaults),
            .litersPer100Kilometers
        )

        defaults.set(
            "invalid",
            forKey: MetricEfficiencyFormat.storageKey(for: vehicleID)
        )
        XCTAssertEqual(
            MetricEfficiencyFormat.stored(for: vehicleID, defaults: defaults),
            .litersPer100Kilometers
        )
    }

    func testMetricEfficiencyFormatStorageIsIndependentPerVehicle() {
        let suiteName = "MetricEfficiencyFormatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstVehicleID = UUID()
        let secondVehicleID = UUID()

        MetricEfficiencyFormat.kilometersPerLiter.store(
            for: firstVehicleID,
            defaults: defaults
        )

        XCTAssertEqual(
            MetricEfficiencyFormat.stored(for: firstVehicleID, defaults: defaults),
            .kilometersPerLiter
        )
        XCTAssertEqual(
            MetricEfficiencyFormat.stored(for: secondVehicleID, defaults: defaults),
            .litersPer100Kilometers
        )
        XCTAssertNotEqual(
            MetricEfficiencyFormat.storageKey(for: firstVehicleID),
            MetricEfficiencyFormat.storageKey(for: secondVehicleID)
        )
    }

    // MARK: - CaseIterable

    func testAllCases() {
        XCTAssertEqual(UnitSystem.allCases.count, 2)
        XCTAssertTrue(UnitSystem.allCases.contains(.imperial))
        XCTAssertTrue(UnitSystem.allCases.contains(.metric))
    }

    // MARK: - Measurement Conversion

    func testSameUnitConversionsPreserveExactBits() {
        let values: [Double] = [
            0, -0.0, .leastNonzeroMagnitude, Double(1).nextUp,
            3.45987654321, 87_654.321, .greatestFiniteMagnitude,
        ]
        for unit in UnitSystem.allCases {
            for value in values {
                XCTAssertEqual(unit.distanceValue(value, from: unit).bitPattern, value.bitPattern)
                XCTAssertEqual(unit.fuelValue(value, from: unit).bitPattern, value.bitPattern)
                XCTAssertEqual(unit.priceValue(value, from: unit).bitPattern, value.bitPattern)
                XCTAssertEqual(unit.efficiencyValue(value, from: unit).bitPattern, value.bitPattern)
                XCTAssertEqual(unit.costPerDistanceValue(value, from: unit).bitPattern, value.bitPattern)
            }
        }
    }

    func testDistanceConversionUsesInternationalMiles() {
        XCTAssertEqual(UnitSystem.metric.distanceValue(1, from: .imperial), 1.609344, accuracy: 1e-12)
        XCTAssertEqual(UnitSystem.imperial.distanceValue(1.609344, from: .metric), 1, accuracy: 1e-12)
    }

    func testFuelAndPriceConversionUsesUSGallons() {
        XCTAssertEqual(UnitSystem.metric.fuelValue(1, from: .imperial), 3.78541, accuracy: 1e-5)
        XCTAssertEqual(UnitSystem.imperial.fuelValue(3.78541, from: .metric), 1, accuracy: 1e-5)
        XCTAssertEqual(UnitSystem.metric.priceValue(3.78541, from: .imperial), 1, accuracy: 1e-5)
        XCTAssertEqual(UnitSystem.imperial.priceValue(1, from: .metric), 3.78541, accuracy: 1e-5)
    }

    func testMeasurementConversionsRoundTripInBothDirections() {
        for source in UnitSystem.allCases {
            let target: UnitSystem = source == .imperial ? .metric : .imperial
            for value in [0, 0.000123456789, 3.459, 15.5, 12_345.6789] {
                let accuracy = max(abs(value) * 1e-12, 1e-15)
                XCTAssertEqual(
                    source.distanceValue(target.distanceValue(value, from: source), from: target),
                    value, accuracy: accuracy)
                XCTAssertEqual(
                    source.fuelValue(target.fuelValue(value, from: source), from: target),
                    value, accuracy: accuracy)
                XCTAssertEqual(
                    source.priceValue(target.priceValue(value, from: source), from: target),
                    value, accuracy: accuracy)
                XCTAssertEqual(
                    source.efficiencyValue(target.efficiencyValue(value, from: source), from: target),
                    value, accuracy: accuracy)
                XCTAssertEqual(
                    source.costPerDistanceValue(target.costPerDistanceValue(value, from: source), from: target),
                    value, accuracy: accuracy)
            }
        }
    }

    // MARK: - Efficiency Display

    func testEfficiencyDisplayValueImperial() {
        // Imperial shows raw MPG value directly
        let rawEfficiency = 30.0
        let display = UnitSystem.imperial.efficiencyDisplayValue(from: rawEfficiency)
        XCTAssertEqual(display, 30.0)
    }

    func testEfficiencyDisplayValueMetric() {
        // Metric converts distance/fuel ratio to L/100km: 100 / ratio
        let rawEfficiency = 30.0 // 30 km/L internally
        let display = UnitSystem.metric.efficiencyDisplayValue(from: rawEfficiency)
        XCTAssertEqual(display, 100.0 / 30.0, accuracy: 0.001) // ~3.33 L/100km
    }

    func testEfficiencyDisplayValueMetricKilometersPerLiter() {
        let rawEfficiency = 30.0
        let display = UnitSystem.metric.efficiencyDisplayValue(
            from: rawEfficiency,
            metricFormat: .kilometersPerLiter
        )
        XCTAssertEqual(display, 30.0)
    }

    func testEfficiencyDisplayValueImperialIgnoresMetricFormat() {
        let rawEfficiency = 30.0
        XCTAssertEqual(
            UnitSystem.imperial.efficiencyDisplayValue(
                from: rawEfficiency,
                metricFormat: .litersPer100Kilometers
            ),
            30.0
        )
        XCTAssertEqual(
            UnitSystem.imperial.efficiencyDisplayValue(
                from: rawEfficiency,
                metricFormat: .kilometersPerLiter
            ),
            30.0
        )
    }

    func testEfficiencyDisplayValueZero() {
        XCTAssertEqual(UnitSystem.imperial.efficiencyDisplayValue(from: 0), 0)
        XCTAssertEqual(UnitSystem.metric.efficiencyDisplayValue(from: 0), 0)
    }

    func testEfficiencyDisplayFromDistanceAndFuel() {
        // Imperial: 300 miles / 10 gallons = 30 MPG
        let imperialDisplay = UnitSystem.imperial.efficiencyDisplayValue(distance: 300, fuel: 10)
        XCTAssertEqual(imperialDisplay, 30.0)

        // Metric: 300 km / 10 L = 30 km/L -> display as 100/30 = 3.33 L/100km
        let metricDisplay = UnitSystem.metric.efficiencyDisplayValue(distance: 300, fuel: 10)
        XCTAssertEqual(metricDisplay, 100.0 / 30.0, accuracy: 0.001)

        let metricKilometersPerLiter = UnitSystem.metric.efficiencyDisplayValue(
            distance: 300,
            fuel: 10,
            metricFormat: .kilometersPerLiter
        )
        XCTAssertEqual(metricKilometersPerLiter, 30.0)
    }

    func testEfficiencyDisplayFromZeroValues() {
        XCTAssertEqual(UnitSystem.imperial.efficiencyDisplayValue(distance: 0, fuel: 10), 0)
        XCTAssertEqual(UnitSystem.imperial.efficiencyDisplayValue(distance: 300, fuel: 0), 0)
        XCTAssertEqual(UnitSystem.metric.efficiencyDisplayValue(distance: 0, fuel: 10), 0)
        XCTAssertEqual(UnitSystem.metric.efficiencyDisplayValue(distance: 300, fuel: 0), 0)
    }

    // MARK: - Codable

    func testEncodeDecode() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for unit in UnitSystem.allCases {
            let encoded = try encoder.encode(unit)
            XCTAssertEqual(encoded, Data("\"\(unit.rawValue)\"".utf8))
            let decoded = try decoder.decode(UnitSystem.self, from: encoded)
            XCTAssertEqual(unit, decoded)
        }
        XCTAssertEqual(try decoder.decode(UnitSystem.self, from: Data("\"imperial\"".utf8)), .imperial)
        XCTAssertEqual(try decoder.decode(UnitSystem.self, from: Data("\"metric\"".utf8)), .metric)
    }

    // MARK: - Unit Conversion Integration

    func testConversionsPreservePhysicalMeasurementsAndDerivedValues() {
        for source in UnitSystem.allCases {
            let target: UnitSystem = source == .imperial ? .metric : .imperial
            let sourceLength: UnitLength = source == .imperial ? .miles : .kilometers
            let targetLength: UnitLength = target == .imperial ? .miles : .kilometers
            let sourceVolume: UnitVolume = source == .imperial ? .gallons : .liters
            let targetVolume: UnitVolume = target == .imperial ? .gallons : .liters
            let distance = 321.123456789
            let fuel = 10.573123456
            let price = 3.459876543
            let convertedDistance = target.distanceValue(distance, from: source)
            let convertedFuel = target.fuelValue(fuel, from: source)
            let convertedPrice = target.priceValue(price, from: source)

            XCTAssertEqual(
                Measurement(value: convertedDistance, unit: targetLength).converted(to: .meters).value,
                Measurement(value: distance, unit: sourceLength).converted(to: .meters).value, accuracy: 1e-9)
            XCTAssertEqual(
                Measurement(value: convertedFuel, unit: targetVolume).converted(to: .liters).value,
                Measurement(value: fuel, unit: sourceVolume).converted(to: .liters).value, accuracy: 1e-12)
            XCTAssertEqual(convertedFuel * convertedPrice, fuel * price, accuracy: 1e-12)
            XCTAssertEqual(
                target.efficiencyValue(distance / fuel, from: source),
                convertedDistance / convertedFuel, accuracy: 1e-12)
            XCTAssertEqual(
                target.costPerDistanceValue(fuel * price / distance, from: source),
                convertedFuel * convertedPrice / convertedDistance, accuracy: 1e-12)
        }
    }
}
