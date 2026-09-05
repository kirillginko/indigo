//
//  StorePredicateTests.swift
//  IndigoTests
//
//  Every other test in this suite builds its container with
//  `isStoredInMemoryOnly: true`, and an in-memory store answers a
//  `#Predicate` by running it as Swift. The app's store is SQLite, which has
//  to translate the same predicate into a query — and a predicate it cannot
//  translate does not fail the way a Swift closure does.
//
//  So these run on disk. What they are checking is not the answer so much as
//  that asking is survivable.
//

import XCTest
import SwiftData
@testable import Indigo

final class StorePredicateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("indigo-predicates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: Persistence.schema, url: directory.appendingPathComponent("store.sqlite")
        )
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Whether a big read on the worker's context makes the main context's
    /// small reads wait.
    ///
    /// This is the standing theory for the stalls that survive every fix: the
    /// worker holds its own `ModelContext`, but both contexts talk to one
    /// SQLite store, and `graph.tables` reads six tables whole every time a
    /// write invalidates the fold. If that blocks the main context, no amount
    /// of moving work to the worker helps — the main thread waits anyway, and
    /// nothing on it is slow enough to appear in the trace.
    func testWhetherABigBackgroundReadBlocksTheMainContext() async throws {
        for index in 0..<20000 {
            context.insert(Track(
                path: "/Music/track-\(index).flac", relativePath: "track-\(index).flac",
                title: "Track \(index)", artist: "Artist \(index % 500)",
                albumArtist: "Artist \(index % 500)", album: "Record \(index % 900)",
                genre: "Techno", trackNumber: index % 12, discNumber: 1, year: 2018,
                duration: 300, fileModified: Date(), fileSize: 1000,
                artworkKey: nil, scanGeneration: 1
            ))
        }
        try context.save()

        func smallReadMilliseconds(_ context: ModelContext) -> Int {
            let path = "/Music/track-17.flac"
            var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
            descriptor.fetchLimit = 1
            let started = ContinuousClock.now
            _ = try? context.fetch(descriptor)
            let parts = (ContinuousClock.now - started).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }

        let quiet = (0..<20).map { _ in smallReadMilliseconds(context) }.max() ?? 0

        // The same small read, while another context reads the table whole on
        // the cooperative pool — which is exactly what the worker does.
        let container = self.container!
        let reader = Task.detached {
            let theirs = ModelContext(container)
            for _ in 0..<12 { _ = (try? theirs.fetch(FetchDescriptor<Track>())) ?? [] }
        }
        var contended = 0
        while !reader.isCancelled, !Task.isCancelled {
            contended = max(contended, smallReadMilliseconds(context))
            if reader.isCancelled { break }
            if contended > 2000 { break }
            if await withTaskGroup(of: Bool.self, body: { group -> Bool in
                group.addTask { await reader.value; return true }
                group.addTask { try? await Task.sleep(for: .milliseconds(1)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }) { break }
        }
        await reader.value

        print("BENCH main-context small read: quiet \(quiet)ms, contended \(contended)ms")
        XCTAssertLessThan(
            contended, max(quiet * 4, 60),
            "A read on another context stalls this one — moving work to the worker cannot fix that"
        )
    }

    /// `CrateService.genres(atPaths:)` and `DigStore.backfillLocalTrack`.
    func testFetchingTracksByPath() throws {
        for index in 0..<5 {
            context.insert(Track(
                path: "/Music/track-\(index).flac", relativePath: "track-\(index).flac",
                title: "Track \(index)", artist: "Artist", albumArtist: "Artist",
                album: "Record", genre: index == 0 ? "" : "Techno", trackNumber: index,
                discNumber: 1, year: 2018, duration: 300, fileModified: Date(),
                fileSize: 1000, artworkKey: nil, scanGeneration: 1
            ))
        }
        try context.save()

        let paths = ["/Music/track-1.flac", "/Music/track-3.flac"]
        let byPath = FetchDescriptor<Track>(predicate: #Predicate { paths.contains($0.path) })
        XCTAssertEqual(try context.fetch(byPath).map(\.path).sorted(), paths)
    }

    /// `DigStore.backfillLocalGenres(artistName:genres:)`.
    func testFetchingTracksWithNoGenre() throws {
        for index in 0..<5 {
            context.insert(Track(
                path: "/Music/track-\(index).flac", relativePath: "track-\(index).flac",
                title: "Track \(index)", artist: "Artist", albumArtist: "Artist",
                album: "Record", genre: index == 0 ? "" : "Techno", trackNumber: index,
                discNumber: 1, year: 2018, duration: 300, fileModified: Date(),
                fileSize: 1000, artworkKey: nil, scanGeneration: 1
            ))
        }
        try context.save()

        // `isEmpty` is the natural spelling and answers with nothing here,
        // silently — no error, no crash, just an empty result and a backfill
        // that never runs.
        let byIsEmpty = FetchDescriptor<Track>(predicate: #Predicate { $0.genre.isEmpty })
        XCTAssertEqual(
            try context.fetch(byIsEmpty).count, 0,
            "If this ever starts working, the note in DigStore can go"
        )

        let ungenred = FetchDescriptor<Track>(predicate: #Predicate { $0.genre == "" })
        XCTAssertEqual(try context.fetch(ungenred).map(\.path), ["/Music/track-0.flac"])
    }

    /// `DigArtwork.discogsRelease`.
    func testFetchingAReleaseByTitle() throws {
        for index in 0..<5 {
            context.insert(DiscogsReleaseRecord(discogsID: index, title: "Release \(index)"))
        }
        try context.save()

        let title = "Release 3"
        let byTitle = FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.title == title })
        XCTAssertEqual(try context.fetch(byTitle).map(\.title), [title])
    }

    /// `GraphStore.Caches` reading only the portraits written since it last
    /// looked. A `Date` comparison is not one of the shapes I would assume
    /// works against SQLite without asking.
    func testFetchingPortraitsWrittenSinceAMoment() throws {
        let old = ArtistPortrait(nameKey: "early", name: "Early")
        old.fetchedAt = Date(timeIntervalSince1970: 1000)
        context.insert(old)
        let cutoff = Date(timeIntervalSince1970: 2000)
        let new = ArtistPortrait(nameKey: "late", name: "Late")
        new.fetchedAt = Date(timeIntervalSince1970: 3000)
        context.insert(new)
        try context.save()

        let since = cutoff
        let descriptor = FetchDescriptor<ArtistPortrait>(
            predicate: #Predicate { $0.fetchedAt > since }
        )
        XCTAssertEqual(try context.fetch(descriptor).map(\.nameKey), ["late"])
    }

    /// `GraphStore.portraitURLs(forKeys:)`, which the stored-edge lookup uses
    /// instead of assembling the fold.
    func testFetchingPortraitsByName() throws {
        for index in 0..<5 {
            let portrait = ArtistPortrait(
                nameKey: RecordingKey.normalizeArtist("Artist \(index)"), name: "Artist \(index)"
            )
            portrait.imageURLString = "https://example.test/\(index).jpg"
            context.insert(portrait)
        }
        try context.save()

        let wanted = [RecordingKey.normalizeArtist("Artist 1"), RecordingKey.normalizeArtist("Artist 4")]
        let descriptor = FetchDescriptor<ArtistPortrait>(
            predicate: #Predicate { wanted.contains($0.nameKey) }
        )
        XCTAssertEqual(try context.fetch(descriptor).map(\.nameKey).sorted(), wanted.sorted())
    }

    /// `BandcampEnricher.cachedReleases(forArtist:)` reads the table and
    /// filters it here, which looks like something worth turning into a
    /// query. It is not: `artistKeys` is a plain `[String]` attribute rather
    /// than a relationship, so the store keeps it as one opaque value and a
    /// predicate naming it takes the process down — not throws, down. This
    /// test holds the shape that works.
    func testFetchingABandcampReleaseByCreditedArtist() throws {
        let solo = BandcampRelease(
            urlString: "https://a.bandcamp.com/album/one", title: "One",
            artistName: "Space Afrika"
        )
        let joint = BandcampRelease(
            urlString: "https://a.bandcamp.com/album/two", title: "Two",
            artistName: "Rainy Miller x Space Afrika"
        )
        context.insert(solo)
        context.insert(joint)
        try context.save()

        XCTAssertEqual(
            BandcampEnricher(context: context)
                .cachedReleases(forArtist: "Space Afrika").map(\.title).sorted(),
            ["One", "Two"]
        )
    }
}
