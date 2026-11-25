import Foundation

enum ChartMetric {
    case efficiency
    case cost
    case pricePerFuelUnit
}

enum ChartRange: CaseIterable {
    case threeMonths
    case year
    case all
}

/// A chart-only snapshot. Managed records and their caches remain on the store executor.
struct ChartRecordSnapshot: Equatable, Sendable {
    let id: UUID
    let date: Date
    let odometer: Double
    let cachedEfficiency: Double?
    let fuelAmount: Double
    let totalCost: Double
    let pricePerFuelUnit: Double
}

/// The complete, immutable dependency of cached chart preparation.
struct ChartInput: Equatable, Sendable {
    let records: [ChartRecordSnapshot]
    let unitSystem: UnitSystem
    let rawAverageEfficiency: Double
    var metricEfficiencyFormat: MetricEfficiencyFormat = .defaultFormat
    var calendar: Calendar = .current
}

struct ChartFillUp: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let efficiency: Double?
    let cost: Double
    let price: Double
    fileprivate let rawEfficiency: Double?
    fileprivate let fuelAmount: Double

    fileprivate init(_ record: ChartRecordSnapshot, input: ChartInput) {
        id = record.id
        date = record.date
        cost = record.totalCost
        price = record.pricePerFuelUnit
        fuelAmount = record.fuelAmount
        let raw = record.cachedEfficiency.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        rawEfficiency = raw
        efficiency = raw.map {
            input.unitSystem.efficiencyDisplayValue(from: $0, metricFormat: input.metricEfficiencyFormat)
        }
    }

    func value(for metric: ChartMetric) -> Double? {
        let value: Double?
        switch metric {
        case .efficiency: value = efficiency
        case .cost: value = cost
        case .pricePerFuelUnit: value = price
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}

struct ChartMetricSummary: Equatable, Sendable {
    let count: Int
    let average: Double
    let minimum: Double
    let maximum: Double
}

struct ChartSummary: Sendable {
    let efficiency: ChartMetricSummary?
    let cost: ChartMetricSummary?
    let price: ChartMetricSummary?

    subscript(metric: ChartMetric) -> ChartMetricSummary? {
        switch metric {
        case .efficiency: efficiency
        case .cost: cost
        case .pricePerFuelUnit: price
        }
    }
}

struct ChartMonth: Identifiable, Sendable {
    let interval: DateInterval
    let summary: ChartSummary
    let priceSeriesStart: Date
    let efficiencySeriesStart: Date

    var id: Date { interval.start }
    var midpoint: Date { interval.start.addingTimeInterval(interval.duration / 2) }

    func seriesStart(for metric: ChartMetric) -> Date {
        metric == .efficiency ? efficiencySeriesStart : priceSeriesStart
    }
}

struct ChartPeriod: Sendable {
    let dates: ClosedRange<Date>
    let fillUps: ArraySlice<ChartFillUp>
    let summary: ChartSummary
}

struct ChartPoint: Equatable, Sendable {
    let date: Date
    let value: Double
}

extension Array where Element == ChartPoint {
    /// Search an ascending series, preferring the earlier point on a tie.
    func nearest(to date: Date) -> ChartPoint? {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower == 0 { return first }
        if lower == count { return last }
        let before = self[lower - 1]
        let after = self[lower]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date) ? before : after
    }
}

/// Calendar grouping, unit conversion and range statistics run once per chart input.
struct PrecomputedChartData: Sendable {
    let id = UUID()
    let fillUps: [ChartFillUp]
    let months: [ChartMonth]
    let unitSystem: UnitSystem
    let metricEfficiencyFormat: MetricEfficiencyFormat
    let calendar: Calendar

    private let all: ChartPeriod?
    private let year: ChartPeriod?
    private let threeMonths: ChartPeriod?

    init(input: ChartInput) {
        let ordered = ChartInput(
            records: input.records.sorted {
                OdometerChronologyValidator.areInIncreasingOrder(
                    lhsDate: $0.date, lhsOdometer: $0.odometer, lhsID: $0.id,
                    rhsDate: $1.date, rhsOdometer: $1.odometer, rhsID: $1.id)
            }, unitSystem: input.unitSystem, rawAverageEfficiency: input.rawAverageEfficiency,
            metricEfficiencyFormat: input.metricEfficiencyFormat, calendar: input.calendar)
        self.init(chronologicalInput: ordered)
    }

    init(chronologicalInput input: ChartInput) {
        unitSystem = input.unitSystem
        metricEfficiencyFormat = input.metricEfficiencyFormat
        calendar = input.calendar
        let fillUps = input.records.map { ChartFillUp($0, input: input) }
        self.fillUps = fillUps
        months = Self.months(from: fillUps, input: input)
        if let first = fillUps.first, let last = fillUps.last {
            let start = months.first?.interval.start ?? first.date
            let end = months.last?.interval.end ?? last.date
            all = ChartPeriod(
                dates: start...end, fillUps: fillUps[...],
                summary: Self.summary(fillUps[...], input: input, lifetimeAverage: input.rawAverageEfficiency))
            year = Self.period(
                fillUps, starting: input.calendar.date(byAdding: .year, value: -1, to: last.date), input: input)
            threeMonths = Self.period(
                fillUps, starting: input.calendar.date(byAdding: .month, value: -3, to: last.date), input: input)
        } else {
            all = nil
            year = nil
            threeMonths = nil
        }
    }

