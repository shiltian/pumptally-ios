import SwiftUI
import Charts

// MARK: - Pre-computed Chart Data (for performance)

/// Value-only snapshot of the fields chart preparation needs. SwiftData models
/// stay on the main actor; these snapshots can be sorted and aggregated off-main.
struct ChartRecordSnapshot: Sendable {
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
                allEfficiencyData.append(ChartDataPoint(
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

            dataPoints.append(ChartDataPoint(
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

struct ChartView: View {
    let records: [FuelingRecord]
    let unitSystem: UnitSystem
    let rawAverageEfficiency: Double
    let metricEfficiencyFormat: MetricEfficiencyFormat
    let invalidationKey: String

    @State private var selectedChart: ChartType = .efficiency
    @State private var chartData: PrecomputedChartData?
    @State private var preparedKey: PreparationKey?

    init(
        records: [FuelingRecord],
        unitSystem: UnitSystem,
        rawAverageEfficiency: Double,
        metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat,
        invalidationKey: String? = nil
    ) {
        self.records = records
        self.unitSystem = unitSystem
        self.rawAverageEfficiency = rawAverageEfficiency
        self.metricEfficiencyFormat = metricEfficiencyFormat
        self.invalidationKey = invalidationKey ?? "\(records.count)"
    }

    enum ChartType: CaseIterable {
        case efficiency
        case cost
        case pricePerFuelUnit

        func label(
            for unitSystem: UnitSystem,
            metricEfficiencyFormat: MetricEfficiencyFormat
        ) -> String {
            switch self {
            case .efficiency:
                return unitSystem.efficiencyUnit(for: metricEfficiencyFormat)
            case .cost: return String(localized: "Cost")
            case .pricePerFuelUnit: return "$\(unitSystem.pricePerFuelShort)"
            }
        }
    }

    private struct PreparationKey: Equatable, Sendable {
        let invalidationKey: String
        let unitSystem: UnitSystem
        let rawAverageEfficiency: Double
        let metricEfficiencyFormat: MetricEfficiencyFormat
    }

    private var preparationKey: PreparationKey {
        PreparationKey(
            invalidationKey: invalidationKey,
            unitSystem: unitSystem,
            rawAverageEfficiency: rawAverageEfficiency,
            metricEfficiencyFormat: metricEfficiencyFormat
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            // Chart Type Picker
            Picker("Chart Type", selection: $selectedChart) {
                ForEach(ChartType.allCases, id: \.self) { type in
                    Text(type.label(
                        for: unitSystem,
                        metricEfficiencyFormat: metricEfficiencyFormat
                    ))
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Chart - use pre-computed data
            Group {
                if let data = chartData {
                    switch selectedChart {
                    case .efficiency:
                        EfficiencyChart(
                            data: data.efficiencyData,
                            average: data.efficiencyAverage,
                            yRange: data.efficiencyYRange,
                            showPoints: data.showPoints,
                            unitSystem: unitSystem,
                            metricEfficiencyFormat: metricEfficiencyFormat
                        )
                    case .cost:
                        CostChart(
                            data: data.costData,
                            average: data.costAverage,
                            yRange: data.costYRange
                        )
                    case .pricePerFuelUnit:
                        PricePerFuelUnitChart(data: data.priceData, average: data.priceAverage, yRange: data.priceYRange, showPoints: data.showPoints, unitSystem: unitSystem)
                    }
                } else {
                    ProgressView()
                        .frame(height: 200)
                }
            }
            .padding()
            .cardStyle()
        }
        .task(id: preparationKey) {
            await prepareChartData(for: preparationKey)
        }
    }

    @MainActor
    private func prepareChartData(for key: PreparationKey) async {
        guard preparedKey != key || chartData == nil else { return }

        // Copy only primitive values while on the model's actor, then perform
        // sorting, aggregation, and downsampling away from UI rendering.
        let snapshots = records.map(ChartRecordSnapshot.init(record:))
        let preparedData = await Task.detached(priority: .userInitiated) {
            PrecomputedChartData(
                records: snapshots,
                unitSystem: key.unitSystem,
                rawAverageEfficiency: key.rawAverageEfficiency,
                metricEfficiencyFormat: key.metricEfficiencyFormat
            )
        }.value

        guard !Task.isCancelled, key == preparationKey else { return }
        chartData = preparedData
        preparedKey = key
    }
}

struct EfficiencyChart: View {
    let data: [ChartDataPoint]
    let average: Double
    let yRange: ClosedRange<Double>
    let showPoints: Bool
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat

    var body: some View {
        let efficiencyUnit = unitSystem.efficiencyUnit(for: metricEfficiencyFormat)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(unitSystem.efficiencyName(for: metricEfficiencyFormat))
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Avg: \(average.formatted(.number.precision(.fractionLength(1)))) \(efficiencyUnit)")
                    .font(.appCaption)
                    .foregroundColor(.purple)
            }

            Chart {
                ForEach(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(efficiencyUnit, point.value)
                    )
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", yRange.lowerBound),
                        yEnd: .value(efficiencyUnit, point.value)
                    )
                    .foregroundStyle(LinearGradient.efficiencyChartFill)

                    // Only show points if there aren't too many
                    if showPoints {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(efficiencyUnit, point.value)
                        )
                        .foregroundStyle(.purple)
                        .symbolSize(40)
                    }
                }

                // Average line
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.purple.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYScale(domain: yRange)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().year(.twoDigits))
                }
            }
        }
    }
}

struct CostChart: View {
    let data: [ChartDataPoint]
    let average: Double
    let yRange: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cost per Fill-up")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Avg: \(average.currencyFormatted)")
                    .font(.appCaption)
                    .foregroundColor(.orange)
            }

            Chart {
                ForEach(data) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", yRange.lowerBound),
                        yEnd: .value("Cost", point.value)
                    )
                    .foregroundStyle(Color.orange)
                    .cornerRadius(4)
                }

                // Average line
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYScale(domain: yRange)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let cost = value.as(Double.self) {
                            Text(cost.currencyFormatted)
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().year(.twoDigits))
                }
            }
        }
    }
}

struct PricePerFuelUnitChart: View {
    let data: [ChartDataPoint]
    let average: Double
    let yRange: ClosedRange<Double>
    let showPoints: Bool
    let unitSystem: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(unitSystem.pricePerFuelLabel)
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Avg: \(average.currencyFormatted)")
                    .font(.appCaption)
                    .foregroundColor(.green)
            }

            Chart {
                ForEach(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.value)
                    )
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", yRange.lowerBound),
                        yEnd: .value("Price", point.value)
                    )
                    .foregroundStyle(LinearGradient.priceChartFill)

                    // Only show points if there aren't too many
                    if showPoints {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Price", point.value)
                        )
                        .foregroundStyle(.green)
                        .symbolSize(40)
                    }
                }

                // Average line
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.green.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
            .chartYScale(domain: yRange)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(price.currencyFormatted)
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day().year(.twoDigits))
                }
            }
        }
    }
}

#Preview {
    ChartView(
        records: [],
        unitSystem: .imperial,
        rawAverageEfficiency: 0
    )
        .padding()
}
