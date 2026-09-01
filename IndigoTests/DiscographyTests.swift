//
//  DiscographyTests.swift
//  IndigoTests
//
//  A page that showed twenty-five things to listen to and no records to show
//  for them.
//

import XCTest
import SwiftData
@testable import Indigo

final class DiscographyTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// A Discogs artist entry can name no releases at all while the app holds
    /// a dozen of their records, pulled in one at a time by crated tracks and
    /// cover lookups. Building the discography only from the listing threw all
    /// of those away.
    func testRecordsAlreadyResolvedAppearEvenWhenTheListingIsEmpty() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("mu tate"),
                                   discogsID: 1, name: "mu tate")
        artist.biography = "Latvian producer based in Berlin"
        // The listing names nothing.
        artist.releaseTitles = []
        context.insert(artist)

        // But these were resolved along the way.
        for (identifier, title, year) in [(10, "they're with you always", 2024),
                                          (11, "world has ended", 2023)] {
            let record = DiscogsReleaseRecord(discogsID: identifier, title: title)
            record.artistNames = ["mu tate"]
            record.year = year
            record.labelNames = ["Not On Label", "Whities"]
            record.imageURLString = "https://img.test/\(identifier).jpg"
            context.insert(record)
        }

        let releases = DigEngine(context: context)
            .artistProfile(name: "mu tate", mbid: nil).releases

        XCTAssertEqual(releases.map(\.title), ["they're with you always", "world has ended"])
        XCTAssertEqual(releases.first?.imageURL?.absoluteString, "https://img.test/10.jpg")
        XCTAssertEqual(releases.first?.label, "Whities", "And not the absence of a label")
    }

    /// A record named by both the listing and the resolved cache is one row.
    func testARecordKnownTwiceStillAppearsOnce() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("mu tate"),
                                   discogsID: 1, name: "mu tate")
        artist.releaseTitles = ["they're with you always"]
        artist.releaseYears = ["2024"]
        artist.releaseDiscogsIDs = [10]
        artist.releaseImageURLStrings = [""]
        context.insert(artist)

        let record = DiscogsReleaseRecord(discogsID: 10, title: "they're with you always")
        record.artistNames = ["mu tate"]
        record.year = 2024
        record.imageURLString = "https://img.test/10.jpg"
        context.insert(record)

        let releases = DigEngine(context: context)
            .artistProfile(name: "mu tate", mbid: nil).releases
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.imageURL?.absoluteString, "https://img.test/10.jpg",
                       "And it keeps the sleeve the resolved record has")
    }
}

/// A row that changes identity while the page is open reads as one record
/// vanishing and a different one appearing further down.
final class ReleaseIdentityTests: XCTestCase {
    private func line(title: String, year: String?, discogsID: Int?) -> ArtistProfile.ReleaseLine {
        ArtistProfile.ReleaseLine(
            title: title, year: year, discogsID: discogsID,
            imageURL: nil, thumbnailURL: nil, label: nil
        )
    }

    /// The year and the Discogs id both arrive partway through enrichment, so
    /// neither can be part of what makes a row itself.
    func testIdentityIsTheRecordNotWhatIsKnownAboutIt() {
        let beforeEnrichment = line(title: "Come To Daddy", year: nil, discogsID: nil)
        let afterYear = line(title: "Come To Daddy", year: "1997", discogsID: nil)
        let afterResolving = line(title: "Come To Daddy", year: "1997", discogsID: 12_345)

        XCTAssertEqual(beforeEnrichment.id, afterYear.id)
        XCTAssertEqual(afterYear.id, afterResolving.id)
    }

    /// Different records are still different rows.
    func testDifferentRecordsKeepDifferentIdentities() {
        XCTAssertNotEqual(
            line(title: "Come To Daddy", year: nil, discogsID: nil).id,
            line(title: "Windowlicker", year: nil, discogsID: nil).id
        )
    }

    /// Spelling drift between catalogues must not split one record in two.
    func testTheSameRecordSpelledDifferentlyIsOneRow() {
        XCTAssertEqual(
            line(title: "Come To Daddy", year: nil, discogsID: nil).id,
            line(title: "come to daddy", year: "1997", discogsID: 1).id
        )
    }
}

