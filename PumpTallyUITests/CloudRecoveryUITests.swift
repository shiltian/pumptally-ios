import XCTest

final class CloudRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPreparedReplacementStaysPausedAcrossRelaunch() { assertStaysPaused(phase: "prepared") }
    func testPublishingReplacementStaysPausedAcrossRelaunch() { assertStaysPaused(phase: "publishing") }
    func testVerifiedReplacementStaysPausedAcrossRelaunch() { assertStaysPaused(phase: "verified") }

    func testInitialSyncOffersMergeAndCloudCopyWithoutCloudReplacement() {
        let app = launch()
        openSettings(app)
        let sync = app.switches["settings.sync"].switches.firstMatch
        sync.tap()
        app.alerts["Disable iCloud Sync?"].buttons["Keep Local Data"].tap()
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()
        let choice = app.alerts["iCloud Data Found"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertTrue(choice.buttons["Merge Both"].exists)
        XCTAssertTrue(choice.buttons["Use iCloud Data"].exists)
        XCTAssertFalse(choice.buttons["Use Local Data"].exists)
        capture("Initial sync choices", app: app)
        choice.buttons["Cancel"].tap()
    }

    func testSyncDetailsOfferCountsWithoutCloudReplacement() {
        let app = launch()
        openSettings(app)
        app.buttons["iCloud Sync Details"].tap()
        XCTAssertTrue(app.buttons["Refresh Counts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Replace iCloud Data"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Replacing iCloud data is unavailable while older app versions may still be using it."
            ].exists)
        capture("iCloud sync details", app: app)
        app.buttons["Refresh Counts"].tap()
        XCTAssertFalse(app.alerts["Replace iCloud Data?"].exists)
    }

    private func assertStaysPaused(phase: String, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = UUID().uuidString
        let common = ["--ui-testing-recovery-id=\(identifier)"]
        let app = launch(arguments: common + ["--ui-testing-recovery-phase=\(phase)"])
        for pass in 0..<2 {
            openSettings(app, file: file, line: line)
            XCTAssertTrue(app.staticTexts["sync.recovery.paused"].waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertFalse(app.buttons["Resume iCloud Replacement"].exists, file: file, line: line)
            XCTAssertFalse(app.staticTexts["Synced"].exists, file: file, line: line)
            XCTAssertFalse(app.switches["settings.sync"].isEnabled, file: file, line: line)
            if pass == 0 { capture("Paused \(phase) replacement", app: app) }
            app.buttons["Done"].tap()
            app.staticTexts["Recovery UI Fixture"].tap()
            app.tabBars.buttons["History"].tap()
            XCTAssertTrue(app.staticTexts["800 records"].waitForExistence(timeout: 10), file: file, line: line)
            XCTAssertTrue(app.staticTexts["Trusted recovery record 799"].exists, file: file, line: line)
            app.terminate()
            if pass == 0 {
                app.launchArguments =
                    ["--ui-testing", "-com.apple.CoreData.ConcurrencyDebug", "1"]
                    + common + ["--ui-testing-recovery-phase=resume"]
                app.launch()
            }
        }
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-com.apple.CoreData.ConcurrencyDebug", "1"] + arguments
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["My Vehicles"]
        XCTAssertTrue(back.waitForExistence(timeout: 30), file: file, line: line)
        back.tap()
        app.buttons["app.settings"].tap()
    }
}
