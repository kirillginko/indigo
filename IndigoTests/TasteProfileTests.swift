//
//  TasteProfileTests.swift
//  IndigoTests
//
//  Phase 1. A taste profile nobody sees still has to be right, because
//  everything downstream ranks against it. Pinned here: that it reflects
//  listening rather than clicking, that it is allowed to change, and that it
//  means the same thing after a week as after a year.
//

import XCTest
import SwiftData
@testable import Indigo

final class TasteProfileTests: XCTestCase {
    private func event(
        _ tags: [String],
        seconds: Double = 1200,
        action: ListeningAction = .played,
        daysAgo: Double = 0,
        now: Date
    ) -> ListeningEvent {
        ListeningEvent(
            node: .artist("Someone \(tags.joined())"),
            action: action,
            at: now.addingTimeInterval(-daysAgo * 86_400),
            seconds: seconds,
            tags: ListeningLog.foldTags(tags)
        )
    }

    func testTheStrongestInterestIsTheOneTheyActuallyListenedTo() {
        let now = Date()
        let profile = TasteProfile.build(from: [
            event(["fourth world"], now: now),
            event(["fourth world"], now: now),
            event(["fourth world"], now: now),
            event(["dub"], now: now)
        ], now: now)

        XCTAssertEqual(profile.top(1).first?.interest, "fourth world")
        // Normalised against itself, so the top interest is always 1 whether
        // this is a week of listening or a year of it.
        XCTAssertEqual(profile["fourth world"], 1, accuracy: 0.0001)
        XCTAssertLessThan(profile["dub"], profile["fourth world"])
    }

    func testAShowTaggedTwelveWaysDoesNotOutweighOneTaggedDub() {
        let now = Date()
        let scattered = Array(0..<12).map { "genre\($0)" }
        let profile = TasteProfile.build(from: [
            event(scattered, now: now),
            event(["dub"], now: now)
        ], now: now)

        XCTAssertEqual(profile["dub"], 1, accuracy: 0.0001)
        XCTAssertLessThan(profile["genre0"], 0.2)
    }

    func testTasteIsAllowedToChange() {
        let now = Date()
        // The same amount of listening, half a year apart.
        let profile = TasteProfile.build(from: [
            event(["spiritual jazz"], daysAgo: 240, now: now),
            event(["ambient"], daysAgo: 1, now: now)
        ], now: now)

        XCTAssertEqual(profile["ambient"], 1, accuracy: 0.0001)
        XCTAssertLessThan(profile["spiritual jazz"], 0.2)
        // Faded, not erased. A winter spent in one place still says something.
        XCTAssertGreaterThan(profile["spiritual jazz"], 0)
    }

    func testAMisClickTeachesNothing() {
        let now = Date()
        let profile = TasteProfile.build(from: [
            event(["happy hardcore"], seconds: 3, now: now)
        ], now: now)

        XCTAssertTrue(profile.isEmpty)
        XCTAssertFalse(profile.isConfident)
    }

    func testARefusedGenreIsAnAbsenceRatherThanAWeakInterest() {
        let now = Date()
        let profile = TasteProfile.build(from: [
            event(["ambient"], now: now),
            event(["happy hardcore"], action: .dismissed, now: now)
        ], now: now)

        XCTAssertEqual(profile["happy hardcore"], 0)
        XCTAssertNil(profile.weights["happy hardcore"])
    }

    func testAThinProfileSaysSoRatherThanPretending() {
        let now = Date()
        let thin = TasteProfile.build(from: [event(["dub"], now: now)], now: now)
        XCTAssertFalse(thin.isConfident)

        let fed = TasteProfile.build(from: (0..<12).map {
            event(["dub"], daysAgo: Double($0), now: now)
        }, now: now)
        XCTAssertTrue(fed.isConfident)
    }

    // MARK: Affinity

    func testACloseMatchOnTwoTagsBeatsAScatteredMatchOnNine() {
        let now = Date()
        let profile = TasteProfile.build(from: [
            event(["ambient"], now: now),
            event(["ambient"], now: now),
            event(["fourth world"], now: now),
            event(["techno"], seconds: 40, now: now)
        ], now: now)

        let close = profile.affinity(for: ["ambient", "fourth world"])
        let scattered = profile.affinity(for:
            ["techno", "house", "disco", "edits", "breaks", "garage", "grime", "jungle", "ambient"]
        )
        XCTAssertGreaterThan(close, scattered)
    }

    func testSomethingDescribedInWordsTheyHaveNeverHeardScoresNothing() {
        let now = Date()
        let profile = TasteProfile.build(from: [event(["ambient"], now: now)], now: now)
        XCTAssertEqual(profile.affinity(for: ["speedcore"]), 0)
        XCTAssertEqual(profile.affinity(for: []), 0)
    }

    func testAnEmptyProfileRanksNothingAboveAnythingElse() {
        XCTAssertEqual(TasteProfile.empty.affinity(for: ["ambient", "dub"]), 0)
        XCTAssertTrue(TasteProfile.empty.top().isEmpty)
    }

    // MARK: Clocks

    func testAnEventFromTheFutureIsAClockThatMovedRatherThanEvidence() {
        let now = Date()
        let profile = TasteProfile.build(from: [
            event(["ambient"], daysAgo: -30, now: now)
        ], now: now)
        XCTAssertEqual(profile["ambient"], 1, accuracy: 0.0001)
    }
}