/// The same record arrives from four sources, each knowing different things
/// about it. Keeping whichever arrived first threw the rest away.
final class ReleaseMergeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    /// The bug as it appeared: a blank tile in the grid for a record whose
    /// sleeve was on its own page all along. The artist listing knew the title
    /// and nothing else; the resolved record had the picture.
    func testARecordKeepsWhicheverSourceHasThePicture() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Aphex Twin"),
                                   discogsID: 1, name: "Aphex Twin")
        artist.releaseTitles = ["Come To Daddy"]
        artist.releaseYears = [""]
        artist.releaseDiscogsIDs = []
        artist.releaseImageURLStrings = [""]
        artist.releaseThumbnailURLStrings = [""]
        context.insert(artist)

        let resolved = DiscogsReleaseRecord(discogsID: 555, title: "Come To Daddy")
        resolved.artistNames = ["Aphex Twin"]
        resolved.year = 1997
        resolved.labelNames = ["Warp Records"]
        resolved.imageURLString = "https://img.test/daddy.jpg"
        context.insert(resolved)

        let releases = DigEngine(context: context)
            .artistProfile(name: "Aphex Twin", mbid: nil).releases

        XCTAssertEqual(releases.count, 1, "One record, not two")
        let line = try XCTUnwrap(releases.first)
        XCTAssertEqual(line.imageURL?.absoluteString, "https://img.test/daddy.jpg")
        XCTAssertEqual(line.year, "1997")
        XCTAssertEqual(line.label, "Warp Records")
        XCTAssertEqual(line.discogsID, 555, "And it can still be opened")
    }

    /// A Bandcamp sleeve fills the same hole when no catalogue has one.
    func testBandcampFillsTheHoleToo() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Aphex Twin"),
                                   discogsID: 1, name: "Aphex Twin")
        artist.releaseTitles = ["Blackbox Life Recorder"]
        artist.releaseImageURLStrings = [""]
        context.insert(artist)

        let bandcamp = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/blackbox",
            title: "Blackbox Life Recorder", artistName: "Aphex Twin",
            imageURLString: "https://f4.bcbits.com/img/blackbox_10.jpg"
        )
        context.insert(bandcamp)

        let line = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Aphex Twin", mbid: nil).releases.first
        )
        XCTAssertEqual(line.thumbnailURL?.absoluteString,
                       "https://f4.bcbits.com/img/blackbox_9.jpg")
    }

    /// Almost nothing carries a pressing marker, so naming every ordinary
    /// record "UNKNOWN RELEASE" said nothing and made the catalogue look
    /// broken. The kinds worth naming still are.
    func testOnlyRecordsThatSayWhatTheyAreAreLabelled() {
        XCTAssertEqual(ReleaseClassifier.classify(title: "Come To Daddy"), .unknown)
        XCTAssertEqual(
            ReleaseClassifier.classify(title: "Untitled", notes: "White label"),
            .whiteLabel
        )
        XCTAssertTrue(ReleaseKind.whiteLabel.isUnderground)
    }
}

/// Working at the same time is not a connection — everybody who put a record
/// out in the 2010s did.
final class EraConnectionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    @discardableResult
    private func artist(_ name: String, id: Int, labels: [String], styles: [String], years: [String]) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
        record.labelNames = labels
        record.styles = styles
        record.releaseYears = years
        record.releaseTitles = years.map { "Release \($0)" }
        context.insert(record)
        return record
    }

    /// A stranger who happened to release in the same decade is not offered at
    /// all — that filled the list with names the app could say nothing about.
    func testADecadeAloneIsNotAConnection() throws {
        artist("Subject", id: 1, labels: ["Ilian Tape"], styles: ["Techno"], years: ["2018"])
        artist("Stranger", id: 2, labels: ["Some Other Label"], styles: ["Folk"], years: ["2018"])

        let related = DigEngine(context: context).relatedArtists(to: "Subject")
        XCTAssertFalse(related.contains { $0.name == "Stranger" })
    }

    /// But two artists on the same imprint whose catalogues overlap are
    /// contemporaries rather than coincidences — and the reason says which.
    func testAnEraQualifiesAConnectionThatAlreadyExists() throws {
        artist("Subject", id: 1, labels: ["Ilian Tape"], styles: ["Techno"], years: ["2018"])
        artist("Labelmate", id: 2, labels: ["Ilian Tape"], styles: ["Ambient"], years: ["2018"])

        let peer = try XCTUnwrap(
            DigEngine(context: context).relatedArtists(to: "Subject")
                .first { $0.name == "Labelmate" }
        )
        let era = try XCTUnwrap(peer.reasons.first { $0.kind == .sameEra })
        XCTAssertEqual(era.detail, "Ilian Tape in the 2010s",
                       "It names what it is qualifying, not a bare decade")
        XCTAssertTrue(peer.reasons.contains { $0.kind == .sharedLabel })
    }

    /// A record's place in the list is fixed when it is first shown. Years
    /// arrive during enrichment, and re-sorting as they land makes records
    /// slide past each other under the reader's eyes.
    func testTheOrderShownFirstIsTheOrderKept() {
        let first = ["release:a", "release:b", "release:c"]
        let placed = Dictionary(uniqueKeysWithValues: first.enumerated().map { ($1, $0) })

        // "d" is found later and has no place yet.
        let arrived = ["release:c", "release:d", "release:a", "release:b"]
        let settled = arrived.enumerated().sorted { lhs, rhs in
            switch (placed[lhs.element], placed[rhs.element]) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)

        XCTAssertEqual(settled, ["release:a", "release:b", "release:c", "release:d"],
                       "Known records hold their places; new ones join the end")
    }
}
