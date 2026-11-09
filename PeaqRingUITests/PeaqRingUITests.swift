import XCTest

final class PeaqRingUITests: XCTestCase {
    @MainActor
    func testHistoryCalendarOpensWithoutExtraDaySelector() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let date = app.buttons["history-date-picker"]
        XCTAssertTrue(date.waitForExistence(timeout: 10))
        let initialDate = String(describing: date.value)
        XCTAssertLessThan(date.frame.midX, app.frame.midX)
        date.tap()
        XCTAssertTrue(app.navigationBars["Choose a day"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["history-date-input"].exists)
        XCTAssertFalse(app.buttons["history-previous-day"].exists)
        XCTAssertFalse(app.buttons["history-next-day"].exists)
        XCTAssertFalse(app.buttons["history-today"].exists)
        let month = String(describing: app.buttons["DatePicker.Show"].value)
        app.buttons["DatePicker.PreviousMonth"].tap()
        XCTAssertNotEqual(String(describing: app.buttons["DatePicker.Show"].value), month)
        app.buttons["DatePicker.NextMonth"].tap()
        XCTAssertEqual(String(describing: app.buttons["DatePicker.Show"].value), month)
        let calendar = XCTAttachment(screenshot: app.screenshot())
        calendar.name = "Calendar only"; calendar.lifetime = .keepAlways; add(calendar)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Calendar accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(String(describing: date.value), initialDate)
        date.tap()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayLabel = yesterday.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(Locale(identifier: "en_US")))
        if !Calendar.current.isDate(yesterday, equalTo: Date(), toGranularity: .month) {
            app.buttons["DatePicker.PreviousMonth"].tap()
        }
        app.descendants(matching: .any)["history-date-input"].descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", yesterdayLabel)).firstMatch.tap()
        app.buttons["Show day"].tap()
        XCTAssertNotEqual(String(describing: date.value), initialDate)
        date.tap()
        if !Calendar.current.isDate(yesterday, equalTo: Date(), toGranularity: .month) {
            app.buttons["DatePicker.NextMonth"].tap()
        }
        let todayLabel = Date().formatted(.dateTime.weekday(.wide).month(.wide).day().locale(Locale(identifier: "en_US")))
        app.descendants(matching: .any)["history-date-input"].descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", todayLabel)).firstMatch.tap()
        app.buttons["Show day"].tap()
        XCTAssertEqual(String(describing: date.value), initialDate)
    }
    @MainActor
    func testLiveAppIgnoresOldDemoPreferenceAndHasSimpleSyncSettings() throws {
        let app = XCUIApplication()
        // Existing prototype users may have left demo mode on. The live app must
        // still show real data only, regardless of the old preference.
        app.launchArguments = ["-demoMode", "YES", "-experimentalSync", "NO", "-autoSync", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your daily rhythm"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Demo preview · all readings are examples"].exists)
        XCTAssertFalse(app.staticTexts["Demo ring"].exists)
        XCTAssertTrue(app.staticTexts["Awaiting first reading"].firstMatch.exists)
        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(app.staticTexts["Sleep"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your next night starts here"].exists)
        XCTAssertTrue(app.staticTexts["PAI Vitality Index"].exists)
        XCTAssertTrue(app.staticTexts["Awaiting first PAI score"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["No exercise records received"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Daily activity goals"].exists)
        app.buttons.containing(.staticText, identifier: "Automatic sync").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Automatic sync"].waitForExistence(timeout: 5))
        let syncChoice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Every 15 minutes")).firstMatch
        XCTAssertTrue(syncChoice.waitForExistence(timeout: 5))
        let syncSettings = XCTAttachment(screenshot: app.screenshot())
        syncSettings.name = "Automatic sync settings"; syncSettings.lifetime = .keepAlways; add(syncSettings)
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Reference profile"].tap()
        XCTAssertTrue(app.buttons["reference-age"].exists)
        XCTAssertTrue(app.buttons["reference-sex"].exists)
        XCTAssertFalse(app.switches["Preview with demo data"].exists)
        XCTAssertFalse(app.switches["Experimental history sync"].exists)
        XCTAssertFalse(app.secureTextFields["Session token"].exists)
        XCTAssertFalse(app.switches["Sync automatically"].exists)
        app.tabBars.buttons["My ring"].tap()
        XCTAssertTrue(app.buttons["Find my ring"].waitForExistence(timeout: 5))
    }
}

extension PeaqRingUITests {
    @MainActor
    func testReferenceProfileCanBeConfiguredAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Reference profile"].tap()
        app.buttons["reference-age"].tap()
        let birthYear = String(Calendar.current.component(.year, from: Date()) - 35)
        let input = app.textFields["birth-year-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        if let value = input.value as? String, Int(value) != nil {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        input.typeText(birthYear)
        app.buttons["Save"].tap()
        app.buttons["reference-sex"].tap()
        app.buttons["Female"].tap()
        if !app.buttons["reference-age"].exists { app.navigationBars.buttons["Reference profile"].tap() }
        XCTAssertTrue((app.buttons["reference-age"].label + String(describing: app.buttons["reference-age"].value)).contains(birthYear))
        XCTAssertTrue((app.buttons["reference-sex"].label + String(describing: app.buttons["reference-sex"].value)).contains("Female"))
        app.terminate()
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Reference profile"].tap()
        XCTAssertTrue((app.buttons["reference-age"].label + String(describing: app.buttons["reference-age"].value)).contains(birthYear))
        XCTAssertTrue((app.buttons["reference-sex"].label + String(describing: app.buttons["reference-sex"].value)).contains("Female"))
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Reference profile settings"; settings.lifetime = .keepAlways; add(settings)
        app.tabBars.buttons["Today"].tap()
        for _ in 0..<2 {
            app.buttons["Heart rate reference ranges"].tap()
            XCTAssertTrue(app.staticTexts["Reading context, At rest"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Typical range, 60–100 bpm"].exists)
            XCTAssertFalse(app.staticTexts["Excellent"].exists)
            XCTAssertFalse(app.buttons["Choose context"].exists)
            let heartGuide = XCTAttachment(screenshot: app.screenshot())
            heartGuide.name = "Adult resting heart-rate guide"; heartGuide.lifetime = .keepAlways; add(heartGuide)
            app.buttons["Done"].tap()
        }
        for _ in 0..<3 {
            if app.buttons["HRV reference ranges"].isHittable { break }
            if app.buttons["HRV reference ranges"].frame.minY < 0 { app.swipeDown() }
            else { app.swipeUp() }
        }
        app.buttons["HRV reference ranges"].tap()
        XCTAssertTrue(app.navigationBars["HRV"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Building baseline: 0/7 prior recorded days within 28 days."].exists)
        XCTAssertFalse(app.staticTexts["30–39 years"].exists)
        let guide = XCTAttachment(screenshot: app.screenshot())
        guide.name = "HRV reference guide"; guide.lifetime = .keepAlways; add(guide)
        app.buttons["Done"].tap()
        app.buttons["Respiration reference ranges"].tap()
        XCTAssertTrue(app.staticTexts["Typical range, 12–20 breaths/min"].waitForExistence(timeout: 5))
        let breathing = XCTAttachment(screenshot: app.screenshot())
        breathing.name = "Adult breathing guide"; breathing.lifetime = .keepAlways; add(breathing)
        app.buttons["Done"].tap()
        app.tabBars.buttons["Insights"].tap()
        app.buttons["About sleep duration"].tap()
        XCTAssertTrue(app.navigationBars["Sleep duration"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["At least 7 hours"].exists)
        let sleepGuide = XCTAttachment(screenshot: app.screenshot())
        sleepGuide.name = "Sleep duration guidance"; sleepGuide.lifetime = .keepAlways; add(sleepGuide)
    }
}
