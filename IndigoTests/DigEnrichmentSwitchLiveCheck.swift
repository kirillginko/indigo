//
//  DigEnrichmentSwitchLiveCheck.swift
//  IndigoTests
//
//  The live switch (0084) decodes, and decides what it says for each cohort.
//  Opt-in: `TEST_RUNNER_INDIGO_LIVE_SWITCH=1`.
//

import XCTest
@testable import Indigo

final class DigEnrichmentSwitchLiveCheck: XCTestCase {
    func testTheLiveSwitchDecodesAndDecides() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INDIGO_LIVE_SWITCH"] == "1", "Set TEST_RUNNER_INDIGO_LIVE_SWITCH=1.")
        let gate = DigEnrichmentSwitch()
        gate.defaults = UserDefaults(suiteName: "indigo.tests.live-switch.\(UUID().uuidString)")!
        await gate.refreshIfDue()
        let decided = gate.decision()
        print("LIVE_SWITCH debug=\(decided)")
        guard case .on(let manifest) = decided else { return XCTFail("debug: \(decided)") }
        XCTAssertEqual(manifest.count, 64)
        gate.cohort = .testflight
        XCTAssertTrue(gate.isOn, "Internal TestFlight builds receive it (approved 2026-10-14)")
        gate.cohort = .appstore
        XCTAssertFalse(gate.isOn, "App Store builds never do until approved")
        XCTAssertEqual(manifest, "b0bb56323c467633aa8db134fb30ed7e6091f379ebf5269689e63792e8457ee7", "The pilot and batch 1, nothing more")
    }
}
