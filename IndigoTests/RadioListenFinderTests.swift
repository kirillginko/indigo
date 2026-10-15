//
//  RadioListenFinderTests.swift
//  IndigoTests
//

import XCTest
@testable import Indigo

final class RadioListenFinderTests: XCTestCase {
    private func appearance(_ episode: Int, provider: String, aired: Double, url: String?, played: String? = "A Track") -> Catalog.ArtistRadioAppearance {
        Catalog.ArtistRadioAppearance(
            appearanceID: UUID(), episodeID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", episode))!,
            episodeTitle: "Episode \(episode)", airedAt: Date(timeIntervalSince1970: aired), archiveURL: url,
            episodeExternalID: "show/episode-\(episode)", provider: provider, showID: nil, showTitle: "A Show",
            station: nil, hostName: nil, trackIndex: 1, rawArtistName: "Them", rawTrackTitle: played,
            offsetSeconds: 600, recordingID: nil)
    }

    private let row = UUID()

    func testTheNewestEpisodeThatPlaysIsOfferedAndAPlaylistNeverIs() async {
        let row = row
        let finder = RadioListenFinder(
            rows: { _ in [7: [row]] },
            appearances: { _ in [
                self.appearance(1, provider: "youtube", aired: 900, url: "https://www.youtube.com/playlist?list=FL1"),
                self.appearance(2, provider: "nts", aired: 800, url: "https://soundcloud.com/gone/episode"),
                self.appearance(3, provider: "lotradio", aired: 700, url: "https://example.com/hls/index.m3u8"),
                self.appearance(4, provider: "nts", aired: 600, url: "https://soundcloud.com/older/episode")
            ] },
            plays: { _, url in !url.absoluteString.contains("gone") }
        )
        let (found, report) = await finder.find([7])
        let listen = found[7] ?? nil
        XCTAssertEqual(listen?.provider, LotProvider.providerID, "Not the playlist, not the archive that is gone")
        XCTAssertEqual(listen?.episode, "show/episode-3")
        XCTAssertEqual(listen?.played, "A Track")
        XCTAssertEqual(report.checks, 2)
        XCTAssertEqual(report.notPlayable, 1)
        XCTAssertEqual(report.identityReads, 1)
    }

    func testANothingIsKeptOnlyWhenEveryCheckWasAVerdict() async {
        let row = row
        let unsure = RadioListenFinder(
            rows: { _ in [7: [row]] },
            appearances: { _ in [self.appearance(1, provider: "nts", aired: 1, url: "https://soundcloud.com/x")] },
            plays: { _, _ in nil })
        let (found, _) = await unsure.find([7])
        XCTAssertNil(found[7], "Could not tell: ask again later, not 'nothing'")

        let absent = RadioListenFinder(rows: { _ in [:] }, appearances: { _ in [] }, plays: { _, _ in true })
        let (none, report) = await absent.find([8])
        let nothing: RadioListen? = nil
        XCTAssertEqual(none[8], .some(nothing), "Never on the radio: a known nothing")
        XCTAssertEqual(report.appearanceReads, 0)
    }

    func testAFailedIdentityReadAsksNothingElse() async {
        struct Down: Error {}
        let finder = RadioListenFinder(rows: { _ in throw Down() }, appearances: { _ in XCTFail(); return [] }, plays: { _, _ in true })
        let (found, report) = await finder.find([1, 2])
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(report.failures, 1)
    }

    func testTheCardSaysWhatWasPlayedNotThatItHoldsTheRecord() throws {
        let listen = RadioListen(provider: "nts", episode: "show/ep", episodeTitle: "Episode", showTitle: "A Show",
                                 airedAt: Date(timeIntervalSince1970: 1_700_000_000), played: "Their Track",
                                 offsetSeconds: 60, archiveURL: try XCTUnwrap(URL(string: "https://soundcloud.com/x")))
        let line = RecommendationCardView.radioLine(listen)
        XCTAssertTrue(line.hasPrefix("“Their Track” on A Show · "), line)
        XCTAssertNotNil(listen.page.destination, "The episode opens its own page")
    }

    func testTheCacheKeepsAnswersAndNeverAsksTwiceAtOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("radio-cache-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = RadioListenCache(file: file)
        XCTAssertEqual(cache.claim([1, 2]), [1, 2])
        XCTAssertEqual(cache.claim([1, 2, 3]), [3], "Being asked already")
        let nothing: RadioListen? = nil
        cache.record([1: nothing], asked: [1, 2])
        XCTAssertEqual(cache.claim([1, 2]), [2], "A fresh answer is not asked again; an unanswered one is")
        XCTAssertEqual(RadioListenCache(file: file).found[1], .some(nothing), "Kept on disk")
    }
}
