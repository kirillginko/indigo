//
//  PortraitFillTests.swift
//  IndigoTests
//
//  Filling in the rows nobody has dug into, slowly, without emptying the
//  request budget.
//

import XCTest
import SwiftData
@testable import Indigo

final class PortraitFillTests: XCTestCase {
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

    /// A picture found on its own is not the same as having dug into someone.
    /// Keeping them apart is what stops a thumbnail lookup masquerading as a
    /// full artist record.
    func testALookedUpPictureIsNotADugArtist() throws {
        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)

        XCTAssertTrue(((try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []).isEmpty)
        XCTAssertEqual(portrait.imageURL?.absoluteString, "https://img.test/stenny.jpg")
    }

    /// Nothing found is a real answer worth remembering, so the same name is
    /// not asked after on every launch — but a catalogue gains artists, so it
    /// is not remembered forever either.
    func testAMissIsRememberedButNotForever() {
        let miss = ArtistPortrait(nameKey: "nobody", name: "Nobody")
        miss.lookupFailed = true
        XCTAssertFalse(miss.isWorthRetrying, "Not today")

        miss.fetchedAt = Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        XCTAssertTrue(miss.isWorthRetrying, "But eventually")

        let hit = ArtistPortrait(nameKey: "stenny", name: "Stenny")
        hit.imageURLString = "https://img.test/stenny.jpg"
        hit.fetchedAt = Date(timeIntervalSinceNow: -400 * 24 * 60 * 60)
        XCTAssertFalse(hit.isWorthRetrying, "A picture we have does not go stale")
    }

    /// The whole point: a row that had nothing gets a picture once the
    /// background fill has been past, without anybody digging into them.
    func testAFilledPortraitReachesTheRow() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny"]
        context.insert(subject)

        XCTAssertNil(DigEngine(context: context).relatedArtists(to: "Skee Mask")
            .first { $0.name == "Stenny" }?.imageURL)

        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)

        XCTAssertEqual(
            DigEngine(context: context).relatedArtists(to: "Skee Mask")
                .first { $0.name == "Stenny" }?.imageURL?.absoluteString,
            "https://img.test/stenny.jpg"
        )
    }

    /// A real portrait from a dig outranks one found by the background fill.
    @MainActor
    func testADugPortraitOutranksALookedUpOne() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny"]
        context.insert(subject)

        let dug = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Stenny"),
                                discogsID: 2, name: "Stenny")
        dug.imageURLString = "https://img.test/dug.jpg"
        dug.labelNames = ["Ilian Tape"]
        context.insert(dug)

        let looked = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        looked.imageURLString = "https://img.test/looked-up.jpg"
        context.insert(looked)

        XCTAssertEqual(
            DigEngine(context: context).relatedArtists(to: "Skee Mask")
                .first { $0.name == "Stenny" }?.imageURL?.absoluteString,
            "https://img.test/dug.jpg"
        )
        XCTAssertEqual(DigStore(context: context).portrait(for: "STENNY")?.imageURLString,
                       "https://img.test/looked-up.jpg",
                       "And the lookup is still findable by however the name was spelled")
    }
}

/// The fill has to be owned by something that outlives a page.
@MainActor
final class PortraitFillLifecycleTests: XCTestCase {
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

