//
//  PortraitWithholdLiveCheck.swift
//  IndigoTests
//
//  The 940 withheld portraits (DIG-REMEDIATION-PLAN.md §10), against the live
//  backend: a device that cached one of their old faces drops it through the
//  change feed (0083), and a provisional unique-name face is kept. Opt-in:
//  `TEST_RUNNER_INDIGO_LIVE_PORTRAITS=1` and `TEST_RUNNER_INDIGO_PORTRAITS_SINCE`
//  (just before the change). Fresh in-memory store; nothing kept.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class PortraitWithholdLiveCheck: XCTestCase {
    func testAWithheldFaceLeavesTheDeviceAndAProvisionalOneStays() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["INDIGO_LIVE_PORTRAITS"] == "1", "Set TEST_RUNNER_INDIGO_LIVE_PORTRAITS=1.")
        let since = try XCTUnwrap(env["INDIGO_PORTRAITS_SINCE"])
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        // What the old first-match rule left on devices.
        let cached = ["Nez": "https://img.test/old-nez.jpg", "Odyssey": "https://img.test/old-odyssey.jpg",
                      "Mind State": "https://img.test/old-mind-state.jpg", "Untouched Name": "https://img.test/u.jpg"]
        for (name, url) in cached {
            let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist(name), name: name)
            portrait.imageURLString = url
            context.insert(portrait)
        }
        try context.save()
        let edge = StoredEdge(from: .artist("Somebody"), edge: MusicEdge(
            from: .artist("Somebody"), to: .artist("Nez"), kind: .frequentlyPlayedNearby, source: .radio,
            reason: "r", confidence: 0.6, occurrences: 1))
        edge.toArtworkURLString = cached["Nez"]
        context.insert(edge)
        try context.save()

        let dig = DigStore(context: context)
        let defaults = UserDefaults(suiteName: "indigo.tests.live-portraits.\(UUID().uuidString)")!
        dig.portraitDefaults = defaults
        defaults.set(since, forKey: "portraitStates.changesSince")
        await dig.followPortraitChanges()

        XCTAssertNil(dig.portraitURL(for: "Nez"), "Withheld: dropped")
        XCTAssertNil(dig.portraitURL(for: "Odyssey"), "Withheld: dropped")
        let nezKey = RecordingKey.normalizeArtist("Nez")
        XCTAssertNil(try context.fetch(FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.toKey == nezKey })).first?.toArtworkURLString,
                     "And off the edge that wore it")
        let fresh = ModelContext(container)
        for name in ["Mind State", "Untouched Name"] {
            let key = RecordingKey.normalizeArtist(name)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == key })).first?.imageURLString,
                           cached[name], "\(name): not in the feed's withheld set, kept")
        }
        XCTAssertNotEqual(defaults.string(forKey: "portraitStates.changesSince"), since, "The watermark moved on")
    }
}
