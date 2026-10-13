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
        "Soul Circuit", "John Wall", "Vitor Joaquim", "Remy Unger", "Magic Carpathians Project", "Kim Salmon",
        "Victoria Jordanova", "Quartetto Cetra", "Hong Chulki", "Ortho Acusto", "Chris Liberator & Sterling Moss",
        "The Squires Of The Subterrain", "Willie Jolley", "DKMD", "Gardna", "Lewis OfMan", "Isabell Gustafsson-Ny",
        "Fines Double", "Craz Digga", "Thingamajigs Performance Group", "Sam Wilkes", "Niilas",
        // Not in the pilot: nothing may change.
        "Prefuse 73", "Hype Williams", "Mica Levi",
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

    /// Opens the page; nil when search did not offer the artist.
    func open(_ name: String, pilot: Bool) -> (firstMs: Int?, rows: Set<String>)? {
        app = XCUIApplication.indigo()
        if pilot { app.launchArguments += ["-INDIGO_DIG_CATALOGUE_PILOT", "YES"] }
        app.launch()
        sleep(3)
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { return nil }
        field.tap()
        field.typeText(name)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Artist, " + name)).firstMatch
        guard row.waitForExistence(timeout: 45) else { return nil }
        row.tap()
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
            app.swipeUp()
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
            app.buttons["Search"].firstMatch.tap()
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("Prefuse 73")
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
                for _ in 0..<12 { app.swipeDown() }
                let button = app.buttons.matching(NSPredicate(format: "label == %@", gained)).firstMatch
                for _ in 0..<14 where !button.isHittable { app.swipeUp(); usleep(500_000) }
                if button.isHittable {
                    button.tap()
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