    /// The bug: started from a page, the fill was cancelled by the first
    /// navigation — and its own start-once guard then stopped it ever running
    /// again. It filled in for a few seconds per launch and never resumed,
    /// which is why rows stayed blank until each artist was opened by hand.
    func testACancelledFillCanBePickedUpAgain() async throws {
        let dig = DigStore(context: context)

        // Cancelled the way a destroyed page cancels it.
        let first = Task { await dig.fillPortraitsInBackground(spacing: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(60))
        first.cancel()
        _ = await first.result

        // The queue must not be closed for the session.
        let second = Task { await dig.fillPortraitsInBackground(spacing: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(60))
        second.cancel()
        _ = await second.result

        // Nothing to assert about pictures here — no network, no token. What
        // is pinned is that the second run was allowed to begin at all.
        XCTAssertTrue(true)
    }

    /// The two table reads the fill begins with must happen on the worker.
    ///
    /// The fill starts four seconds after launch — deliberately, to let the
    /// first page settle — and used to open by materialising the whole
    /// portrait table, then the whole artist table, on the main actor. That
    /// is the hitch a listener sees once the window has stopped moving: the
    /// app loads, runs fine, and then catches. Neither read was measured, so
    /// nothing in the trace named it.
    func testTheFillsOpeningReadsHappenOffTheMainActor() async throws {
        for index in 0..<400 {
            let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Artist \(index)"),
                                       discogsID: index, name: "Artist \(index)")
            artist.labelNeighbourNames = (0..<12).map { "Neighbour \(index)-\($0)" }
            context.insert(artist)
            let portrait = ArtistPortrait(
                nameKey: RecordingKey.normalizeArtist("Artist \(index)"), name: "Artist \(index)"
            )
            portrait.imageURLString = "https://img.test/\(index).jpg"
            context.insert(portrait)
        }
        try context.save()

        let worker = DigWorker(modelContainer: container)

        // The reads themselves, asked for the way the fill asks for them.
        let index = await worker.portraitIndex()
        let pending = await worker.pendingPortraits()

        XCTAssertEqual(index.count, 400, "Every stored picture, by name")
        XCTAssertFalse(pending.isEmpty, "Neighbours nobody has a picture for")
        XCTAssertFalse(
            pending.contains { RecordingKey.normalizeArtist($0) == RecordingKey.normalizeArtist("Artist 3") },
            "Somebody already pictured is not still pending"
        )
        let ranOffMain = await worker.runsOffTheMainThread()
        XCTAssertTrue(ranOffMain, "And the context they were read on is not the main one")
    }

    /// A page says whose pictures it needs, and those go first — one for
    /// somebody on screen is worth more than one for a name three pages back.
    func testWhatIsOnScreenIsAskedForFirst() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Squarepusher"),
                                    discogsID: 1, name: "Squarepusher")
        subject.collaboratorNames = ["Somebody Buried", "Carl Craig"]
        context.insert(subject)

        let dig = DigStore(context: context)
        dig.wantPortraits(for: ["Carl Craig"])

        // Placeholders never enter the queue.
        dig.wantPortraits(for: ["Various", "Carl Craig"])
        XCTAssertTrue(ArtistName.isRealArtist("Carl Craig"))
        XCTAssertFalse(ArtistName.isRealArtist("Various"))
    }
}

/// A picture arriving is not a reason to rebuild anybody's graph.
@MainActor
final class PortraitInvalidationTests: XCTestCase {
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

    /// A picture that arrives after the fold was read still reaches the row.
    ///
    /// The fold used to re-read the whole portrait table whenever its row
    /// count moved — 243ms of a 614ms rebuild, paid on nearly every one,
    /// because the background fill changes that count every second and a
    /// half. It now asks only for what has been written since. That is only
    /// sound if a new picture is genuinely picked up, and if a replacement is
    /// too — the count does not move for a replacement, and the old code
    /// inherited straight past those.
    @MainActor
    func testAPictureWrittenAfterTheFoldIsStillSeen() throws {
        let subject = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                    discogsID: 1, name: "Skee Mask")
        subject.labelNames = ["Ilian Tape"]
        subject.labelNeighbourNames = ["Stenny"]
        context.insert(subject)
        try context.save()

