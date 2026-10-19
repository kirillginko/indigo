//
//  PortraitProbeUITests.swift — throwaway probe for the portrait remediation, not to be committed.
//

import XCTest

final class PortraitProbeUITests: XCTestCase {
    var app: XCUIApplication!

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func dump(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func open(_ query: String, pick: String) {
        app = XCUIApplication.indigo()
        app.launchArguments += ["-INDIGO_DIG_CATALOGUE_PILOT", "YES"]
        app.launch()
        sleep(3)
        app.buttons["Search"].firstMatch.tap()
        sleep(2)
        let field = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        guard field.waitForExistence(timeout: 10) else { dump("\(query)-nofield"); return }
        field.tap()
        field.typeText(query)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (label == 'Clear search')", pick)).firstMatch
        _ = row.waitForExistence(timeout: 60)
        sleep(3)
        shot("\(query)-results")
        dump("\(query)-results-tree")
        guard row.exists else { return }
        row.tap()
        sleep(18)
        shot("\(query)-page")
        dump("\(query)-page-tree")
        for step in 2...9 {
            app.swipeUp()
            sleep(2)
            shot("\(query)-page-\(step)")
        }
        dump("\(query)-bottom-tree")
        app.terminate()
    }

    func testPilotMagicCarpathians() { open("Magic Carpathians Project", pick: "Magic Carpathians") }

    func testOGParkerExpanded() {
        app = XCUIApplication.indigo()
        app.launchArguments += ["-INDIGO_DIG_CATALOGUE_PILOT", "YES"]
        app.launch()
        sleep(3)
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields.firstMatch
        _ = field.waitForExistence(timeout: 10)
        field.tap()
        field.typeText("OG Parker")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Artist, OG Parker")).firstMatch
        _ = row.waitForExistence(timeout: 45)
        row.tap()
        sleep(40)
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "All ")).firstMatch
        for _ in 0..<14 where !all.isHittable { app.swipeUp(); usleep(500_000) }
        let found = XCTAttachment(string: "all button: \(all.exists ? all.label : "none")")
        found.name = "og-all-button"; found.lifetime = .keepAlways; add(found)
        if all.isHittable { all.tap(); sleep(2) }
        var tree = app.debugDescription
        for _ in 0..<6 { app.swipeUp(); usleep(600_000); tree += app.debugDescription }
        let attachment = XCTAttachment(string: tree)
        attachment.name = "og-expanded-tree"; attachment.lifetime = .keepAlways; add(attachment)
        shot("og-expanded")
    }

    /// The three anomalies of the batch 1 run: what search offers, what the
    /// page holds, and for Bruce Mennel, where "Drama Aka Treason" leads.
    func testAnomalies() {
        for (name, follow) in [("Bruce Mennel", "Drama Aka Treason"), ("Ritual Band", nil), ("OG Parker", nil)] as [(String, String?)] {
            app = XCUIApplication.indigo()
            app.launchArguments += ["-INDIGO_DIG_CATALOGUE_PILOT", "YES"]
            app.launch()
            sleep(3)
            app.buttons["Search"].firstMatch.tap()
            let field = app.textFields.firstMatch
            guard field.waitForExistence(timeout: 10) else { continue }
            field.tap()
            field.typeText(name)
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Artist, " + name)).firstMatch
            _ = row.waitForExistence(timeout: 45)
            sleep(3)
            shot("\(name)-results")
            dump("\(name)-results-tree")
            guard row.exists else { app.terminate(); continue }
            row.tap()
            sleep(40)
            shot("\(name)-page")
            var tree = app.debugDescription
            for _ in 0..<10 { app.swipeUp(); usleep(700_000); tree += "\n=== scrolled\n" + app.debugDescription }
            let attachment = XCTAttachment(string: tree)
            attachment.name = "\(name)-page-tree"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let follow {
                for _ in 0..<12 { app.swipeDown() }
                let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", follow)).firstMatch
                for _ in 0..<14 where !target.isHittable { app.swipeUp(); usleep(500_000) }
                if target.isHittable {
                    let label = XCTAttachment(string: target.label)
                    label.name = "\(name)-followed-row"
                    label.lifetime = .keepAlways
                    add(label)
                    target.tap()
                    sleep(15)
                    shot("\(name)-followed-page")
                    dump("\(name)-followed-tree")
                }
            }
            app.terminate()
        }
    }
}

#if os(macOS)
final class PortraitMacProbeUITests: XCTestCase {
    var app: XCUIApplication!

    func shot(_ name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func dump(_ name: String) {
        let lines = app.debugDescription.split(separator: "\n").filter { $0.contains("Button") || $0.contains("StaticText") || $0.contains("Image") }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func open(_ query: String, pick: String) {
        app.buttons["Dig"].firstMatch.click()
        sleep(2)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        app.typeText(query + "\n")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pick)).firstMatch
        _ = row.waitForExistence(timeout: 45)
        sleep(4)
        shot("\(query)-results")
        dump("\(query)-results-tree")
        guard row.exists else { return }
        row.click()
        sleep(20)
        shot("\(query)-page")
        dump("\(query)-page-tree")
    }

    func testRepresentativePages() {
        app = XCUIApplication.indigo()
        app.launch()
        sleep(5)
        open("Hype Williams", pick: "Hype Williams")
        open("Speedy J", pick: "Speedy J")
        open("Prefuse 73", pick: "Prefuse 73")
        open("Tom Zé", pick: "Tom Z")
        open("Logic", pick: "Logic")
    }
}
#endif
