//
//  IdentityProbeUITests.swift — throwaway probe, not to be committed.
//

import XCTest

final class IdentityProbeUITests: XCTestCase {
    var app: XCUIApplication!
    var log: [String] = []

    func shot(_ name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func text(_ name: String, _ body: String) {
        let attachment = XCTAttachment(string: body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func lines() -> [String] {
        app.debugDescription.split(separator: "\n").filter { $0.contains("Button") || $0.contains("StaticText") }.map(String.init)
    }

    /// Scrolls the page top to bottom, keeping every content-area label once,
    /// in the order first seen.
    func sweep(_ name: String, steps: Int = 14) -> [String] {
        var seen: [String] = []
        var raw: [String] = []
        let window = app.windows.firstMatch
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        for _ in 0..<4 { center.scroll(byDeltaX: 0, deltaY: 2000) }
        for step in 0..<steps {
            let now = lines()
            raw.append("--- step \(step)"); raw += now
            for line in now {
                guard let range = line.range(of: "label: '"), line.contains("Button") else { continue }
                let label = String(line[range.upperBound...].prefix { $0 != "'" })
                guard let x = Double(line.components(separatedBy: "{{").dropFirst().first?.components(separatedBy: ",").first ?? ""),
                      x > 500, !seen.contains(label) else { continue }
                seen.append(label)
            }
            if step % 4 == 0 { shot("\(name)-\(step)") }
            center.scroll(byDeltaX: 0, deltaY: -600)
            usleep(1_200_000)
        }
        text("\(name)-raw", raw.joined(separator: "\n"))
        text("\(name)-rows", seen.joined(separator: "\n"))
        return seen
    }

    func search(_ query: String) {
        app.buttons["Dig"].firstMatch.click()
        sleep(2)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        app.typeText(query + "\n")
        sleep(12)
        shot("search-\(query)")
        text("search-\(query)-lines", lines().joined(separator: "\n"))
    }

    func click(_ label: String, exact: Bool = true) {
        let predicate = exact ? NSPredicate(format: "label == %@", label) : NSPredicate(format: "label CONTAINS %@", label)
        let element = app.buttons.matching(predicate).firstMatch
        if !element.waitForExistence(timeout: 10) {
            // Scroll it into view.
            let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            for _ in 0..<4 { center.scroll(byDeltaX: 0, deltaY: 2000) }
            for _ in 0..<15 where !element.isHittable { center.scroll(byDeltaX: 0, deltaY: -500); usleep(600_000) }
        }
        log.append("click \(label): exists \(element.exists)")
        guard element.exists else { return }
        if !element.isHittable {
            let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            for _ in 0..<15 where !element.isHittable { center.scroll(byDeltaX: 0, deltaY: -500); usleep(600_000) }
        }
        element.click()
        sleep(16)
    }

    /// The breadcrumb at the top of a page ("← PREVIOUS"), by where it is
    /// drawn: it is not exposed to accessibility.
    func back(to label: String) {
        for _ in 0..<4 { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: 2000) }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.225, dy: 0.072)).click()
        log.append("back toward \(label)")
        sleep(8)
    }

    func title() -> String {
        let headings = lines().filter { $0.contains("StaticText") && $0.contains("{{") }
        return headings.first { line in
            guard let y = Double(line.components(separatedBy: "{{").dropFirst().first?.components(separatedBy: ", ").dropFirst().first?.components(separatedBy: "}").first ?? "") else { return false }
            return y > 60 && y < 110 && line.contains("value:")
        } ?? "?"
    }

    func note(_ line: String) { log.append(line) }

    /// Waits on the page until a row whose label matches appears, scrolling
    /// through it; the seconds it took, or nil.
    func secondsUntil(_ format: String, _ argument: String, limit: Int = 90) -> Int? {
        let query = app.buttons.matching(NSPredicate(format: format, argument))
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        let started = Date()
        while Date().timeIntervalSince(started) < Double(limit) {
            for _ in 0..<4 { center.scroll(byDeltaX: 0, deltaY: 2000) }
            for _ in 0..<14 {
                if query.count > 0 { return Int(Date().timeIntervalSince(started)) }
                center.scroll(byDeltaX: 0, deltaY: -600)
                usleep(300_000)
            }
            sleep(3)
        }
        return nil
    }

    func secondsUntilDeep() -> Int? { secondsUntil("label CONTAINS %@", ", Confidence ") }

