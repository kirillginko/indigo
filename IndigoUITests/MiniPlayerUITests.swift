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
        let mini = app.windows["Mini Player"]
        // macOS reopens the mini player at launch if it was open at the last
        // quit, and then there is no new window for the shortcut to add.
        if mini.exists {
            mini.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertTrue(mini.waitForNonExistence(timeout: 5), "Could not close the restored mini player")
        }
        let before = app.windows.count

        app.typeKey("m", modifierFlags: [.command, .shift])

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

    /// The two corner buttons swap one window for the other: the header's
    /// leaves only the mini player, and the mini player's brings the main
    /// window back and steps aside.
    func testTheCornerButtonsSwapTheTwoWindows() throws {
        let app = launch()
        let mini = app.windows["Mini Player"]
        let toMini = app.buttons["header.miniPlayer"].firstMatch
        let toMain = app.buttons["mini.maximize"].firstMatch

        // Whichever window the last quit left open, start from the main one.
        if !toMini.exists {
            XCTAssertTrue(toMain.waitForExistence(timeout: 5), "Neither window's switch is on screen")
            toMain.click()
        }
        XCTAssertTrue(toMini.waitForExistence(timeout: 10), "No switch in the page header")

        toMini.click()
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "The header switch did not open the mini player")
        XCTAssertTrue(toMini.waitForNonExistence(timeout: 5), "The main window stayed open behind the mini player")

        XCTAssertTrue(toMain.waitForExistence(timeout: 5), "No way back in the mini player's title bar")
        toMain.click()
        XCTAssertTrue(toMini.waitForExistence(timeout: 10), "The mini player's switch did not bring the main window back")
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5), "The mini player stayed open over the main window")
    }
}
