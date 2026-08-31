//
//  ArtworkFallbackTests.swift
//  IndigoTests
//
//  Sleeves that were there all along, and the marks that stand in when there
//  is genuinely no picture.
//

import XCTest
import SwiftData
import AppKit
@testable import Indigo

final class ArtworkFallbackTests: XCTestCase {
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

    /// Discogs' artist listing frequently omits a cover the release itself
    /// has. That is why a tile stayed blank until somebody opened it and came
    /// back — the sleeve was already cached, just never read.
    func testACoverAlreadyCachedIsUsedWithoutOpeningTheRelease() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Seefeel"),
                                   discogsID: 1, name: "Seefeel")
        artist.releaseTitles = ["Squared Roots", "Quique"]
        artist.releaseDiscogsIDs = [500, 501]
        artist.releaseYears = ["2024", "1993"]
        // Exactly the state that produced the blank tiles: no cover here.
        artist.releaseImageURLStrings = ["", ""]
        artist.releaseThumbnailURLStrings = ["", ""]
        context.insert(artist)

        let opened = DiscogsReleaseRecord(discogsID: 500, title: "Squared Roots")
        opened.artistNames = ["Seefeel"]
        opened.labelNames = ["Warp Records"]
        opened.imageURLString = "https://img.test/squared-roots.jpg"
        context.insert(opened)

        let profile = DigEngine(context: context).artistProfile(name: "Seefeel", mbid: nil)
        let resolved = try XCTUnwrap(profile.releases.first { $0.title == "Squared Roots" })
        let unresolved = try XCTUnwrap(profile.releases.first { $0.title == "Quique" })

        XCTAssertEqual(resolved.imageURL?.absoluteString, "https://img.test/squared-roots.jpg")
        XCTAssertEqual(resolved.label, "Warp Records", "And the label it came off")
        XCTAssertNil(unresolved.imageURL, "Nothing cached is still nothing")
    }

    /// Matched on the identifier rather than the title, so two records with
    /// the same name don't swap sleeves.
    func testSleevesAreMatchedByIdentifierNotByName() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Various"),
                                   discogsID: 1, name: "Various")
        artist.releaseTitles = ["Untitled"]
        artist.releaseDiscogsIDs = [700]
        artist.releaseImageURLStrings = [""]
        context.insert(artist)

        let wrong = DiscogsReleaseRecord(discogsID: 999, title: "Untitled")
        wrong.artistNames = ["Various"]
        wrong.imageURLString = "https://img.test/a-different-untitled.jpg"
        context.insert(wrong)

        let right = DiscogsReleaseRecord(discogsID: 700, title: "Untitled")
        right.artistNames = ["Various"]
        right.imageURLString = "https://img.test/the-right-one.jpg"
        context.insert(right)

        let profile = DigEngine(context: context).artistProfile(name: "Various", mbid: nil)
        XCTAssertEqual(profile.releases.first?.imageURL?.absoluteString,
                       "https://img.test/the-right-one.jpg")
    }

    /// Several stations publish no picture of what is on air. Their own mark
    /// beats an empty square in the one place always in view.
    func testAStationWithNoPictureStillHasAMark() {
        XCTAssertEqual(StationMark.logoURL(for: LYLProvider.providerID), LYLProvider.logoURL)
        XCTAssertEqual(StationMark.logoURL(for: CashmereProvider.providerID), CashmereProvider.logoURL)
        XCTAssertEqual(StationMark.logoURL(for: AlharaProvider.providerID), AlharaProvider.logoURL)
        XCTAssertEqual(StationMark.logoURL(for: DublabProvider.providerID), DublabProvider.logoURL)
        XCTAssertEqual(StationMark.name(for: LYLProvider.providerID), "LYL")
    }

    /// Stations that do publish artwork must not have it replaced by a logo,
    /// and neither must a local file.
    func testStationsWithTheirOwnArtworkAreLeftAlone() {
        XCTAssertNil(StationMark.logoURL(for: NTSProvider.providerID))
        XCTAssertNil(StationMark.logoURL(for: Track.sourceID))
        XCTAssertNil(StationMark.logoURL(for: nil))
        XCTAssertNil(StationMark.name(for: NTSProvider.providerID))
    }

    /// Some stations publish nothing bigger than a 32-pixel favicon. Blown up
    /// to fill a tile that is a blurry smear; the name is at least legible.
    func testAMarkIsNotBlownUpPastWhatItCanCarry() {
        let tiny = PlatformImage(size: NSSize(width: 32, height: 32))
        let large = PlatformImage(size: NSSize(width: 512, height: 512))

        XCTAssertTrue(ArtworkView.canCarry(tiny, at: 68), "A player-bar thumbnail it can manage")
        XCTAssertFalse(ArtworkView.canCarry(tiny, at: 220), "A full tile it cannot")
        XCTAssertTrue(ArtworkView.canCarry(large, at: 220))
        XCTAssertTrue(ArtworkView.canCarry(tiny, at: 0), "No size yet is not a reason to refuse")
    }

    /// Discogs lists "Electronic" beside "Techno" constantly. Printing both
    /// says less than printing one.
    func testStylesAndGenresDoNotRepeatThemselves() throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 1, name: "Skee Mask")
        artist.styles = ["Techno", "Ambient"]
        artist.genres = ["techno", "Electronic"]
        artist.imageURLString = "https://img.test/skee.jpg"
        context.insert(artist)

        let profile = DigEngine(context: context).artistProfile(name: "Skee Mask", mbid: nil)
        var seen = Set<String>()
        let tags = (profile.styles + profile.genres).filter {
            seen.insert(RecordingKey.normalize($0)).inserted
        }
        XCTAssertEqual(tags, ["Techno", "Ambient", "Electronic"])
    }

    /// A row of names is a list; a row of faces is a shelf. The portrait
    /// travels with the connection when a catalogue we have already read
    /// supplied one.
    func testAKnownArtistBringsTheirPortraitAlong() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        context.insert(subject)

        let peer = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Stenny"),
                                 discogsID: 2, name: "Stenny")
        peer.labelNames = ["Ilian Tape"]
        peer.imageURLString = "https://img.test/stenny.jpg"
        context.insert(peer)

        let related = DigEngine(context: context).relatedArtists(to: "Skee Mask")
        let stenny = try XCTUnwrap(related.first { $0.name == "Stenny" })
        XCTAssertEqual(stenny.imageURL?.absoluteString, "https://img.test/stenny.jpg")
    }

    /// The picture arrives in the same search response the name does, and was
    /// being thrown away. It is a record of theirs rather than a portrait —
    /// which for a row that exists *because* you both put records out on the
    /// same imprint is arguably the better image, and costs nothing.
    func testANeighboursPictureCostsNoExtraRequest() throws {
        let results = [
            DiscogsSearchResult(
                id: 1, title: "Stenny - Consumer's Tool", coverImage: "https://img.test/big.jpg",
                thumbnail: "https://img.test/small.jpg", genre: nil, style: nil, label: nil, year: nil
            ),
            DiscogsSearchResult(
                id: 2, title: "No Separator Here", coverImage: nil, thumbnail: nil,
                genre: nil, style: nil, label: nil, year: nil
            )
        ]
        let neighbours = DiscogsClient.neighbours(from: results)

        XCTAssertEqual(neighbours.map(\.name), ["Stenny"])
        XCTAssertEqual(neighbours.first?.thumbnailURL, "https://img.test/small.jpg",
                       "The small cut — a 38-point row has no use for a 600-pixel sleeve")
    }

    /// Their own portrait when we have dug into them; a record of theirs when
    /// we have not. Either beats an empty box in a row of forty.
    func testAPeerWithoutAPortraitStillHasAPicture() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny", "Andrea"]
        subject.labelNeighbourImageURLStrings = ["https://img.test/stenny-record.jpg", ""]
        context.insert(subject)

        // Andrea has been dug into, so we have her actual portrait.
        let andrea = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Andrea"),
                                   discogsID: 3, name: "Andrea")
        andrea.imageURLString = "https://img.test/andrea-portrait.jpg"
        context.insert(andrea)

        let related = DigEngine(context: context).relatedArtists(to: "Skee Mask")
        XCTAssertEqual(related.first { $0.name == "Stenny" }?.imageURL?.absoluteString,
                       "https://img.test/stenny-record.jpg")
        XCTAssertEqual(related.first { $0.name == "Andrea" }?.imageURL?.absoluteString,
                       "https://img.test/andrea-portrait.jpg",
                       "A real portrait outranks a sleeve")
    }

    /// Somebody dug into before Discogs gave us a portrait still has records,
    /// and a picture of one of those beats a hole in the row.
    func testAnArtistWithNoPortraitFallsBackToTheirOwnRecord() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        context.insert(subject)

        let peer = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Stenny"),
                                 discogsID: 2, name: "Stenny")
        peer.labelNames = ["Ilian Tape"]
        peer.imageURLString = nil
        peer.releaseThumbnailURLStrings = ["", "https://img.test/stenny-lp.jpg"]
        context.insert(peer)

        let related = DigEngine(context: context).relatedArtists(to: "Skee Mask")
        XCTAssertEqual(related.first { $0.name == "Stenny" }?.imageURL?.absoluteString,
                       "https://img.test/stenny-lp.jpg")
    }

    /// Firing four dozen requests in one breath is how a service starts
    /// refusing them.
    func testWorkIsSentInBatchesRatherThanAllAtOnce() {
        XCTAssertEqual(Array(1...14).chunked(into: 6).map(\.count), [6, 6, 2])
        XCTAssertEqual([Int]().chunked(into: 6).count, 0)
        XCTAssertEqual(Array(1...3).chunked(into: 6), [[1, 2, 3]])
        XCTAssertEqual(Array(1...3).chunked(into: 0), [[1, 2, 3]], "A nonsense size is not a crash")
    }
}

