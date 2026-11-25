import Charts
import Observation
import SwiftUI
import UIKit

struct ChartView: View {
    let data: PrecomputedChartData

    @Environment(\.locale) private var locale
    @State private var metric: ChartMetric = .efficiency
    @State private var range: ChartRange = .all
    @State private var selection = ChartSelection()

    var body: some View {
        VStack(spacing: 12) {
            Picker("Chart Type", selection: $metric) {
                Text(data.unitSystem.efficiencyUnit(for: data.metricEfficiencyFormat)).tag(ChartMetric.efficiency)
                Text("Cost").tag(ChartMetric.cost)
                Text(pricePickerLabel).tag(ChartMetric.pricePerFuelUnit)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("trends.metric")

            if let period = data.period(for: range) {
                chartCard(period)
            }
        }
        .onChange(of: range) { selection.move(to: nil) }
        .onChange(of: metric) { selection.move(to: nil) }
        .onChange(of: data.id) { selection.move(to: nil) }
    }

    private var pricePickerLabel: String {
        locale.displayCurrencySymbol.map { "\($0)\(data.unitSystem.pricePerFuelShort)" }
            ?? data.unitSystem.pricePerFuelShortLabel
    }

    private func chartCard(_ period: ChartPeriod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metric.title(for: data, monthly: range == .all))
                        .font(.appSubheadline)
                        .foregroundStyle(.secondary)
                    ChartReadout(
                        data: data, metric: metric, range: range, average: period.summary[metric]?.average,
                        selection: selection)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rangeMenu
            }

