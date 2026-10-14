//
//  CataloguePilotPagesUITests.swift
//  IndigoUITests
//
//  The DIG catalogue pilot in the running app, beside everything the app
//  itself does when a page opens (Discogs, R2 credit reads, the worker). Each
//  artist is opened twice, pilot off and on, in a fresh launch with the UI-test
//  store (in memory: nobody's history, no CloudKit). Records when the first
//  relationship row appears, every relationship row on the page, and, with the
//  pilot on, whether a row it added opens the artist it names.
//
//  Opt-in: `TEST_RUNNER_INDIGO_MEASURE_PILOT_PAGES=1`. Writes one text
//  attachment per page.
//

import XCTest

final class CataloguePilotPagesUITests: XCTestCase {
    static let artists = [
        // Batch 1 (supabase/functions/_shared/catalogue_batch1.ts): distinctive names, chosen by hash.
        "Christin Nichols", "Arturo En El Barco", "Ai Phoenix", "Martin Brygmann", "Tricky Disco", "Ron Pope",
        "OG Parker", "Rafael Kasma", "Benjamin Koppel", "M. Caye Castagnetto", "Ritual Band", "Rusconi Trio",
        "This Celestial Engine", "Midnite Radio", "Keak Da Sneak", "Nec Nymbl", "Gayun Cannon", "Martin East Project",
        "De Nazaten", "Owain Bellis", "Bruce Mennel", "Luigi Butera",
        // The pilot.
        "Magic Carpathians Project",
        // No bundle: nothing may change.
        "Prefuse 73", "Hype Williams",
    ]

    /// What a relationship row's label reads like: a name, then why.
    static let reasons = [" on ", "together", "Makes up", "Also on", "Releases on", "Appears on", "Recorded with",
                          "Played", "Member", "Alias", "Credited", "Produced", "Same label"]

    var app: XCUIApplication!

    func attach(_ name: String, _ body: String) {
        let attachment = XCTAttachment(string: body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Read from one snapshot of the tree: asking element by element fails when
    /// the page redraws between the asks.
    func relationshipLabels() -> Set<String> {
        var found = Set<String>()
        for line in app.debugDescription.split(separator: "\n") where line.contains("Button,") {
            guard let start = line.range(of: "label: '") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.range(of: "'", options: .backwards) else { continue }
            let label = String(rest[..<end.lowerBound])
            guard label.contains(", "), !label.hasPrefix("Artist, "),
                  Self.reasons.contains(where: { label.contains($0) }) else { continue }
            found.insert(label)
        }
        return found
    }

    func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    func scrollDown() {
        #if os(macOS)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: -600)
        #else
        app.swipeUp()
        #endif
    }

    func scrollUp() {
        #if os(macOS)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: 600)
        #else
        app.swipeDown()
        #endif
    }

    /// Opens the page; nil when search did not offer the artist.
    func open(_ name: String, pilot: Bool) -> (firstMs: Int?, rows: Set<String>)? {
        app = XCUIApplication.indigo()
        // Forced either way: the remote switch is on for development builds.
        app.launchArguments += ["-INDIGO_DIG_CATALOGUE_PILOT", pilot ? "YES" : "NO"]
        app.launch()
        sleep(3)
        #if os(macOS)
        app.buttons["Dig"].firstMatch.click()
        sleep(2)
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 15) else { return nil }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        #else
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return nil }
        field.tap()
        field.typeText(name)
        #endif
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Artist, " + name)).firstMatch
        guard row.waitForExistence(timeout: 45) else { return nil }
        press(row)
        let opened = Date()
        var first: Int?
        var rows = Set<String>()
        // Watched for 40 s: the time the first relationship row appears.
        while Date().timeIntervalSince(opened) < 40 {
            let now = relationshipLabels()
            if first == nil, !now.isEmpty { first = Int(Date().timeIntervalSince(opened) * 1000) }
            rows.formUnion(now)
            sleep(1)
        }
        // Then all of it, scrolled through.
        for _ in 0..<12 {
            scrollDown()
            usleep(700_000)
            rows.formUnion(relationshipLabels())
        }
        return (first, rows)
    }

    func testPilotPagesBesideTheApp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_MEASURE_PILOT_PAGES"] == "1",
                          "Set TEST_RUNNER_INDIGO_MEASURE_PILOT_PAGES=1.")
        var summary: [String] = []
        // The host's firewall holds a freshly installed app's connections for
        // a few minutes: wait until search answers before measuring anything.
        var warm = false
        let warmStarted = Date()
        while !warm, Date().timeIntervalSince(warmStarted) < 600 {
            app = XCUIApplication.indigo()
            app.launch()
            sleep(3)
            #if os(macOS)
            app.buttons["Dig"].firstMatch.click()
            #else
            app.buttons["Search"].firstMatch.tap()
            #endif
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                press(field)
                #if os(macOS)
                field.typeKey("a", modifierFlags: .command)
                app.typeText("Prefuse 73")
                #else
                field.typeText("Prefuse 73")
                #endif
                warm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Artist, Prefuse 73")).firstMatch.waitForExistence(timeout: 30)
            }
            app.terminate()
        }
        summary.append("network ready after \(Int(Date().timeIntervalSince(warmStarted))) s: \(warm)")
        for name in Self.artists {
            let off = open(name, pilot: false)
            app.terminate()
            let on = open(name, pilot: true)
            var opened = "-"
            if let on, let off, let gained = on.rows.subtracting(off.rows).sorted().first {
                // A row the pilot added opens the artist it names.
                let target = String(gained.prefix { $0 != "," })
                for _ in 0..<12 { scrollUp() }
                let button = app.buttons.matching(NSPredicate(format: "label == %@", gained)).firstMatch
                for _ in 0..<14 where !button.isHittable { scrollDown(); usleep(500_000) }
                if button.isHittable {
                    press(button)
                    sleep(6)
                    let title = app.staticTexts.matching(NSPredicate(format: "label == %@", target)).firstMatch
                    opened = title.waitForExistence(timeout: 10) ? "opened \(target)" : "did NOT show \(target)"
                } else {
                    opened = "not hittable"
                }
            }
            app.terminate()
            func describe(_ side: (firstMs: Int?, rows: Set<String>)?) -> String {
                guard let side else { return "not found" }
                let first = side.firstMs.map(String.init) ?? "never"
                return "\(side.rows.count) rows, first \(first) ms"
            }
            var gainedCount = -1, lostCount = -1
            if let on, let off {
                gainedCount = on.rows.subtracting(off.rows).count
                lostCount = off.rows.subtracting(on.rows).count
            }
            let line = [name, "off=" + describe(off), "on=" + describe(on),
                        "gained=\(gainedCount)", "lost=\(lostCount)", "nav=" + opened].joined(separator: "\t")
            summary.append(line)
            let offRows: String = off?.rows.sorted().joined(separator: "\n") ?? ""
            let onRows: String = on?.rows.sorted().joined(separator: "\n") ?? ""
            attach(name, [line, "--- off", offRows, "--- on", onRows].joined(separator: "\n"))
        }
        attach("summary", summary.joined(separator: "\n"))
    }
}
