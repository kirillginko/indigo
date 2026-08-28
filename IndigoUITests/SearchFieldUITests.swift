//
//  SearchFieldUITests.swift
//  IndigoUITests
//

import XCTest

final class SearchFieldUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTypingLandsInTheSearchField() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "No search field found")

        field.click()
        app.typeText("aphex")
        XCTAssertEqual(field.value as? String, "aphex")
    }

    /// The regression: a plain TextField only hit-tests the glyph run it
    /// occupies, so clicks landing in the padding inside the bordered box did
    /// nothing at all. Anywhere in the box must take focus.
    func testClickingThePaddingInsideTheBoxTakesFocus() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "No search field found")

        // Just above the text baseline — inside the drawn border, outside the
        // text field's own frame.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.35)).click()
        app.typeText("boards")

        XCTAssertEqual(field.value as? String, "boards",
                       "Clicking inside the search box should focus it")
    }
}
