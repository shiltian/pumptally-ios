import SwiftUI
import Charts

struct ChartView: View {
    let input: ChartInput

    @State private var selectedChart: ChartType = .efficiency
    @State private var chartData: PrecomputedChartData?

    private var unitSystem: UnitSystem { input.unitSystem }
    private var metricEfficiencyFormat: MetricEfficiencyFormat { input.metricEfficiencyFormat }

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
        .task(id: input) {
            let input = input
            let prepared = await Task.detached(priority: .userInitiated) {
                PrecomputedChartData(input: input)
            }.value
            guard !Task.isCancelled else { return }
            chartData = prepared
        }
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
    ChartView(input: ChartInput(records: [], unitSystem: .imperial, rawAverageEfficiency: 0))
        .padding()
}
