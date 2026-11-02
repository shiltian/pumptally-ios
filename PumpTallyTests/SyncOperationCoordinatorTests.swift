import XCTest
@testable import PumpTally

@MainActor
final class SyncOperationCoordinatorTests: XCTestCase {
    private enum ExpectedError: Error {
        case failure
    }

    func testExclusiveOperationsNeverOverlapAcrossSuspensionPoints() async {
        let coordinator = SyncOperationCoordinator()
        var activeCount = 0
        var maximumActiveCount = 0
        let firstStarted = expectation(description: "First operation holds the pipeline")
        let queued = expectation(description: "Other operations submitted")
        queued.expectedFulfillmentCount = 10
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await coordinator.runExclusive {
                activeCount += 1
                maximumActiveCount = activeCount
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstStarted.fulfill()
                }
                activeCount -= 1
            }
        }
        await fulfillment(of: [firstStarted], timeout: 5)

        let tasks = (0..<10).map { _ in
            Task { @MainActor in
                queued.fulfill()
                await coordinator.runExclusive {
                    activeCount += 1
                    maximumActiveCount = max(maximumActiveCount, activeCount)
                    await Task.yield()
                    activeCount -= 1
                }
            }
        }

        await fulfillment(of: [queued], timeout: 5)
        XCTAssertEqual(activeCount, 1)
        releaseFirst?.resume()
        await first.value
        for task in tasks {
            await task.value
        }

        XCTAssertEqual(maximumActiveCount, 1)
        XCTAssertEqual(activeCount, 0)
    }

    func testThrowingOperationReleasesPipelineForNextRequest() async {
        let coordinator = SyncOperationCoordinator()

        do {
            try await coordinator.runExclusive {
                throw ExpectedError.failure
            }
            XCTFail("Expected operation to throw")
        } catch ExpectedError.failure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let value = await coordinator.runExclusive { 42 }
        XCTAssertEqual(value, 42)
    }
}
