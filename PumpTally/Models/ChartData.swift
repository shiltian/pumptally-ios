import Foundation

// MARK: - Pre-computed Chart Data (for performance)

/// Value-only snapshot of the fields chart preparation needs. SwiftData models
/// stay on the main actor; these snapshots can be sorted and aggregated off-main.
struct ChartRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let date: Date
    let odometer: Double
    let cachedEfficiency: Double?
    let totalCost: Double
    let pricePerFuelUnit: Double

    @MainActor
    init(record: FuelingRecord) {
        id = record.id
        date = record.date
        odometer = record.vehicle.displayUnitSystem.distanceValue(record.odometer, from: record.vehicle.unitSystem)
        cachedEfficiency = record.cachedEfficiency.map {
            record.vehicle.displayUnitSystem.efficiencyValue($0, from: record.vehicle.unitSystem)
        }
        totalCost = record.totalCost
        pricePerFuelUnit = record.vehicle.displayUnitSystem.priceValue(
            record.pricePerFuelUnit, from: record.vehicle.unitSystem)
    }

    init(
        id: UUID,
        date: Date,
        odometer: Double,
        cachedEfficiency: Double?,
        totalCost: Double,
        pricePerFuelUnit: Double
    ) {
        self.id = id
        self.date = date
        self.odometer = odometer
        self.cachedEfficiency = cachedEfficiency
        self.totalCost = totalCost
        self.pricePerFuelUnit = pricePerFuelUnit
    }
}

/// The complete, immutable dependency of chart preparation and SwiftUI's task.
struct ChartInput: Equatable, Sendable {
    let records: [ChartRecordSnapshot]
    let unitSystem: UnitSystem
    let rawAverageEfficiency: Double
    var metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat

    @MainActor
    init(vehicle: Vehicle, records: [FuelingRecord], metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat) {
        self.init(
            records: records.map(ChartRecordSnapshot.init(record:)),
            unitSystem: vehicle.displayUnitSystem,
            rawAverageEfficiency: vehicle.displayUnitSystem.efficiencyValue(
                vehicle.cachedAverageEfficiency ?? 0, from: vehicle.unitSystem),
            metricEfficiencyFormat: metricEfficiencyFormat)
    }

    init(
        records: [ChartRecordSnapshot], unitSystem: UnitSystem, rawAverageEfficiency: Double,
        metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat
    ) {
        self.records = records
        self.unitSystem = unitSystem
        self.rawAverageEfficiency = rawAverageEfficiency
        self.metricEfficiencyFormat = metricEfficiencyFormat
    }
}

/// Pre-computed data point for charts
struct ChartDataPoint: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let value: Double
}

/// Pre-computed chart data to avoid recalculation on every render
struct PrecomputedChartData: Sendable {
    let efficiencyData: [ChartDataPoint]
    let efficiencyAverage: Double
    let efficiencyYRange: ClosedRange<Double>

    let costData: [ChartDataPoint]
    let costAverage: Double
    let costYRange: ClosedRange<Double>

    let priceData: [ChartDataPoint]
    let priceAverage: Double
    let priceYRange: ClosedRange<Double>

    let showPoints: Bool  // Only show points if data count is reasonable
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    init(input: ChartInput) {
        self.init(
            records: input.records, unitSystem: input.unitSystem,
            rawAverageEfficiency: input.rawAverageEfficiency,
            metricEfficiencyFormat: input.metricEfficiencyFormat)
    }

    /// Maximum number of individual point markers to display for performance.
    static let maxPointMarkers = 100
    /// Cap every rendered series to bound Swift Charts layout and drawing work.
    static let maxTrendPoints = 200

