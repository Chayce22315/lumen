import XCTest
import UIKit

/// How long any single step may take on a cold simulator.
private let timeout: TimeInterval = 20

/// iPad at regular width: Plan's lists are sidebar items and show the selected task beside the
/// list. Skipped on iPhone, where `LumenSmokeTests` covers the tab bar.
@MainActor
final class LumenIPadTests: XCTestCase {
    func testTaskOpensBesideItsList() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "The sidebar layout is iPad-only")
        continueAfterFailure = false
        // Every iPad is regular width in landscape, full screen.
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-LumenUITesting"]
        app.launch()

        let today = sidebarItem("Today", in: app)
        XCTAssertTrue(today.waitForExistence(timeout: timeout), "Today is neither in the sidebar nor in iPad's tab bar")
        today.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: timeout), "Today did not open")
        XCTAssertTrue(
            app.staticTexts["No Task Selected"].waitForExistence(timeout: timeout),
            "The detail column is not beside the list"
        )

        app.navigationBars["Today"].buttons["New task"].tap()
        let field = element("quickCapture.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Quick capture did not open")
        field.tap()
        field.typeText("Water the plants today")
        element("quickCapture.add", in: app).tap()
        XCTAssertTrue(element("quickCapture.confirmation", in: app).waitForExistence(timeout: timeout), "Adding the task was not confirmed")
        element("quickCapture.close", in: app).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "Quick capture did not close")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Water the plants"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "The captured task is not in Today")
        // The checkbox is the row's leading 44 pt; the middle of the row selects it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Task"].waitForExistence(timeout: timeout), "The task did not open")
        XCTAssertTrue(app.navigationBars["Today"].exists, "The task replaced its list instead of opening beside it")
        XCTAssertFalse(app.staticTexts["No Task Selected"].exists, "The placeholder is still shown")
    }

    // MARK: - Queries

    /// A sidebar row, or the same item in iPad's tab bar when the sidebar is collapsed into it.
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: timeout) { return button }
        return app.cells.containing(.staticText, identifier: title).firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