    func period(for range: ChartRange) -> ChartPeriod? {
        switch range {
        case .all: all
        case .year: year
        case .threeMonths: threeMonths
        }
    }

    func points(for metric: ChartMetric, in range: ChartRange) -> [ChartPoint] {
        if range == .all {
            return months.compactMap { month in
                month.summary[metric].map { ChartPoint(date: month.midpoint, value: $0.average) }
            }
        }
        guard let fillUps = period(for: range)?.fillUps else { return [] }
        var points: [ChartPoint] = []
        points.reserveCapacity(fillUps.count)
        for fillUp in fillUps {
            if let value = fillUp.value(for: metric), points.last?.date != fillUp.date {
                points.append(ChartPoint(date: fillUp.date, value: value))
            }
        }
        return points
    }

    func yRange(for metric: ChartMetric, in range: ChartRange) -> ClosedRange<Double>? {
        guard let summary = period(for: range)?.summary[metric] else { return nil }
        let lower: Double
        let upper: Double
        let step: Double
        switch metric {
        case .efficiency:
            (lower, upper, step) = (min(summary.minimum, summary.average), max(summary.maximum, summary.average), 5)
        case .cost:
            let monthlyCosts = months.lazy.compactMap { $0.summary.cost?.average }
            lower = min(0, range == .all ? monthlyCosts.min() ?? 0 : summary.minimum)
            upper = range == .all ? monthlyCosts.max() ?? 0 : summary.maximum
            step = 10
        case .pricePerFuelUnit:
            (lower, upper, step) = (summary.minimum, summary.maximum, 0.5)
        }
        let roundedLower = floor(lower / step) * step
        return roundedLower...max(roundedLower + step, ceil(upper / step) * step)
    }

    private static func period(_ fillUps: [ChartFillUp], starting start: Date?, input: ChartInput) -> ChartPeriod? {
        guard let start, let last = fillUps.last,
            let firstIndex = fillUps.firstIndex(where: { $0.date >= start })
        else { return nil }
        let visible = fillUps[firstIndex...]
        return ChartPeriod(dates: start...last.date, fillUps: visible, summary: summary(visible, input: input))
    }

    private static func months(from fillUps: [ChartFillUp], input: ChartInput) -> [ChartMonth] {
        var months: [ChartMonth] = []
        var start = fillUps.startIndex
        while start < fillUps.endIndex {
            guard let interval = input.calendar.dateInterval(of: .month, for: fillUps[start].date) else {
                start += 1
                continue
            }
            var end = start + 1
            while end < fillUps.endIndex, fillUps[end].date < interval.end { end += 1 }

            let records = fillUps[start..<end]
            let summary = summary(records, input: input)
            let previous = months.last
            let consecutive = previous?.interval.end == interval.start
            months.append(
                ChartMonth(
                    interval: interval, summary: summary,
                    priceSeriesStart: consecutive ? previous?.priceSeriesStart ?? interval.start : interval.start,
                    efficiencySeriesStart: consecutive && previous?.summary.efficiency != nil
                        ? previous?.efficiencySeriesStart ?? interval.start : interval.start))
            start = end
        }
        return months
    }

    private static func summary(
        _ fillUps: ArraySlice<ChartFillUp>, input: ChartInput, lifetimeAverage: Double? = nil
    ) -> ChartSummary {
        var price = Totals()
        var cost = Totals()
        var efficiency = Totals()
        var weightedEfficiency = 0.0
        var eligibleFuel = 0.0
        for fillUp in fillUps {
            price.add(fillUp.price)
            cost.add(fillUp.cost)
            if let value = fillUp.efficiency, let raw = fillUp.rawEfficiency {
                efficiency.add(value)
                if fillUp.fuelAmount.isFinite && fillUp.fuelAmount > 0 {
                    weightedEfficiency += raw * fillUp.fuelAmount
                    eligibleFuel += fillUp.fuelAmount
                }
            }
        }
        // Weight the distance-per-fuel ratio before converting to L/100km.
        // Each eligible interval belongs to the month in which it ended.
        let raw = lifetimeAverage ?? (eligibleFuel > 0 ? weightedEfficiency / eligibleFuel : 0)
        let average =
            raw.isFinite && raw > 0
            ? input.unitSystem.efficiencyDisplayValue(from: raw, metricFormat: input.metricEfficiencyFormat) : nil
        return ChartSummary(
            efficiency: efficiency.summary(average: average), cost: cost.summary(), price: price.summary())
    }

    private struct Totals {
        private var count = 0
        private var sum = 0.0
        private var minimum = Double.infinity
        private var maximum = -Double.infinity

        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            count += 1
            sum += value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }

        func summary(average: Double? = nil) -> ChartMetricSummary? {
            guard count > 0 else { return nil }
            return ChartMetricSummary(
                count: count, average: average ?? sum / Double(count), minimum: minimum, maximum: maximum)
        }
    }
}