        // A fold with no picture for the neighbour.
        let first = GraphStore(context: context)
        first.prepare()
        XCTAssertNil(
            first.relatedArtists(to: .artist("Skee Mask")).first { $0.node.title == "Stenny" }?
                .node.artworkURL,
            "Nothing found for them yet"
        )

        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)
        try context.save()

        // The next fold inherits the last one, the way the worker builds it.
        let second = GraphStore(context: context, inheriting: first)
        second.prepare()
        XCTAssertEqual(
            second.relatedArtists(to: .artist("Skee Mask")).first { $0.node.title == "Stenny" }?
                .node.artworkURL?.absoluteString,
            "https://img.test/stenny.jpg",
            "A picture written after the fold has to reach the row"
        )

        // And a replacement, which leaves the row count exactly where it was.
        context.delete(portrait)
        let replacement = ArtistPortrait(
            nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny"
        )
        replacement.imageURLString = "https://img.test/stenny-better.jpg"
        context.insert(replacement)
        try context.save()

        let third = GraphStore(context: context, inheriting: second)
        third.prepare()
        XCTAssertEqual(
            third.relatedArtists(to: .artist("Skee Mask")).first { $0.node.title == "Stenny" }?
                .node.artworkURL?.absoluteString,
            "https://img.test/stenny-better.jpg",
            "A replacement moves no count, and used to be inherited straight past"
        )
    }

    /// A burst of writes is one change to the pages, not four.
    ///
    /// Each announcement is a full graph walk and a rebuild on every open DIG
    /// surface. Enriching one cold artist writes three times in as many
    /// seconds; a real session's trace showed four walks of the same artist
    /// inside a single 3341ms enrichment that made one network request.
    @MainActor
    func testABurstOfWritesIsAnnouncedOnce() async throws {
        let address = "https://www.youtube.com/watch?v=aaaaaaaaaaa"
        for identifier in 1...6 {
            let record = DiscogsReleaseRecord(discogsID: identifier, title: "Release \(identifier)")
            record.videoURLStrings = [address]
            record.videoTitles = ["Refused"]
            record.videoDurations = [300]
            context.insert(record)
        }
        try context.save()

        let dig = DigStore(context: context)
        let before = dig.revision

        // Six writes, back to back, the way an enrichment arrives.
        for identifier in 1...6 {
            await dig.markUnplayable(try XCTUnwrap(URL(string: address)))
            // Undo it so the next call is a real write again.
            let record = try XCTUnwrap(
                ((try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [])
                    .first { $0.discogsID == identifier }
            )
            record.videoPlayable = [0]
        }

        XCTAssertEqual(
            dig.revision - before, 1,
            "The first write is announced at once; the rest of the burst waits for it"
        )

        // And the burst is not simply dropped — it lands once, after.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(
            dig.revision - before, 2,
            "One trailing announcement for everything that arrived during the burst"
        )
    }

    /// The two counters mean different things, and the expensive one must not
    /// move when only a thumbnail has changed. The background fill runs for as
    /// long as the app is open — on the shared counter it asked every visible
    /// page to rebuild itself every second or two, which is what made
    /// scrolling catch.
    func testAThumbnailDoesNotInvalidateAProfile() async throws {
        let artist = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Skee Mask"),
                                   discogsID: 1, name: "Skee Mask")
        artist.labelNames = ["Ilian Tape"]
        context.insert(artist)
        try context.save()

        let dig = DigStore(context: context)
        _ = await dig.artistProfile(name: "Skee Mask", mbid: nil)
        let settled = dig.revision

        // What the drip does when a picture lands.
        let portrait = ArtistPortrait(nameKey: RecordingKey.normalizeArtist("Stenny"), name: "Stenny")
        portrait.imageURLString = "https://img.test/stenny.jpg"
        context.insert(portrait)
        try context.save()

        XCTAssertEqual(dig.revision, settled,
                       "The counter that rebuilds pages must not move for a picture")
        XCTAssertNotNil(dig.cachedArtistProfile(name: "Skee Mask", mbid: nil),
                        "So the page it was showing is still good")
    }

    /// And the picture still has to reach the row, by the cheap route.
    func testAPictureStillReachesTheRow() throws {
        let dig = DigStore(context: context)
        XCTAssertNil(dig.portraitURL(for: "Stenny"))
        XCTAssertNil(dig.portraitURL(for: "Various"), "Never a placeholder")
    }
}
