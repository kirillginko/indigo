//
//  EmbedPlaybackUITests.swift
//  IndigoUITests
//
//  Archived NTS episodes play through a hosted widget. This drives the real
//  thing: open an episode, press play, and watch the transport advance.
//

import XCTest

final class EmbedPlaybackUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func clickSidebar(_ app: XCUIApplication, _ label: String) {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", label)
        let match = app.buttons.matching(predicate).allElementsBoundByIndex
            .first { $0.exists && $0.frame.minX < 500 }
        match?.click()
    }

    /// macOS exposes a SwiftUI `Text` as the accessibility *value*, not the
    /// label — reading `.label` here returned "" for every element, which made
    /// the duration assertion below pass vacuously and the elapsed check never
    /// succeed no matter what the transport did.
    private func readout(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        guard element.exists else { return "" }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func elapsed(_ app: XCUIApplication) -> String { readout(app, "player.elapsed") }

    private func duration(_ app: XCUIApplication) -> String { readout(app, "player.duration") }

    func testArchivedEpisodePlaysInsideTheApp() throws {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 3)

        clickSidebar(app, "Latest")
        Thread.sleep(forTimeInterval: 6)

        let tile = app.buttons.allElementsBoundByIndex
            .first { $0.exists && $0.frame.height > 120 && $0.frame.width > 120 }
        XCTAssertNotNil(tile, "No episode tile on the Latest page")
        tile?.click()
        Thread.sleep(forTimeInterval: 6)
        shot("30-episode-before-play")

        let play = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Play Episode")
        ).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15), "No Play Episode button")
        play.click()

        // Give the widget time to load and start.
        var last = ""
        var advanced = false
        for step in 0..<40 {
            Thread.sleep(forTimeInterval: 1)
            last = elapsed(app)
            NSLog("INDIGO_PLAY step=\(step) elapsed=\(last) duration=\(duration(app))")
            if last != "" && last != "--:--" && last != "0:00" { advanced = true; break }
        }
        shot("31-episode-playing")
        let reportedDuration = duration(app)
        XCTAssertFalse(reportedDuration.isEmpty, "No duration readout was exposed at all")
        XCTAssertNotEqual(reportedDuration, "--:--", "The widget never reported a duration")
        XCTAssertTrue(advanced, "Transport never advanced past 0:00; last elapsed: \(last)")
    }
}
