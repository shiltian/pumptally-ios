import XCTest

@testable import PumpTally

/// Large single-vehicle histories. Fixture writes are outside the measured
/// interval; every cold iteration includes native fetch, indexing and charts.
@MainActor
final class VehicleHistoryPerformanceTests: XCTestCase {
    private func measureOpen(count: Int) throws {
        let fixture = try VehicleHistoryFixture(count: count)
        let options = XCTMeasureOptions()
        options.iterationCount = 4
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let completed = expectation(description: "Open history off MainActor")
            Task {
                do {
                    let repository = VehicleHistoryRepository(
                        container: fixture.container, vehicleID: fixture.vehicleID)
                    let data = try await repository.refresh(revision: 0, format: .defaultFormat)
                    let page = try await repository.page(
                        version: data.version,
                        query: .init(searchText: "", sortOrder: .dateDescending), offset: 0)
                    XCTAssertEqual(page?.records.count, 50)
                    XCTAssertEqual(page?.totalCount, count)
                    XCTAssertLessThanOrEqual(data.chartData.costData.count, 200)
                } catch { XCTFail("\(error)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 30)
        }
    }

    func testOpen800() throws { try measureOpen(count: 800) }
    func testOpen3200() throws { try measureOpen(count: 3200) }
    func testOpen12800() throws { try measureOpen(count: 12800) }

    func testSearchAndNextPage12800() throws {
        let fixture = try VehicleHistoryFixture(count: 12800)
        let repository = VehicleHistoryRepository(container: fixture.container, vehicleID: fixture.vehicleID)
        var version: UUID?
        let ready = expectation(description: "Warm the catalog")
        Task {
            do { version = try await repository.refresh(revision: 0, format: .defaultFormat).version } catch {
                XCTFail("\(error)")
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 30)
        let sourceVersion = try XCTUnwrap(version)
        let options = XCTMeasureOptions()
        options.iterationCount = 4
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let completed = expectation(description: "Search and page the existing index")
            Task {
                do {
                    for text in ["Record 1", "Record 12", "Record 128", "Record 1"] {
                        let query = VehicleHistoryRepository.Query(searchText: text, sortOrder: .costHighest)
                        let first = try await repository.page(version: sourceVersion, query: query, offset: 0)
                        let evaluations = await repository.queryEvaluations
                        let second = try await repository.page(version: sourceVersion, query: query, offset: 50)
                        let afterPaging = await repository.queryEvaluations
                        XCTAssertLessThanOrEqual(first!.records.count, 50)
                        XCTAssertLessThanOrEqual(second!.records.count, 50)
                        XCTAssertEqual(evaluations, afterPaging)
                    }
                    let reads = await repository.sourceLoads
                    let charts = await repository.chartPreparations
                    XCTAssertEqual(reads, 1)
                    XCTAssertEqual(charts, 1)
                } catch { XCTFail("\(error)") }
                completed.fulfill()
            }
            wait(for: [completed], timeout: 30)
        }
    }
}
