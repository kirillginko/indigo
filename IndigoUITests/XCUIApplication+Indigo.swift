//
//  XCUIApplication+Indigo.swift
//  IndigoUITests
//
//  Every UI test builds its app here. The argument tells Indigo to keep its
//  store in memory: without it the app opens the listener's real store, and a
//  test run migrates, repairs and writes to their crate.
//

import XCTest

extension XCUIApplication {
    static func indigo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-INDIGO_UI_TESTING"]
        return app
    }
}
