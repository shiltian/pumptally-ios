import XCTest

final class CloudRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testResumeAfterProcessTerminationAtPreparedReceipt() { assertResumes(after: "prepared") }
    func testResumeAfterProcessTerminationAtPublishingReceipt() { assertResumes(after: "publishing") }
    func testResumeAfterProcessTerminationAfterBusinessAcknowledgement() {
        assertResumes(after: "businessAcknowledged")
    }
    func testResumeAfterProcessTerminationAtVerifiedReceipt() { assertResumes(after: "verified") }
    func testResumeAfterProcessTerminationAfterCommittedActivation() { assertResumes(after: "completed") }

    private func assertResumes(after cutpoint: String, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = UUID().uuidString
        let app = XCUIApplication()
        let common = [
            "--ui-testing", "--ui-testing-recovery-id=\(identifier)",
            "--ui-testing-recovery-expected=\(cutpoint)", "-com.apple.CoreData.ConcurrencyDebug", "1",
        ]
        app.launchArguments = common + ["--ui-testing-recovery-phase=\(cutpoint)"]
        app.launch()
        openSettings(app, file: file, line: line)
        let sync = app.switches["settings.sync"].switches.firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 10), file: file, line: line)
        sync.tap()
        let local = app.alerts["iCloud Data Found"].buttons["Use Local Data"]
        XCTAssertTrue(local.waitForExistence(timeout: 10), file: file, line: line)
        local.tap()
        let checkpoint = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Recovery test checkpoint: \(cutpoint)")
        ).firstMatch
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 30), file: file, line: line)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, file: file, line: line)
        app.launchArguments = common + ["--ui-testing-recovery-phase=resume"]
        app.launch()
        openSettings(app, file: file, line: line)
        XCTAssertTrue(app.staticTexts["Synced"].waitForExistence(timeout: 30), file: file, line: line)
        XCTAssertFalse(app.buttons["sync.recovery.resume"].exists, file: file, line: line)
        XCTAssertEqual(app.switches["settings.sync"].switches.firstMatch.value as? String, "1", file: file, line: line)
        app.buttons["Done"].tap()
        app.staticTexts["Recovery UI Fixture"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["800 records"].waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["Trusted recovery record 799"].waitForExistence(timeout: 10), file: file, line: line)
        app.terminate()
    }

    private func openSettings(_ app: XCUIApplication, file: StaticString, line: UInt) {
        let back = app.navigationBars.buttons["My Vehicles"]
        XCTAssertTrue(back.waitForExistence(timeout: 30), file: file, line: line)
        back.tap()
        app.buttons["app.settings"].tap()
    }
}