    func testJourney() throws {
        app = XCUIApplication.indigo()
        app.launch()
        app.activate()
        sleep(3)

        // Cold: the first visits.
        search("Prefuse73")
        click("Artist, Prefuse 73", exact: false)
        note("page after Prefuse73: \(title())")
        shot("prefuse-top")
        let deep = secondsUntilDeep()
        note("first visit: DEEP rows after \(deep.map { "\($0)s" } ?? "never (90s)")")
        shot("prefuse-deep-first")
        XCTAssertNotNil(deep, "DEEP populates on the first visit")
        let firstPrefuse = sweep("prefuse-1")

        click("Scott Herren")
        note("page after Scott Herren: \(title())")
        shot("herren-top")
        _ = sweep("herren", steps: 8)
        click("Piano Overlord")
        note("page after Piano Overlord: \(title())")
        shot("piano-top")
        back(to: "Scott Herren")
        note("back 1: \(title())")
        shot("back-1")
        back(to: "Prefuse 73")
        note("back 2: \(title())")
        shot("back-2")

        // Namesakes, Dean Blunt and the crate.
        search("Hype Williams")
        click("Artist, Hype Williams", exact: false)
        note("page after Hype Williams: \(title())")
        shot("hype-top")
        let deanWait = secondsUntil("label BEGINSWITH %@", "Dean Blunt,")
        note("Dean Blunt row on the duo's page after \(deanWait.map { "\($0)s" } ?? "never (90s)")")
        let hype = sweep("hype-1")
        let dean = hype.first { $0.hasPrefix("Dean Blunt,") } ?? "Dean Blunt"
        click(dean)
        note("page after Dean Blunt row: \(title())")
        shot("dean-top")
        for _ in 0..<4 { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: 2000) }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.947, dy: 0.157)).click()
        sleep(3)
        let crateButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'crate'")).allElementsBoundByIndex.map(\.label)
        note("crate buttons after crating: \(crateButton)")
        shot("dean-crated")
        back(to: "Hype Williams")
        note("back to: \(title())")
        let hypeAgain = sweep("hype-2")
        let deanAgain = hypeAgain.first { $0.hasPrefix("Dean Blunt,") } ?? "Dean Blunt"
        click(deanAgain)
        note("Dean Blunt reopened: \(title())")
        sleep(20)
        let header = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'crate'")).allElementsBoundByIndex.prefix(3).map(\.label)
        note("crate buttons on reopen, after enrichment: \(header)")
        shot("dean-again-enriched")
        XCTAssertEqual(header.first, "Remove from crate", "Dean Blunt stays crated")
        shot("dean-again")

        // Populated: back to where it started.
        search("Prefuse73")
        click("Artist, Prefuse 73", exact: false)
        note("page again: \(title())")
        let secondPrefuse = sweep("prefuse-2")
        note("prefuse rows first \(firstPrefuse.count), second \(secondPrefuse.count)")
        note("only first: \(Set(firstPrefuse).subtracting(secondPrefuse).sorted())")
        note("only second: \(Set(secondPrefuse).subtracting(firstPrefuse).sorted())")

        // History.
        app.buttons["Dig"].firstMatch.click()
        sleep(2)
        let field = app.textFields.firstMatch
        field.click()
        field.typeKey("a", modifierFlags: .command)
        app.typeText("\u{8}")
        sleep(4)
        shot("dig-landing")
        text("dig-landing-lines", lines().joined(separator: "\n"))
        text("log", log.joined(separator: "\n"))
    }

    override func tearDown() {
        if !log.isEmpty { text("log-final", log.joined(separator: "\n")) }
        super.tearDown()
    }

    func testForeground() throws {
        app = XCUIApplication.indigo()
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Dig"].firstMatch.waitForExistence(timeout: 20))
    }

    func testHype() throws {
        app = XCUIApplication.indigo()
        app.launch()
        app.activate()
        sleep(3)
        search("Hype Williams")
        click("Artist, Hype Williams, GB", exact: false)
        let wait = secondsUntil("label BEGINSWITH %@", "Dean Blunt,", limit: 120)
        note("Dean Blunt row after \(wait.map { "\($0)s" } ?? "never (120s)")")
        let rows = sweep("hype")
        note("rows \(rows.count); blunt/copeland/giletti: \(rows.filter { $0.contains("Blunt") || $0.contains("Copeland") || $0.contains("Giletti") })")
    }

    func crateLabels() -> [String] {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'crate'")).allElementsBoundByIndex.prefix(2).map(\.label)
    }

    func testDeanCrate() throws {
        app = XCUIApplication.indigo()
        app.launch()
        app.activate()
        sleep(3)
        search("Dean Blunt")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Artist, Dean Blunt")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        sleep(2)
        shot("dean-opened")
        note("header before crating: \(crateLabels()); subtitle known: \(app.debugDescription.contains("Hackney"))")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.947, dy: 0.157)).click()
        sleep(2)
        note("header after crating: \(crateLabels())")
        sleep(30)
        note("header after enrichment: \(crateLabels()); subtitle known: \(app.debugDescription.contains("Hackney"))")
        shot("dean-enriched")
        search("Dean Blunt")
        let again = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Artist, Dean Blunt")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        again.click()
        sleep(25)
        note("header on reopen: \(crateLabels()); subtitle known: \(app.debugDescription.contains("Hackney"))")
        shot("dean-reopened")
        XCTAssertEqual(crateLabels().first, "Remove from crate")
    }
}
