import XCTest

/// Driven by scripts/test_in_place_upgrades.py. These cases operate on a
/// separately installed full app, never the ordinary Testing app's fixtures.
final class InPlaceUpgradeUITests: XCTestCase {
    private let bundleID = "me.tianshilei.fuelio.upgrade"
    private let names = ["Upgrade Imperial", "Upgrade Metric"]

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if (testRun?.failureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    func testPopulateHistoricalInstallation() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Add Your First Vehicle"].waitForExistence(timeout: 15))
        for (index, vehicleName) in names.enumerated() {
            if index == 0 {
                app.buttons["Add Your First Vehicle"].tap()
            } else {
                app.navigationBars.buttons["My Vehicles"].tap()
                app.navigationBars["My Vehicles"].buttons.element(boundBy: 1).tap()
            }
            let nameField = app.textFields["Vehicle Name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.tap()
            nameField.typeText(vehicleName)
            app.textFields["Make (e.g., Toyota)"].tap()
            app.textFields["Make (e.g., Toyota)"].typeText("Upgrade")
            app.textFields["Model (e.g., Camry)"].tap()
            app.textFields["Model (e.g., Camry)"].typeText(index == 0 ? "Imperial" : "Metric")
            if index == 1 {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Unit System")).firstMatch.tap()
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Metric")).firstMatch.tap()
                if app.buttons["km/L"].exists { app.buttons["km/L"].tap() }
            }
            app.buttons["Save"].tap()
            if index == 1 {
                XCTAssertTrue(app.staticTexts[vehicleName].waitForExistence(timeout: 5))
                app.staticTexts[vehicleName].tap()
            }
            XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))
            try importHistory(in: app, vehicleIndex: index)
            if index == 0 { try addHistoricalRecord(in: app) }
        }
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE Metric record 399"].waitForExistence(timeout: 10))
        // Exercise the actual old app's persisted last-viewed preference and
        // a clean background transition before taking the on-disk baseline.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.navigationBars[names[1]].waitForExistence(timeout: 10))
    }

    private func importHistory(in app: XCUIApplication, vehicleIndex: Int) throws {
        let label = vehicleIndex == 0 ? "Imperial" : "Metric"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Upgrade-\(label).csv")
        let formatter = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_577_836_800)
        var rows = ["date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes"]
        for index in 0..<400 {
            let date = formatter.string(from: base.addingTimeInterval(Double(index) * 5 * 86_400))
            let distance = vehicleIndex == 0 ? 10_000.123456789 : 50_000.987654321
            let odometer = distance + Double(index) * 400.125
            let price = 3.459876543 + Double(index % 7) / 1000
            let fuel = 10.123456789 + Double(index % 9) / 100
            let cost = price * fuel
            let fill = index.isMultiple(of: 29) ? "reset" : (index.isMultiple(of: 13) ? "partial" : "full")
            let note =
                index == 399
                ? "UPGRADE \(label) record 399"
                : (index.isMultiple(of: 17) ? "" : "\(label) café 加油 \(index)")
            rows.append("\(date),\(odometer),\(price),\(fuel),\(cost),\(fill),\"\(note)\"")
        }
        try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        app.open(url)
        let importing = app.navigationBars["Import CSV"]
        XCTAssertTrue(importing.waitForExistence(timeout: 10))
        let importButton = importing.buttons["Import"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: importButton)
        wait(for: [ready], timeout: 15)
        importButton.tap()
        let success = app.alerts["Import Successful"]
        XCTAssertTrue(success.waitForExistence(timeout: 60))
        success.buttons["OK"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE \(label) record 399"].waitForExistence(timeout: 10))
    }

    private func addHistoricalRecord(in app: XCUIApplication) throws {
        app.navigationBars[names[0]].buttons.matching(
            NSPredicate(format: "label IN %@", ["Add", "plus.circle.fill"])
        ).firstMatch.tap()
        let fields = app.textFields
        XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 5))
        fields.element(boundBy: 0).tap()
        fields.element(boundBy: 0).typeText("300000.123456789")
        fields.element(boundBy: 1).tap()
        fields.element(boundBy: 1).typeText("3500")
        fields.element(boundBy: 2).tap()
        fields.element(boundBy: 2).typeText("10000")
        if fields.element(boundBy: 3).value as? String == "0.00" {
            fields.element(boundBy: 3).tap()
            fields.element(boundBy: 3).typeText("3500")
        }
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Fill-up Recorded!"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 5))
    }

    func testReadRestoredHistoricalInstallation() {
        let app = launch()
        XCTAssertTrue(app.navigationBars[names[1]].waitForExistence(timeout: 30))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE Metric record 399"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["My Vehicles"].tap()
        XCTAssertTrue(app.staticTexts[names[0]].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[names[1]].exists)
        app.staticTexts[names[1]].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE Metric record 399"].waitForExistence(timeout: 5))
    }

    func testOpenUpgradedInstallation() {
        let app = launch()
        XCTAssertTrue(app.navigationBars[names[1]].waitForExistence(timeout: 30))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE Metric record 399"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["My Vehicles"].tap()
        XCTAssertTrue(app.staticTexts[names[0]].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[names[1]].exists)
        app.staticTexts[names[1]].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["UPGRADE Metric record 399"].waitForExistence(timeout: 5))
    }

    func testEditUpgradedInstallation() throws {
        let app = launch()
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 30))
        history.tap()
        let original = app.staticTexts["UPGRADE Metric record 399"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        let notes = app.descendants(matching: .any).matching(identifier: "fueling.notes").firstMatch
        if !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText(" [upgrade reviewed]")
        let expected = try XCTUnwrap(notes.value as? String)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 10))
    }

    func testAddRecordAfterUpgrade() {
        let app = launch()
        XCTAssertTrue(app.buttons["fueling.add"].waitForExistence(timeout: 30))
        app.buttons["fueling.add"].tap()
        let odometer = app.textFields["fueling.odometer"]
        XCTAssertTrue(odometer.waitForExistence(timeout: 5))
        odometer.tap()
        odometer.typeText("500000.987654321")
        app.textFields["fueling.price"].tap()
        app.textFields["fueling.price"].typeText("3500")
        app.textFields["fueling.fuel"].tap()
        app.textFields["fueling.fuel"].typeText("10000")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Fill-up Recorded!"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 5))
    }

    func testReopenSavedUpgrade() {
        let app = launch()
        XCTAssertTrue(app.navigationBars[names[1]].waitForExistence(timeout: 30))
        app.tabBars.buttons["History"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "401 records")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let reviewed = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", "UPGRADE Metric record 399", "[upgrade reviewed]")
        ).firstMatch
        XCTAssertTrue(reviewed.waitForExistence(timeout: 5))
    }
}
