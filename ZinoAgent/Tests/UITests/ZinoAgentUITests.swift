import XCTest

final class ZinoAgentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndNavigatesPrimarySections() throws {
        let app = XCUIApplication()
        app.launch()

        // Verify Home screen renders.
        XCTAssertTrue(app.staticTexts["ZinoAgent"].waitForExistence(timeout: 8))

        // Navigate through primary tabs/sidebar entries where visible.
        for label in ["Files", "AI Chat", "3D Studio", "Image Studio", "Models", "Settings", "Home"] {
            let button = app.buttons[label].firstMatch
            let cell = app.cells.staticTexts[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
            } else if cell.exists && cell.isHittable {
                cell.tap()
            }
        }
    }
}
