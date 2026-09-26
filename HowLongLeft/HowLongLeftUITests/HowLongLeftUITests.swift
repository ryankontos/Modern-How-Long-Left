import XCTest

final class HowLongLeftUITests: XCTestCase {
    /// A real launch check catches broken navigation before backend details
    /// such as calendar authorization or iCloud account state are involved.
    @MainActor
    func testPrimaryTabsAndSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Current"].waitForExistence(timeout: 15))

        let upcomingTab = app.tabBars.buttons["Upcoming"]
        XCTAssertTrue(upcomingTab.waitForExistence(timeout: 5))
        upcomingTab.tap()
        XCTAssertTrue(app.navigationBars["Upcoming"].waitForExistence(timeout: 5))

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Calendar Preferences"].exists)
        XCTAssertTrue(app.staticTexts["Widgets & Complications"].exists)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Upcoming"].waitForExistence(timeout: 5))
    }

    /// Keep a baseline for launch time while also checking that the first
    /// useful screen, rather than only the process, becomes available.
    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            XCTAssertTrue(app.staticTexts["Current"].waitForExistence(timeout: 15))
            app.terminate()
        }
    }
}
