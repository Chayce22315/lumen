import XCTest

/// Captures App Store–style screenshots of the main screens from sample content
/// (`-LumenScreenshotFixture`, Debug builds only). `scripts/export-screenshots.sh` copies them out
/// of the test results as PNG files named after each step. Run on the simulator whose size you
/// need (for example an iPhone Pro Max for the 6.9" set) with `LUMEN_SIMULATOR=<udid>`.
@MainActor
final class LumenScreenshotTests: XCTestCase {
    private let timeout: TimeInterval = 20

    func testCaptureScreenshots() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LumenUITesting", "-LumenScreenshotFixture"]
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: timeout), "The main interface never appeared")

        XCTAssertTrue(app.buttons["New task"].firstMatch.waitForExistence(timeout: timeout), "Home did not appear")
        capture(app, "01-Home")

        tabBar.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: timeout))
        capture(app, "02-Plan")

        app.descendants(matching: .any).matching(identifier: "plan.list.today").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: timeout))
        capture(app, "03-Today")

        tabBar.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: timeout))
        capture(app, "04-Library")

        tabBar.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("launch")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Launch plan")).firstMatch
            .waitForExistence(timeout: timeout), "Search found nothing to show")
        capture(app, "05-Search")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
