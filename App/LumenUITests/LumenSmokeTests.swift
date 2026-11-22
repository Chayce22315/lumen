import XCTest

/// How long any single step may take on a cold simulator.
private let timeout: TimeInterval = 20

/// End-to-end smoke tests of the real app: launch, capture, completion and search.
///
/// The app is launched with `-LumenUITesting` (see `LaunchMode`), which gives every launch an
/// empty in-memory store, in-memory secrets, no system notifications and no network, so the tests
/// never depend on — or change — anything outside the launch.
@MainActor
final class LumenSmokeTests: XCTestCase {
    func testLaunchShowsEveryTab() {
        let app = launch()
        let tabBar = app.tabBars.firstMatch
        for title in ["Plan", "Library", "Assistant", "Search"] {
            tabBar.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: timeout), "The \(title) tab did not show its screen")
        }
        tabBar.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["New task"].firstMatch.waitForExistence(timeout: timeout), "Home did not come back")
    }

    func testCaptureAndCompleteTask() {
        let app = launch()
        let title = "Water the plants"
        openPlan(in: app)
        capture(title, in: app)

        element("plan.list.inbox", in: app).tap()
        let row = taskRow(title, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "The captured task is not in the Inbox")

        // The checkbox is the leading 44 pt of the row. 24 pt in lands on it whether the query
        // resolved to the cell or to the row content inside it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 24, dy: 0))
            .tap()
        let completedRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, "completed"))
            .firstMatch
        XCTAssertTrue(completedRow.waitForExistence(timeout: timeout), "Tapping the checkbox did not complete the task")

        app.navigationBars["Inbox"].buttons["Plan"].tap()
        element("plan.list.completed", in: app).tap()
        XCTAssertTrue(app.navigationBars["Completed"].waitForExistence(timeout: timeout))
        XCTAssertTrue(taskRow(title, in: app).waitForExistence(timeout: timeout), "The completed task is not in Completed")
    }

    func testSearchFindsCapturedTask() {
        let app = launch()
        let title = "Renew the passport"
        openPlan(in: app)
        capture(title, in: app)

        app.tabBars.firstMatch.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "The Search tab has no search field")
        field.tap()
        field.typeText("passport")
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: timeout), "Search did not find the captured task")
    }

    // MARK: - Steps

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LumenUITesting"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: timeout), "The main interface never appeared")
        return app
    }

    private func openPlan(in app: XCUIApplication) {
        app.tabBars.firstMatch.buttons["Plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: timeout))
    }

    /// Adds a task through the quick capture sheet from the Plan screen and closes the sheet.
    private func capture(_ title: String, in app: XCUIApplication) {
        app.navigationBars["Plan"].buttons["New task"].tap()
        let field = element("quickCapture.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Quick capture did not open")
        field.tap()
        field.typeText(title)
        element("quickCapture.add", in: app).tap()
        XCTAssertTrue(
            element("quickCapture.confirmation", in: app).waitForExistence(timeout: timeout),
            "Adding the task was not confirmed"
        )
        element("quickCapture.close", in: app).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "Quick capture did not close")
    }

    // MARK: - Queries

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func taskRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
    }
}