/// Lazy grids rebuild a tile every time it scrolls back into view, so a
/// missing picture is asked for again on every pass.
final class MissingArtworkTests: XCTestCase {
    /// A picture that is not there stays not there — for an hour, which is
    /// long enough to stop a grid retrying on every scroll and short enough
    /// that a service having a bad minute does not cost the rest of the
    /// session.
    func testAKnownMissingPictureIsNotAskedForAgain() async throws {
        let store = RemoteArtworkStore.shared
        let missing = try XCTUnwrap(URL(string: "https://i.discogs.com/indigo-test-\(UUID().uuidString).jpg"))

        let first = await store.image(for: missing)
        XCTAssertNil(first)

        // The second ask is answered from what was learned, not from the
        // network. Correctness is what is pinned here; the saving is the point.
        let second = await store.image(for: missing)
        XCTAssertNil(second)
    }

    /// A record MusicBrainz lists and nobody pictures is exactly the one whose
    /// sleeve is already sitting in the Bandcamp cache.
    func testABandcampSleeveFillsInAMusicBrainzRelease() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)

        let artist = Artist(mbid: "mb-1", name: "Space Afrika")
        artist.releaseTitles = ["Honest Labour"]
        artist.releaseDates = ["2021-08-27"]
        context.insert(artist)

        let release = BandcampRelease(
            urlString: "https://x.bandcamp.com/album/honest-labour",
            title: "Honest Labour", artistName: "Space Afrika", labelName: "sferic",
            imageURLString: "https://f4.bcbits.com/img/a0599943016_10.jpg"
        )
        context.insert(release)

        let line = try XCTUnwrap(
            DigEngine(context: context).artistProfile(name: "Space Afrika", mbid: "mb-1")
                .releases.first { $0.title == "Honest Labour" }
        )
        XCTAssertEqual(line.thumbnailURL?.absoluteString,
                       "https://f4.bcbits.com/img/a0599943016_9.jpg")
        XCTAssertEqual(line.label, "sferic")
    }
}
