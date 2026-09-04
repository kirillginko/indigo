//
//  RadioIngestionTests.swift
//  IndigoTests
//
//  The app asks the backend to ingest a broadcast by naming it, and the Edge
//  Function refuses anything that is not the shape it expects
//  (supabase/functions/catalog-refresh/index.ts). Every other resource id in
//  Indigo is one opaque token; an NTS broadcast is genuinely two slugs, and
//  that exception is the one place the two sides can disagree.
//
//  A disagreement here does not fail loudly. It returns `invalid_resource_id`
//  into a fire-and-forget task, and radio provenance simply never accumulates.
//

import XCTest
@testable import Indigo

final class RadioIngestionTests: XCTestCase {
    /// The Edge Function's allow-list, transcribed. If one of these changes
    /// the other has to, and this is where that gets noticed.
    private let slug = "[A-Za-z0-9][A-Za-z0-9_-]{0,80}"

    private func isAcceptedAsEpisodeID(_ value: String) -> Bool {
        let pattern = "^\(slug)(/\(slug))?$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        // The function checks the resource type too: an id with no separator
        // would build `shows/x/episodes/undefined`.
        return value.split(separator: "/", maxSplits: 2).count == 2
    }

    func testTheIdsIndigoSendsAreTheOnesTheBackendAccepts() {
        let broadcasts = [
            ("ben-ufo", "12th-june-2026"),
            ("moxie", "3rd-february-2026"),
            ("the-trilogy-tapes", "20th-may-2025"),
            ("nts-breakfast", "1st-january-2026"),
            ("guests", "skee-mask-4th-april-2024"),
            ("4-to-the-floor", "18th-august-2023")
        ]

        for (show, episode) in broadcasts {
            let id = RadioRepository.ntsEpisodeResourceID(show: show, episode: episode)
            XCTAssertTrue(isAcceptedAsEpisodeID(id), "\(id) would be refused")
        }
    }

    /// The separator is the identity, and it survives a round trip — an
    /// artist's radio history is only navigable because a stored external id
    /// can be turned back into a page.
    func testABroadcastIdSplitsBackIntoTheShowAndEpisodeItNames() {
        let id = RadioRepository.ntsEpisodeResourceID(show: "ben-ufo", episode: "12th-june-2026")
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)

        XCTAssertEqual(parts, ["ben-ufo", "12th-june-2026"])
    }

    /// Not a hypothetical: the id is built from two aliases, and an episode
    /// alias that itself contained a slash would send the fetch somewhere
    /// other than the episode it names.
    func testAnAliasCarryingItsOwnSeparatorIsNotAcceptedAsABroadcast() {
        let id = RadioRepository.ntsEpisodeResourceID(
            show: "ben-ufo", episode: "12th-june-2026/../../secrets")

        XCTAssertFalse(isAcceptedAsEpisodeID(id))
    }
}
