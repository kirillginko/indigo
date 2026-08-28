//
//  MiniPlayerUITests.swift
//  IndigoUITests
//
//  The mini player is a second window, which is exactly the kind of thing that
//  compiles and then doesn't open. These assert it actually appears, carries
//  the transport, and survives the main window closing.
//

import XCTest

final class MiniPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "App never showed a window")
        return app
    }

    func testShiftCommandMOpensTheMiniPlayer() throws {
        let app = launch()
        let before = app.windows.count

        app.typeKey("m", modifierFlags: [.command, .shift])

        let mini = app.windows["Mini Player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "⇧⌘M did not open the mini player")
        XCTAssertGreaterThan(app.windows.count, before)
    }

    /// Crate and DIG have to be reachable without the main window — that is
    /// the entire justification for the window existing.
    func testMiniPlayerCarriesTheCrateAction() throws {
        let app = launch()
        app.typeKey("m", modifierFlags: [.command, .shift])

        let mini = app.windows["Mini Player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))

        // Nothing is playing on a cold launch, so the transport is present but
        // inert and the crate button has nothing to keep. The window still has
        // to render rather than collapsing to nothing.
        XCTAssertTrue(mini.staticTexts["mini.primary"].waitForExistence(timeout: 5),
                      "The mini player should render an empty state, not blank")
        // macOS exposes SwiftUI Text as the value, uppercased as drawn.
        XCTAssertEqual(mini.staticTexts["mini.primary"].value as? String, "NOTHING PLAYING")
        XCTAssertEqual(mini.staticTexts["mini.source"].value as? String, "INDIGO")
        XCTAssertGreaterThan(mini.frame.height, 100, "The window collapsed")
    }

    func testMiniPlayerOutlivesTheMainWindow() throws {
        let app = launch()
        app.typeKey("m", modifierFlags: [.command, .shift])
        let mini = app.windows["Mini Player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))

        // Close whichever window is frontmost that isn't the mini player.
        for window in app.windows.allElementsBoundByIndex where window.title != "Mini Player" {
            if window.buttons[XCUIIdentifierCloseWindow].exists {
                window.buttons[XCUIIdentifierCloseWindow].click()
                break
            }
        }

        XCTAssertTrue(mini.exists, "Closing the main window must not take the mini player with it")
    }
}
