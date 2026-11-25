import XCTest
@testable import PumpTally

final class PrecomputedChartDataTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func snapshot(
        _ index: Int, date: Date, odometer: Double? = nil, efficiency: Double? = nil,
        fuel: Double = 10, cost: Double = 30, price: Double = 3
    ) -> ChartRecordSnapshot {
        ChartRecordSnapshot(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            date: date, odometer: odometer ?? Double(index), cachedEfficiency: efficiency,
            fuelAmount: fuel, totalCost: cost, pricePerFuelUnit: price)
    }

    private func makeData(
        _ records: [ChartRecordSnapshot], average: Double = 0,
        units: UnitSystem = .imperial, format: MetricEfficiencyFormat = .defaultFormat, calendar: Calendar? = nil
    ) -> PrecomputedChartData {
        PrecomputedChartData(
            input: ChartInput(
                records: records, unitSystem: units, rawAverageEfficiency: average,
                metricEfficiencyFormat: format, calendar: calendar ?? self.calendar))
    }

    func testEmptyRecordsHaveNoPeriodsOrMonths() {
        let data = makeData([])
        XCTAssertTrue(data.fillUps.isEmpty)
        XCTAssertTrue(data.months.isEmpty)
        for range in ChartRange.allCases { XCTAssertNil(data.period(for: range)) }
    }

    func testMonthlySummariesKeepSpikesAndUseMeasuredCosts() throws {
        let records = [
            snapshot(0, date: date(2020, 1, 2), cost: 30, price: 3.40),
            snapshot(1, date: date(2020, 1, 7), cost: 20, price: 3.45),
            snapshot(2, date: date(2020, 1, 18), cost: 71.23, price: 5.60),
            snapshot(3, date: date(2020, 1, 31), cost: 38, price: 3.50),
            snapshot(4, date: date(2020, 3, 1), cost: 35, price: 3.75),
        ]
        let data = makeData(Array(records.reversed()))
        XCTAssertEqual(data.months.count, 2)
        let january = try XCTUnwrap(data.months.first)
        let prices = try XCTUnwrap(january.summary.price)
        XCTAssertEqual(prices.average, 3.9875, accuracy: 0.000_001)
        XCTAssertEqual(prices.minimum, 3.40)
        XCTAssertEqual(prices.maximum, 5.60)
        XCTAssertEqual(january.summary.cost?.average, (30 + 20 + 71.23 + 38) / 4)
        XCTAssertEqual(january.summary.cost?.count, 4)
        XCTAssertEqual(data.fillUps[2].cost.bitPattern, records[2].totalCost.bitPattern)
        XCTAssertEqual(data.months.map { calendar.component(.month, from: $0.id) }, [1, 3])
        XCTAssertNotEqual(data.months[1].priceSeriesStart, january.priceSeriesStart)
        XCTAssertEqual(data.yRange(for: .cost, in: .all), 0...40)
        XCTAssertEqual(data.yRange(for: .cost, in: .year), 0...80)
        XCTAssertEqual(data.yRange(for: .pricePerFuelUnit, in: .all), 3...6)
    }

    func testLargeHistoryUsesCalendarMonthsAndRetainsAll800Records() throws {
        let start = date(2020, 1, 1)
        let records = (0..<800).map { index in
            snapshot(
                index, date: start.addingTimeInterval(Double(index) * 172_800),
                efficiency: 28, cost: 40 + Double(index % 9), price: index == 2 ? 5.6 : 3.5)
        }
        let data = makeData(records, average: 28)
        XCTAssertEqual(data.months.count, 53)
        XCTAssertEqual(data.fillUps.map(\.id), records.map(\.id))
        XCTAssertEqual(data.months.compactMap { $0.summary.cost?.count }.reduce(0, +), 800)
        XCTAssertEqual(data.months.first?.summary.price?.maximum, 5.6)
        XCTAssertEqual(data.period(for: .all)?.summary.efficiency?.average, 28)

        let latest = try XCTUnwrap(records.last?.date)
        for (range, component, value) in [
            (ChartRange.threeMonths, Calendar.Component.month, -3),
            (.year, .year, -1),
        ] {
            let start = try XCTUnwrap(calendar.date(byAdding: component, value: value, to: latest))
            let period = try XCTUnwrap(data.period(for: range))
            let expected = records.filter { $0.date >= start }
            XCTAssertEqual(period.dates, start...latest)
            XCTAssertEqual(period.fillUps.map(\.id), expected.map(\.id))
            XCTAssertEqual(period.fillUps.map(\.cost), expected.map(\.totalCost))
        }
    }

    func testMonthUsesLocalCalendarAtTheBoundary() throws {
        let before = snapshot(0, date: date(2024, 2, 1, hour: 0), cost: 20)
        let after = snapshot(1, date: date(2024, 2, 1, hour: 12), cost: 40)
        var newYork = calendar
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let data = makeData([before, after], calendar: newYork)
        XCTAssertEqual(data.months.count, 2)
        XCTAssertEqual(newYork.component(.month, from: data.months[0].id), 1)
        XCTAssertEqual(data.months.map { $0.summary.cost?.average }, [20, 40])
        XCTAssertEqual(data.months[0].interval.end, data.months[1].id)
        XCTAssertEqual(makeData([before, after]).months.count, 1)
    }

    func testMonthlyEfficiencyUsesFuelWeightBeforeConvertingToLitersPer100Km() throws {
        let records = [
            snapshot(0, date: date(2023, 1, 2), efficiency: 10, fuel: 10),
            snapshot(1, date: date(2023, 1, 4), efficiency: 20, fuel: 30),
            snapshot(2, date: date(2023, 2, 6), fuel: 13),
            snapshot(3, date: date(2023, 3, 2), efficiency: 25, fuel: 10),
        ]
        let data = makeData(records, average: 19, units: .metric, format: .litersPer100Kilometers)
        let january = try XCTUnwrap(data.months.first?.summary.efficiency)
        XCTAssertEqual(january.average, 100 / 17.5, accuracy: 0.000_001)
        XCTAssertEqual(january.minimum, 5)
        XCTAssertEqual(january.maximum, 10)
        XCTAssertEqual(data.fillUps.map(\.efficiency), [10, 5, nil, 4])
        XCTAssertNil(data.months[1].summary.efficiency)
        XCTAssertEqual(data.months[2].efficiencySeriesStart, data.months[2].id)
        XCTAssertEqual(data.months[2].priceSeriesStart, data.months[0].id)
        XCTAssertEqual(data.period(for: .all)?.summary.efficiency?.average, 100 / 19)
        let otherFormat = makeData(records, units: .metric, format: .kilometersPerLiter)
        XCTAssertEqual(otherFormat.months.first?.summary.efficiency?.average, 17.5)
    }

    func testSameTimestampUsesOdometerThenUUIDOrdering() {
        let timestamp = date(2020, 2, 1)
        let data = makeData([
            snapshot(2, date: timestamp, odometer: 200, cost: 30),
            snapshot(1, date: timestamp, odometer: 200, cost: 20),
            snapshot(3, date: timestamp, odometer: 100, cost: 10),
        ])
        XCTAssertEqual(data.fillUps.map(\.cost), [10, 20, 30])
        XCTAssertEqual(data.months.first?.summary.cost?.count, 3)
        XCTAssertEqual(data.points(for: .cost, in: .year), [ChartPoint(date: timestamp, value: 10)])
    }

    func testCursorSelectsTheClosestVisiblePointForEachRange() {
        let records = [
            snapshot(0, date: date(2024, 1, 2), efficiency: 30, cost: 20),
            snapshot(1, date: date(2024, 1, 4), cost: 40),
            snapshot(2, date: date(2024, 3, 2), efficiency: 20, cost: 60),
        ]
        let data = makeData(records)
        let monthly = data.points(for: .cost, in: .all)
        XCTAssertEqual(monthly.map(\.value), [30, 60])
        XCTAssertEqual(monthly.nearest(to: date(2023, 12, 31)), monthly.first)
        XCTAssertEqual(monthly.nearest(to: date(2024, 3, 31)), monthly.last)
        XCTAssertEqual(monthly.first?.date, data.months.first?.midpoint)

        let recentCosts = data.points(for: .cost, in: .threeMonths)
        XCTAssertEqual(recentCosts.nearest(to: date(2024, 1, 3))?.value, 20)
        XCTAssertEqual(recentCosts.nearest(to: date(2024, 1, 4))?.value, 40)
        XCTAssertEqual(data.points(for: .efficiency, in: .threeMonths).map(\.value), [30, 20])
        XCTAssertNil([ChartPoint]().nearest(to: date(2024, 1, 4)))
    }
}
