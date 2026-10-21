import XCTest
@testable import Indigo

/// How Live finds a picture for a show its station published none for:
/// by reading the show's name out of what the station does publish.
final class LiveShowTitleTests: XCTestCase {
    func testAlharaReplayNamesItsHostAndShow() {
        let parsed = AlharaLiveTitle.parse("[Abstract Abder & The Rhythm Raoufs] 'Spooky Season'")
        XCTAssertEqual(parsed.host, "Abstract Abder & The Rhythm Raoufs")
        XCTAssertEqual(parsed.show, "Spooky Season")
        // The upload's name begins with the same words.
        let upload = RecordingKey.normalize("Abstract Abder & The Rhythm Raoufs - Spooky Season @ Radio Alhara")
        XCTAssertTrue(upload.hasPrefix(AlharaLiveTitle.matchKey(host: parsed.host, show: parsed.show)))
    }

    func testAlharaPlainTitleIsTheShow() {
        let parsed = AlharaLiveTitle.parse("Live from Bethlehem")
        XCTAssertNil(parsed.host)
        XCTAssertEqual(parsed.show, "Live from Bethlehem")
    }

    func testNoodsRepeatsAreNamedByTheTrack() {
        XCTAssertEqual(NoodsOnAir(scheduledTitle: "Repeats", trackTitle: "After Season Radio").showTitle,
                       "After Season Radio")
        XCTAssertEqual(NoodsOnAir(scheduledTitle: "Breakfast w/ Someone", trackTitle: "Some Track").showTitle,
                       "Breakfast w/ Someone")
        XCTAssertNil(NoodsOnAir(scheduledTitle: nil, trackTitle: nil).showTitle)
    }

    func testDublabBroadcastMatchesTheSlotWithoutItsDate() {
        XCTAssertEqual(DublabBrowseStore.programmeKey("Brennan — Unresolved Dependencies (09.21.26)"),
                       DublabBrowseStore.programmeKey("Brennan - Unresolved Dependencies"))
    }

    func testCashmereReplayNamesItsProgramme() {
        let onAir = CashmereOnAir(showName: "Cashmere Radio Archive", showStartsAt: nil, showEndsAt: nil,
                                  showSlug: nil, trackTitle: "Faulendes Holz – FAUL5 w/excel rose",
                                  trackArtist: "excel rose", upNext: [])
        XCTAssertEqual(onAir.replayedProgramme, "Faulendes Holz")
        let plain = CashmereOnAir(showName: "Morning", showStartsAt: nil, showEndsAt: nil,
                                  showSlug: nil, trackTitle: "Untitled", trackArtist: nil, upNext: [])
        XCTAssertNil(plain.replayedProgramme)
    }
}
