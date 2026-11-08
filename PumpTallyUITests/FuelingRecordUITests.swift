import XCTest

final class FuelingRecordUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-com.apple.CoreData.ConcurrencyDebug", "1"] + arguments
        app.launch()
        return app
    }

    func testAddOdometerKeyboardDoneIsTrailingAndDismissesTheKeyboard() {
        assertOdometerKeyboardDone(editing: false)
    }

    func testEditOdometerKeyboardDoneIsTrailingAndDismissesTheKeyboard() {
        assertOdometerKeyboardDone(editing: true)
    }

    private func assertOdometerKeyboardDone(editing: Bool) {
        let app = launch()
        if editing {
            let history = app.tabBars.buttons["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 10))
            history.tap()
            let record = app.staticTexts["Original UI note"]
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            record.tap()
        } else {
            let add = app.buttons["fueling.add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
        }
        let odometer = app.textFields["fueling.odometer"]
        XCTAssertTrue(odometer.waitForExistence(timeout: 5))
        odometer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = editing ? "Edit odometer keyboard accessory" : "Add odometer keyboard accessory"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertGreaterThan(done.frame.midX, app.frame.minX + app.frame.width * 0.75)
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        wait(for: [dismissed], timeout: 5)
        app.buttons["Cancel"].tap()
    }

    func testNumericKeyboardDoneDismissesTheKeyboard() {
        let app = launch()
        let add = app.buttons["fueling.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = app.textFields["fueling.price"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("2470")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        wait(for: [dismissed], timeout: 5)
        XCTAssertEqual(field.value as? String, "2.470")
    }

    func testRecordFieldsUseConsistentNativeKeyboardDone() {
        let app = launch()
        let addRecord = app.buttons["fueling.add"]
        XCTAssertTrue(addRecord.waitForExistence(timeout: 10))
        addRecord.tap()
        for identifier in ["fueling.odometer", "fueling.price", "fueling.fuel", "fueling.cost"] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(done.frame.midX, app.frame.minX + app.frame.width * 0.75)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(identifier) native keyboard Done"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            done.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: keyboard)
            wait(for: [dismissed], timeout: 5)
        }
        app.buttons["Cancel"].tap()
    }

    func testFuelDetailsSwitchDirectlyWithoutDismissingTheKeyboard() {
        let app = launch()
        let addRecord = app.buttons["fueling.add"]
        XCTAssertTrue(addRecord.waitForExistence(timeout: 10))
        addRecord.tap()
        for identifier in ["fueling.price", "fueling.fuel", "fueling.cost"] {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, "")
            let done = app.buttons.matching(identifier: "Done")
            XCTAssertEqual(done.count, 1)
            XCTAssertTrue(done.firstMatch.isHittable)
        }
        app.buttons["Done"].tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        wait(for: [dismissed], timeout: 5)
        XCTAssertEqual(app.textFields["fueling.price"].value as? String, "0.000")
        XCTAssertEqual(app.textFields["fueling.fuel"].value as? String, "0.000")
        XCTAssertEqual(app.textFields["fueling.cost"].value as? String, "0.00")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        app.buttons["Cancel"].tap()
    }

    func testDecimalCommaEntrySavesThroughTheForm() {
        let app = launch(arguments: ["-AppleLanguages", "(en)", "-AppleLocale", "es_ES"])
        let add = app.buttons["fueling.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let odometer = app.textFields["fueling.odometer"]
        XCTAssertTrue(odometer.waitForExistence(timeout: 5))
        odometer.tap()
        odometer.typeText("1600,5")
        let price = app.textFields["fueling.price"]
        price.tap()
        price.typeText("3,5")
        let fuel = app.textFields["fueling.fuel"]
        fuel.tap()
        fuel.typeText("10000")
        app.buttons["Done"].tap()
        XCTAssertEqual(price.value as? String, "3,500")
        XCTAssertEqual(fuel.value as? String, "10,000")
        XCTAssertEqual(app.textFields["fueling.cost"].value as? String, "35,00")
        app.swipeUp()
        let notes = app.descendants(matching: .any).matching(identifier: "fueling.notes").firstMatch
        notes.tap()
        notes.typeText("Localized numeric entry")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Localized numeric entry"].waitForExistence(timeout: 5))
    }

    func testSelectAllDeleteFromTheNativeEditMenu() {
        let app = launch()
        let add = app.buttons["fueling.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let price = app.textFields["fueling.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        price.tap()
        price.typeText("12345")
        XCTAssertEqual(price.value as? String, "12.345")
        let text = price.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let selectAll = app.menuItems["Select All"]
        text.tap()
        if !selectAll.waitForExistence(timeout: 1) { text.tap() }
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        price.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(price.value as? String, "")
        price.typeText("2.47")
        app.buttons["Done"].tap()
        XCTAssertEqual(price.value as? String, "2.470")
    }

    func testSpanishRecoveryReviewIsLocalized() {
        assertLocalizedRecoveryReview(
            language: "es", locale: "es_ES",
            reviewTitle: "Revisar eliminaciones anteriores", countText: "1 solicitud de eliminación",
            keepTitle: "Conservar copias de iCloud", finishedText: "No hay eliminaciones anteriores que revisar.")
    }

    func testSimplifiedChineseRecoveryReviewIsLocalized() {
        assertLocalizedRecoveryReview(
            language: "zh-Hans", locale: "zh_CN",
            reviewTitle: "检查之前的删除请求", countText: "1 条删除请求",
            keepTitle: "保留 iCloud 副本", finishedText: "没有需要检查的历史删除请求。")
    }

    private func assertLocalizedRecoveryReview(
        language: String, locale: String, reviewTitle: String,
        countText: String, keepTitle: String, finishedText: String
    ) {
        let app = launch(arguments: [
            "--ui-testing-legacy-deletion",
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
        ])
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        app.buttons["app.settings"].tap()
        let review = app.buttons["sync.recovery.deletions"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertEqual(review.label, reviewTitle)
        review.tap()
        let explanation = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", countText)).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        app.buttons[reviewTitle].tap()
        let keep = app.buttons[keepTitle]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertTrue(app.staticTexts[finishedText].waitForExistence(timeout: 5))
    }

    func testZeroFuelRecordAllowsNotesEditThroughTheForm() throws {
        let app = launch(arguments: ["--ui-testing-zero-fuel"])
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let original = app.staticTexts["Original UI note"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        let notes = app.descendants(matching: .any).matching(identifier: "fueling.notes").firstMatch
        if !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText(" updated")
        let expected = try XCTUnwrap(notes.value as? String)
        XCTAssertNotEqual(expected, "Original UI note")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
    }

    func testFirstBaselineAllowsEfficiencyPreview() { assertEfficiencyPreview(afterPartial: false) }
    func testNonFirstPartialPredecessorSuppressesEfficiencyPreview() { assertEfficiencyPreview(afterPartial: true) }

    private func assertEfficiencyPreview(afterPartial: Bool) {
        let app = launch(
            arguments: afterPartial
                ? ["--ui-testing-two-records", "--ui-testing-partial-predecessor"] : [])
        let add = app.buttons["fueling.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let odometer = app.textFields["fueling.odometer"]
        XCTAssertTrue(odometer.waitForExistence(timeout: 5))
        odometer.tap()
        odometer.typeText("1600")
        let price = app.textFields["fueling.price"]
        price.tap()
        price.typeText("3500")
        let fuel = app.textFields["fueling.fuel"]
        fuel.tap()
        fuel.typeText("10000")
        let preview = app.staticTexts["Preview"]
        if !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["Estimated MPG"].exists, !afterPartial)
        app.buttons["Cancel"].tap()
    }

    func testFailedStartupKeepsEditingUnavailableAndRetryReportsFailure() {
        let app = launch(arguments: ["--ui-testing-read-only-store", "--ui-testing-uncached-store"])
        let failure = app.staticTexts["Unable to Prepare Your Data"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fueling.add"].exists)
        XCTAssertFalse(app.tabBars.buttons["History"].exists)
        let retry = app.buttons["startup.retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fueling.add"].exists)
        XCTAssertFalse(app.buttons["app.settings"].exists)
    }

    func testStoreOpenFailureKeepsEditingUnavailableAcrossRetries() {
        let app = launch(arguments: ["--ui-testing-store-open-failure"])
        let failure = app.staticTexts["Your saved data could not be opened. Please try again."]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fueling.add"].exists)
        XCTAssertFalse(app.buttons["app.settings"].exists)
        XCTAssertFalse(app.tabBars.buttons["History"].exists)
        app.buttons["startup.retry"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["fueling.add"].exists)
        XCTAssertFalse(app.buttons["app.settings"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native store-open failure and retry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testStoreOpenRetryReachesSavedHistory() {
        let app = launch(arguments: ["--ui-testing-store-open-failure", "--ui-testing-store-open-retry"])
        XCTAssertTrue(app.buttons["startup.retry"].waitForExistence(timeout: 10))
        app.buttons["startup.retry"].tap()
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.staticTexts["Original UI note"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startup.retry"].exists)
    }

    func testCSVOpenedDuringStoreFailureIsPresentedAfterRetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Deferred-\(UUID()).csv")
        try "date,odometer,pricePerFuelUnit,fuelAmount,totalCost\n2024-01-15,1300,3.5,10,35\n".write(
            to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = launch(arguments: ["--ui-testing-store-open-failure", "--ui-testing-store-open-retry"])
        XCTAssertTrue(app.buttons["startup.retry"].waitForExistence(timeout: 10))
        app.open(url)
        XCTAssertFalse(app.buttons["csv.import"].exists)
        app.buttons["startup.retry"].tap()
        XCTAssertTrue(app.buttons["csv.import"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["fueling.add"].waitForExistence(timeout: 5))
    }

    func testColdCacheStartupOpensTheSavedHistory() {
        let app = launch(arguments: ["--ui-testing-uncached-store"])
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.staticTexts["Original UI note"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startup.retry"].exists)
    }

    func testCSVOpenedFromFileImportsThroughTheOwnedWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Import-\(UUID()).csv")
        let csv = """
            date,odometer,pricePerFuelUnit,fuelAmount,totalCost,fillUpType,notes
            2024-01-15,1300,3.50,10,35,full,Imported CSV note
            """
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = launch()
        app.open(url)
        let importButton = app.buttons["csv.import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        XCTAssertFalse(importButton.isEnabled)
        app.buttons["csv.units"].tap()
        app.buttons["Miles and US Gallons"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: importButton)
        wait(for: [ready], timeout: 10)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CSV import review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        importButton.tap()
        let success = app.alerts["Import Successful"]
        XCTAssertTrue(success.waitForExistence(timeout: 10))
        success.buttons["OK"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Imported CSV note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original UI note"].exists)
    }

    func testMatchingCSVRequiresAnExplicitDuplicateDecision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Repeat-\(UUID()).csv")
        try
            "date,odometer,price,fuel,cost,fillUpType,notes\n2023-11-14T22:13:20Z,1000.123456789,3.459876543,10.123456789,35.123456789,full,Original UI note"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = launch()
        app.open(url)
        let button = app.buttons["csv.import"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        app.buttons["csv.units"].tap()
        app.buttons["Miles and US Gallons"].tap()
        let duplicates = app.buttons["csv.duplicates"]
        XCTAssertTrue(duplicates.waitForExistence(timeout: 10))
        XCTAssertFalse(button.isEnabled)
        if !duplicates.isHittable { app.scrollViews.firstMatch.swipeUp() }
        duplicates.tap()
        app.buttons["Skip Possible Duplicates"].tap()
        let reviewed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        wait(for: [reviewed], timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CSV duplicate review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        button.tap()
        let success = app.alerts["Import Successful"]
        XCTAssertTrue(success.waitForExistence(timeout: 10))
        XCTAssertTrue(success.staticTexts["0 record(s) imported successfully"].exists)
        success.buttons["OK"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "Original UI note").count, 1)
        XCTAssertTrue(app.staticTexts["Original UI note"].exists)
    }

    func testCancelCSVReviewLeavesHistoryUnchanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Cancel-\(UUID()).csv")
        try "date,odometer,price,fuel,cost\n2024-01-15,1300,3.5,10,35".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = launch()
        app.open(url)
        XCTAssertTrue(app.buttons["csv.import"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["csv.import"].isEnabled)
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Original UI note"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Import Successful"].exists)
    }

    func testPriceAndFuelCalculateTotalAndSave() throws {
        let app = launch()
        let add = app.buttons["fueling.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let odometer = app.textFields["fueling.odometer"]
        XCTAssertTrue(odometer.waitForExistence(timeout: 5))
        odometer.tap()
        odometer.typeText("1300")
        let price = app.textFields["fueling.price"]
        price.tap()
        price.typeText("3500")
        let fuel = app.textFields["fueling.fuel"]
        fuel.tap()
        fuel.typeText("10000")
        XCTAssertEqual(app.textFields["fueling.cost"].value as? String, "35.00")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Fill-up Recorded!"].waitForExistence(timeout: 5))
    }

    func testNotesOnlyEditThroughHistory() throws {
        let app = launch()
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let original = app.staticTexts["Original UI note"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        let notes = app.descendants(matching: .any).matching(identifier: "fueling.notes").firstMatch
        if !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText(" reviewed")
        let expected = try XCTUnwrap(notes.value as? String)
        XCTAssertNotEqual(expected, "Original UI note")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
    }

    func testFailedNotesSaveKeepsDraftAndCancelShowsOriginalSavedValues() throws {
        let app = launch(arguments: ["--ui-testing-read-only-store"])
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let original = app.staticTexts["Original UI note"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        let notes = app.descendants(matching: .any).matching(identifier: "fueling.notes").firstMatch
        if !notes.isHittable { app.swipeUp() }
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText(" unsaved draft")
        let draft = try XCTUnwrap(notes.value as? String)
        app.buttons["Save"].tap()
        let alert = app.alerts["Unable to Save"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        XCTAssertEqual(notes.value as? String, draft)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[draft].exists)
    }

    func testDeletingOneOfTwoRecordsKeepsTheRemainingHistoryVisible() {
        let app = launch(arguments: ["--ui-testing-two-records"])
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let removed = app.staticTexts["Second UI note"]
        XCTAssertTrue(removed.waitForExistence(timeout: 5))
        removed.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts["Delete Record"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        let disappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: removed)
        wait(for: [disappeared], timeout: 5)
        XCTAssertTrue(app.staticTexts["Original UI note"].exists)
    }

    func testNavigationAfterRemovingLocalCopyAndAddingFirstVehicle() {
        let app = launch()
        let back = app.navigationBars.buttons["My Vehicles"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        app.buttons["app.settings"].tap()
        let sync = app.switches["settings.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.switches.firstMatch.tap()
        let remove = app.alerts.buttons["Remove Local Data"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(app.staticTexts["Welcome to PumpTally"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add Your First Vehicle"].exists)

        app.buttons["Add Your First Vehicle"].tap()
        let name = app.textFields["Vehicle Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Replacement UI Vehicle")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Replacement UI Vehicle"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["My Vehicles"].tap()
        XCTAssertTrue(app.navigationBars["My Vehicles"].waitForExistence(timeout: 5))

        // Returning from a sheet must not restore the vehicle a second time.
        app.buttons["app.settings"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["My Vehicles"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Replacement UI Vehicle"].exists)
    }

    func testLegacyMeasurementsCanBeReviewedWithExplicitUnits() {
        let app = launch(arguments: ["--ui-testing-legacy-record"])
        let back = app.navigationBars.buttons["My Vehicles"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        app.buttons["app.settings"].tap()
        app.buttons["sync.recovery.units"].tap()
        let units = app.buttons["sync.review.units"]
        XCTAssertTrue(units.waitForExistence(timeout: 5))
        units.tap()
        app.buttons["Imperial"].tap()
        app.buttons["sync.review.confirm"].tap()
        let apply = app.alerts.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()
        XCTAssertTrue(app.staticTexts["No measurements need confirmation."].waitForExistence(timeout: 5))
        let settings = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync.recovery.units"].exists)
        XCTAssertFalse(app.buttons["sync.recovery.diagnostics"].exists)
    }

    func testHealthySettingsDoNotOfferSyncRecoveryActions() {
        let app = launch()
        openSettings(in: app)
        XCTAssertTrue(app.switches["settings.sync"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Review Sync Changes"].exists)
        XCTAssertFalse(app.buttons["sync.recovery.units"].exists)
        XCTAssertFalse(app.buttons["sync.recovery.deletions"].exists)
        XCTAssertFalse(app.buttons["sync.recovery.diagnostics"].exists)
    }

    func testMalformedIncomingRecordOffersDiagnosticsWithoutUnitControls() {
        let app = launch(arguments: ["--ui-testing-malformed-record"])
        openSettings(in: app)
        let diagnostics = app.buttons["sync.recovery.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync.recovery.units"].exists)
        diagnostics.tap()
        XCTAssertTrue(
            app.staticTexts["This iCloud record has missing or invalid fields. Choosing units cannot repair it."]
                .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync.review.units"].exists)
        XCTAssertFalse(app.buttons["sync.review.confirm"].exists)
    }

    func testPreviousDeletionActionDisappearsAfterKeepingCloudCopies() {
        let app = launch(arguments: ["--ui-testing-legacy-deletion"])
        openSettings(in: app)
        let deletions = app.buttons["sync.recovery.deletions"]
        XCTAssertTrue(deletions.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync.recovery.units"].exists)
        deletions.tap()
        app.buttons["Review Previous Deletions"].tap()
        app.buttons["Keep iCloud Copies"].tap()
        XCTAssertTrue(app.staticTexts["No previous deletions need review."].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["sync.recovery.deletions"].exists)
    }

    func testCancelInitialSourceChoiceThenMergeKeepsTheVehicleAndRecords() {
        let app = launch()
        openSettings(in: app)
        let sync = app.switches["settings.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.switches.firstMatch.tap()
        let disableAlert = app.alerts["Disable iCloud Sync?"]
        let keep = disableAlert.buttons["Keep Local Data"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        let disableScreenshot = XCTAttachment(screenshot: disableAlert.screenshot())
        disableScreenshot.name = "Standard sync confirmation"
        disableScreenshot.lifetime = .keepAlways
        add(disableScreenshot)
        keep.tap()
        XCTAssertTrue(app.staticTexts["Not Syncing"].waitForExistence(timeout: 5))
        XCTAssertEqual(sync.switches.firstMatch.value as? String, "0")

        sync.switches.firstMatch.tap()
        let sourceAlert = app.alerts["iCloud Data Found"]
        XCTAssertTrue(sourceAlert.waitForExistence(timeout: 5))
        let sourceScreenshot = XCTAttachment(screenshot: sourceAlert.screenshot())
        sourceScreenshot.name = "iCloud data source confirmation"
        sourceScreenshot.lifetime = .keepAlways
        add(sourceScreenshot)
        sourceAlert.buttons["Cancel"].tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: sourceAlert)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(sync.switches.firstMatch.value as? String, "0")
        sync.switches.firstMatch.tap()
        let merge = sourceAlert.buttons["Merge Both"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()
        XCTAssertTrue(app.staticTexts["Synced"].waitForExistence(timeout: 10))
        XCTAssertEqual(sync.switches.firstMatch.value as? String, "1")
        app.buttons["Done"].tap()
        app.staticTexts["UI Test Vehicle"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Original UI note"].waitForExistence(timeout: 5))
    }

    func testInitialEnableWithEmptyCloudUploadsWithoutASourceDialog() {
        let app = launch(arguments: ["--ui-testing-initial-sync", "--ui-testing-empty-cloud"])
        openSettings(in: app)
        let sync = app.switches["settings.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        XCTAssertEqual(sync.switches.firstMatch.value as? String, "0")
        sync.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synced"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Merge Both"].exists)
        XCTAssertEqual(sync.switches.firstMatch.value as? String, "1")
        app.buttons["Done"].tap()
        app.staticTexts["UI Test Vehicle"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Original UI note"].waitForExistence(timeout: 5))
    }

    private func openSettings(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["My Vehicles"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        app.buttons["app.settings"].tap()
    }
}