    init(
        records: [ChartRecordSnapshot],
        unitSystem: UnitSystem,
        rawAverageEfficiency: Double,
        metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat
    ) {
        self.unitSystem = unitSystem
        self.metricEfficiencyFormat = metricEfficiencyFormat

        // Sort once, then gather all series and full-data summary statistics in
        // one pass. Downsampling happens only after the accurate summaries are
        // known, so averages and axis ranges retain their existing semantics.
        let sorted = records.sorted {
            OdometerChronologyValidator.areInIncreasingOrder(
                lhsDate: $0.date,
                lhsOdometer: $0.odometer,
                lhsID: $0.id,
                rhsDate: $1.date,
                rhsOdometer: $1.odometer,
                rhsID: $1.id
            )
        }
        self.showPoints = sorted.count <= Self.maxPointMarkers

        var allEfficiencyData: [ChartDataPoint] = []
        var allCostData: [ChartDataPoint] = []
        var allPriceData: [ChartDataPoint] = []
        allEfficiencyData.reserveCapacity(sorted.count)
        allCostData.reserveCapacity(sorted.count)
        allPriceData.reserveCapacity(sorted.count)

        var efficiencyMinimum: Double?
        var efficiencyMaximum: Double?
        var costTotal = 0.0
        var costMinimum: Double?
        var costMaximum: Double?
        var priceTotal = 0.0
        var priceMinimum: Double?
        var priceMaximum: Double?

        for record in sorted {
            let cost = record.totalCost
            allCostData.append(ChartDataPoint(id: record.id, date: record.date, value: cost))
            costTotal += cost
            costMinimum = min(costMinimum ?? cost, cost)
            costMaximum = max(costMaximum ?? cost, cost)

            let price = record.pricePerFuelUnit
            allPriceData.append(ChartDataPoint(id: record.id, date: record.date, value: price))
            priceTotal += price
            priceMinimum = min(priceMinimum ?? price, price)
            priceMaximum = max(priceMaximum ?? price, price)

            if let rawEfficiency = record.cachedEfficiency, rawEfficiency > 0 {
                let displayEfficiency = unitSystem.efficiencyDisplayValue(
                    from: rawEfficiency,
                    metricFormat: metricEfficiencyFormat
                )
                allEfficiencyData.append(
                    ChartDataPoint(
                        id: record.id,
                        date: record.date,
                        value: displayEfficiency
                    ))
                efficiencyMinimum = min(efficiencyMinimum ?? displayEfficiency, displayEfficiency)
                efficiencyMaximum = max(efficiencyMaximum ?? displayEfficiency, displayEfficiency)
            }
        }

        efficiencyData = Self.averagedDataPoints(
            allEfficiencyData,
            targetCount: Self.maxTrendPoints
        )
        costData = Self.averagedDataPoints(allCostData, targetCount: Self.maxTrendPoints)
        priceData = Self.averagedDataPoints(allPriceData, targetCount: Self.maxTrendPoints)

        if allEfficiencyData.isEmpty {
            efficiencyAverage = 0
        } else {
            efficiencyAverage = unitSystem.efficiencyDisplayValue(
                from: rawAverageEfficiency,
                metricFormat: metricEfficiencyFormat
            )
        }
        costAverage = sorted.isEmpty ? 0 : costTotal / Double(sorted.count)
        priceAverage = sorted.isEmpty ? 0 : priceTotal / Double(sorted.count)

        efficiencyYRange = Self.roundedRange(
            minimum: efficiencyMinimum,
            maximum: efficiencyMaximum,
            step: 5,
            fallback: 0...40
        )
        costYRange = Self.roundedRange(
            minimum: costMinimum,
            maximum: costMaximum,
            step: 10,
            fallback: 0...100
        )
        priceYRange = Self.roundedRange(
            minimum: priceMinimum,
            maximum: priceMaximum,
            step: 0.5,
            fallback: 0...5
        )
    }

    /// Average a date-ordered series into stable buckets. The midpoint record's
    /// ID and date keep SwiftUI identity deterministic between preparations.
    private static func averagedDataPoints(
        _ data: [ChartDataPoint],
        targetCount: Int
    ) -> [ChartDataPoint] {
        guard data.count > targetCount else { return data }

        var dataPoints: [ChartDataPoint] = []
        dataPoints.reserveCapacity(targetCount)

        let bucketSize = Double(data.count) / Double(targetCount)

        for index in 0..<targetCount {
            let startIndex = Int(Double(index) * bucketSize)
            let endIndex = min(Int(Double(index + 1) * bucketSize), data.count)

            guard startIndex < endIndex else { continue }

            var total = 0.0
            for dataIndex in startIndex..<endIndex {
                total += data[dataIndex].value
            }

            let middleIndex = startIndex + (endIndex - startIndex) / 2
            let representative = data[middleIndex]

            dataPoints.append(
                ChartDataPoint(
                    id: representative.id,
                    date: representative.date,
                    value: total / Double(endIndex - startIndex)
                ))
        }

        return dataPoints
    }

    private static func roundedRange(
        minimum: Double?,
        maximum: Double?,
        step: Double,
        fallback: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        guard let minimum, let maximum else { return fallback }
        let lowerBound = floor(minimum / step) * step
        let upperBound = ceil(maximum / step) * step
        return lowerBound...max(upperBound, lowerBound + step)
    }
}