            if let yRange = data.yRange(for: metric, in: range) {
                TrendPlot(
                    data: data, period: period, metric: metric, range: range, yRange: yRange, selection: selection
                )
                .frame(height: 180)
                .accessibilityIdentifier("trends.plot")

                HStack(alignment: .firstTextBaseline) {
                    if range == .all && metric != .cost {
                        Text("Monthly average and range")
                    }
                    Spacer()
                    Text("Hold to inspect")
                }
                .font(.appCaption)
                .foregroundStyle(.secondary)
            } else {
                Text("No measurements in this range")
                    .font(.appSubheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .padding()
        .cardStyle()
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Chart Range", selection: $range) {
                ForEach(ChartRange.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(range.label)
                    .font(.appFootnote.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
        }
        .accessibilityLabel(Text("Chart Range"))
        .accessibilityValue(Text(range.title))
        .accessibilityIdentifier("trends.range")
    }
}

@MainActor
@Observable
private final class ChartSelection {
    private(set) var point: ChartPoint?

    func move(to point: ChartPoint?) {
        guard self.point != point else { return }
        self.point = point
    }
}

private struct ChartReadout: View {
    let data: PrecomputedChartData
    let metric: ChartMetric
    let range: ChartRange
    let average: Double?
    let selection: ChartSelection

    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let point = selection.point {
                let format = Date.FormatStyle(locale: locale, calendar: data.calendar, timeZone: data.calendar.timeZone)
                let date = point.date.formatted(
                    range == .all
                        ? format.month(.abbreviated).year() : format.month(.abbreviated).day().year(.twoDigits))
                let amount = metric.formatted(point.value, data: data, locale: locale)
                Text("\(date) · \(amount)")
                    .accessibilityIdentifier("trends.selection")
            } else if let average {
                Text("Avg: \(metric.formatted(average, data: data, locale: locale))")
            }
        }
        .font(.appSubheadline.monospacedDigit())
        .foregroundStyle(metric.color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Only the cursor and readout observe the selection. Chart marks and axes depend on the series.
private struct TrendPlot: View {
    let data: PrecomputedChartData
    let period: ChartPeriod
    let metric: ChartMetric
    let range: ChartRange
    let yRange: ClosedRange<Double>
    let selection: ChartSelection

    @Environment(\.locale) private var locale

    private var dateFormat: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: data.calendar, timeZone: data.calendar.timeZone)
    }

    var body: some View {
        let summary = period.summary[metric]
        let barWidth = min(8, max(1, 220 / CGFloat(summary?.count ?? 1)))
        let points = data.points(for: metric, in: range)
        Chart {
            if range == .all {
                ForEach(data.months) { month in monthMarks(month) }
            } else {
                let showPoints = (summary?.count ?? 0) <= 12
                ForEach(period.fillUps) { fillUp in
                    fillUpMarks(fillUp, showPoint: showPoints, barWidth: barWidth)
                }
            }
            if let average = summary?.average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(metric.color.opacity(0.48))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: period.dates, range: .plotDimension(padding: 5))
        .chartYScale(domain: yRange)
        .chartXAxis {
            AxisMarks(values: dateAxisValues(for: period.dates)) {
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: dateAxisFormat(for: period.dates))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine()
                if let value = mark.as(Double.self) {
                    AxisValueLabel {
                        Text(
                            metric == .efficiency
                                ? value.formatted(.number.locale(locale))
                                : value.currencyFormatted(locale: locale))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    ZStack {
                        ChartPressArea { x in
                            let clamped = min(max(x, 0), frame.width)
                            if let date = proxy.value(atX: clamped, as: Date.self) {
                                selection.move(to: points.nearest(to: date))
                            }
                        }
                        ChartCrosshair(proxy: proxy, height: frame.height, color: metric.color, selection: selection)
                            .allowsHitTesting(false)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ChartContentBuilder
    private func monthMarks(_ month: ChartMonth) -> some ChartContent {
        if let summary = month.summary[metric] {
            if metric == .cost {
                RectangleMark(
                    xStart: .value("Month", month.interval.start.addingTimeInterval(month.interval.duration * 0.14)),
                    xEnd: .value("Month end", month.interval.end.addingTimeInterval(-month.interval.duration * 0.14)),
                    yStart: .value("Zero", 0.0),
                    yEnd: .value("Average", summary.average)
                )
                .foregroundStyle(metric.color.opacity(0.84))
                .accessibilityLabel(month.id.formatted(dateFormat.month(.wide).year()))
                .accessibilityValue(metric.formatted(summary.average, data: data, locale: locale))
            } else {
                RectangleMark(
                    xStart: .value("Month", month.interval.start),
                    xEnd: .value("Month end", month.interval.end),
                    yStart: .value("Low", summary.minimum),
                    yEnd: .value("High", summary.maximum)
                )
                .foregroundStyle(metric.color.opacity(0.15))
                .accessibilityHidden(true)

                LineMark(
                    x: .value("Month", month.midpoint),
                    y: .value("Average", summary.average),
                    series: .value("Period", month.seriesStart(for: metric))
                )
                .foregroundStyle(metric.color)
                .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .symbol(.circle)
                .symbolSize(10)
                .accessibilityLabel(month.id.formatted(dateFormat.month(.wide).year()))
                .accessibilityValue(metric.formatted(summary.average, data: data, locale: locale))
            }
        }
    }

    @ChartContentBuilder
    private func fillUpMarks(_ fillUp: ChartFillUp, showPoint: Bool, barWidth: CGFloat) -> some ChartContent {
        if let value = fillUp.value(for: metric) {
            if metric == .cost {
                BarMark(
                    x: .value("Date", fillUp.date),
                    yStart: .value("Zero", 0.0),
                    yEnd: .value("Cost", value),
                    width: .fixed(barWidth)
                )
                .foregroundStyle(metric.color.opacity(0.84))
            } else {
                LineMark(x: .value("Date", fillUp.date), y: .value("Value", value))
                    .foregroundStyle(metric.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                if showPoint {
                    PointMark(x: .value("Date", fillUp.date), y: .value("Value", value))
                        .foregroundStyle(metric.color)
                        .symbolSize(18)
                }
            }
        }
    }

    private func overviewYears(in dates: ClosedRange<Date>) -> Int {
        guard range == .all else { return 0 }
        return data.calendar.dateComponents([.year], from: dates.lowerBound, to: dates.upperBound).year ?? 0
    }

    private func dateAxisValues(for dates: ClosedRange<Date>) -> AxisMarkValues {
        let years = overviewYears(in: dates)
        return years >= 2
            ? .stride(by: .year, count: max(1, (years + 5) / 6), calendar: data.calendar)
            : .automatic(desiredCount: 4)
    }

    private func dateAxisFormat(for dates: ClosedRange<Date>) -> Date.FormatStyle {
        if overviewYears(in: dates) >= 2 { return dateFormat.year() }
        if range == .threeMonths { return dateFormat.month(.abbreviated).day() }
        return dateFormat.month(.abbreviated).year(.twoDigits)
    }
}

private struct ChartCrosshair: View {
    let proxy: ChartProxy
    let height: CGFloat
    let color: Color
    let selection: ChartSelection

    var body: some View {
        if let point = selection.point,
            let position = proxy.position(for: (x: point.date, y: point.value))
        {
            Path { path in
                path.move(to: CGPoint(x: position.x, y: 0))
                path.addLine(to: CGPoint(x: position.x, y: height))
            }
            .stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            Circle()
                .fill(color)
                .overlay { Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                .frame(width: 10, height: 10)
                .position(position)
        }
    }
}

private struct ChartPressArea: UIViewRepresentable {
    let move: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0.3
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.move = move
    }

    func makeCoordinator() -> Coordinator { Coordinator(move: move) }

    final class Coordinator: NSObject {
        var move: (CGFloat) -> Void

        init(move: @escaping (CGFloat) -> Void) {
            self.move = move
        }

        @objc func handle(_ press: UILongPressGestureRecognizer) {
            if press.state == .began || press.state == .changed {
                move(press.location(in: press.view).x)
            }
        }
    }
}

private extension ChartRange {
    var label: LocalizedStringKey {
        switch self {
        case .threeMonths: "3M"
        case .year: "1Y"
        case .all: "All"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .threeMonths: "3 Months"
        case .year: "1 Year"
        case .all: "All Time"
        }
    }
}

private extension ChartMetric {
    var color: Color {
        switch self {
        case .efficiency: .purple
        case .cost: .orange
        case .pricePerFuelUnit: .green
        }
    }

    func title(for data: PrecomputedChartData, monthly: Bool) -> String {
        switch self {
        case .efficiency: data.unitSystem.efficiencyName(for: data.metricEfficiencyFormat)
        case .pricePerFuelUnit: data.unitSystem.pricePerFuelLabel
        case .cost: monthly ? String(localized: "Average Cost per Fill-up") : String(localized: "Cost per Fill-up")
        }
    }

    func formatted(_ value: Double, data: PrecomputedChartData, locale: Locale) -> String {
        switch self {
        case .efficiency:
            let amount = value.formatted(.number.locale(locale).precision(.fractionLength(1)))
            return String(localized: "\(amount) \(data.unitSystem.efficiencyUnit(for: data.metricEfficiencyFormat))")
        case .cost: return value.currencyFormatted(locale: locale)
        case .pricePerFuelUnit: return value.currencyFormatted(locale: locale, fractionDigits: 3)
        }
    }
}

#Preview {
    ChartView(
        data: PrecomputedChartData(input: ChartInput(records: [], unitSystem: .imperial, rawAverageEfficiency: 0))
    )
    .padding()
}
