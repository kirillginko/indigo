import XCTest
@testable import Indigo

final class RadioShowArtworkTests: XCTestCase {
    func testDirectoryArtworkFillsMissingLiveArtworkAndPreservesMetadata() {
        let image = URL(string: "https://images.test/show.jpg")!
        let show = RadioShow(title: "Night Shift", host: "Host", summary: "Description",
                             location: "London", genres: ["Ambient"], moods: [], artworkURL: nil,
                             startsAt: Date(timeIntervalSince1970: 100), endsAt: Date(timeIntervalSince1970: 200),
                             detailID: "night-shift")
        let illustrated = show.withArtwork(image)
        XCTAssertEqual(illustrated.artworkURL, image)
        XCTAssertEqual(illustrated.title, show.title)
        XCTAssertEqual(illustrated.detailID, show.detailID)
        XCTAssertEqual(illustrated.startsAt, show.startsAt)
        XCTAssertEqual(illustrated.summary, show.summary)
        XCTAssertEqual(illustrated.withArtwork(URL(string: "https://images.test/older.jpg")).artworkURL, image)
    }

    func testOnlyTheSameProgrammeMatches() {
        XCTAssertTrue(RadioShowArtwork.matches(" NIGHT SHIFT ", "Night Shift"))
        XCTAssertFalse(RadioShowArtwork.matches("Night Shift Special", "Night Shift"))
        XCTAssertFalse(RadioShowArtwork.matches("", ""))
    }
}
