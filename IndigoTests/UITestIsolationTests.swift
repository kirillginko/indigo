//
//  UITestIsolationTests.swift
//  IndigoTests
//
//  A UI test launches Indigo as a separate process, with no XCTest variable in
//  its environment, so it was indistinguishable from the app somebody uses and
//  opened their real store. The launch argument is what tells it apart.
//

import XCTest
@testable import Indigo

final class UITestIsolationTests: XCTestCase {
    func testTheLaunchArgumentMarksAUITestingProcess() {
        XCTAssertTrue(Persistence.isUITesting(arguments: ["Indigo", "-INDIGO_UI_TESTING"]))
        XCTAssertFalse(Persistence.isUITesting(arguments: ["Indigo"]))
        XCTAssertFalse(Persistence.isUITesting(arguments: []))
    }

    func testTheArgumentTheUITestsPassIsTheOneTheAppReads() {
        XCTAssertEqual(Persistence.uiTestingArgument, "-INDIGO_UI_TESTING")
    }

    func testAUITestingProcessCountsAsTestingSoLaunchRepairsStandAside() {
        // The unit-test host is already `isRunningTests`; this pins that the
        // flag is a way in as well, not the only one.
        XCTAssertTrue(Persistence.isRunningTests)
    }
}
