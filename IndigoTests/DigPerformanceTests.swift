//
//  DigPerformanceTests.swift
//  IndigoTests
//
//  A store big enough to be worth measuring, and a stopwatch on the two
//  things a page actually waits for: reading the tables, and walking them.
//
//  Written because "it feels slow" and a log full of milliseconds are not the
//  same as a number that moves when you change something. This one can be run
//  before and after, by anybody, without opening the app.
//

import XCTest
import OSLog
import SwiftData
@testable import Indigo

@MainActor
final class DigPerformanceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// Roughly the shape of a store somebody has been digging in for a while.
    // Sized from a real session's trace rather than guessed. At 800 artists
    // a walk measured 19ms here while the running app was averaging 1092ms —
    // the benchmark was too small to reproduce the thing it existed to
    // measure, which is how an "optimisation" that changed nothing got
    // shipped as a fix.
    private let artistCount = 5000
    private let trackCount = 4000
    private let recordingCount = 1500
    private let portraitCount = 3000

    /// Results are written to a file rather than logged.
    ///
    /// A test host's `print` never reaches xcodebuild and its `Logger` lines
    /// do not reach the system log either, so a benchmark nobody can read is
    /// a benchmark nobody will run twice.
    private func record(_ line: String) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("indigo-bench.txt")
        let stamped = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private let styles = ["Techno", "Ambient", "House", "Electro", "Dub", "Jungle"]
    private let labels = ["Ilian Tape", "Warp", "Hessle Audio", "Sferic", "Dais", "Bandulu"]

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        try seed()
    }

    override func tearDown() {
        Trace.flush()
        context = nil
        container = nil
    }

    private func seed() throws {
        for index in 0..<artistCount {
            let name = "Artist \(index)"
            let record = DiscogsArtist(
                nameKey: RecordingKey.normalizeArtist(name), discogsID: index + 1, name: name
            )
            // Everybody shares an imprint and a style with somebody, the way
            // a real cache does — otherwise the walk has nothing to compare.
            record.labelNames = [labels[index % labels.count]]
            record.styles = [styles[index % styles.count]]
            record.releaseTitles = ["Record \(index)A", "Record \(index)B"]
            record.releaseYears = ["2018", "2021"]
            record.releaseDiscogsIDs = [index * 2, index * 2 + 1]
            record.releaseImageURLStrings = ["", ""]
            record.releaseThumbnailURLStrings = ["", ""]
            record.releaseLabels = [labels[index % labels.count], ""]
            context.insert(record)
        }

        // The table the profile builder scans in full, which the benchmark
        // was missing entirely — and so measured 19ms where the running app
        // measured 1092ms.
        for index in 0..<4000 {
            let release = DiscogsReleaseRecord(discogsID: 100_000 + index, title: "Release \(index)")
            release.artistNames = ["Artist \(index % artistCount)", "Various"]
            release.labelNames = [labels[index % labels.count]]
            context.insert(release)
        }

        for index in 0..<recordingCount {
            let recording = Recording(
                title: "Track \(index)",
                artistName: "Artist \(index % artistCount)",
                status: .identified
            )
            context.insert(recording)
            let entry = RecordingMetadata(recordingID: recording.id)
            entry.labelName = labels[index % labels.count]
            context.insert(entry)
        }

        // The table the running app grows all session and the benchmark did
        // not have at all.
        //
        // The background portrait fill writes one of these every second and a
        // half for as long as the app is open. Two full reads of it were
        // happening per walk — one in the fold, one in the stored-edge
        // lookup — and neither was measured here, because the seed created
        // none. That is how 178ms a walk stayed invisible through a round of
        // "optimisation".
        for index in 0..<portraitCount {
            let portrait = ArtistPortrait(
                nameKey: RecordingKey.normalizeArtist("Artist \(index)"),
                name: "Artist \(index)"
            )
            portrait.imageURLString = "https://img.discogs.com/artist-\(index).jpg"
            context.insert(portrait)
        }

        for index in 0..<trackCount {
            context.insert(Track(
                path: "/music/\(index).flac",
                relativePath: "\(index).flac",
                title: "Local \(index)",
                artist: "Artist \(index % artistCount)",
                albumArtist: "Artist \(index % artistCount)",
                album: "Album \(index % 400)",
                genre: "Electronic",
                trackNumber: 1,
                discNumber: 1,
                year: 2020,
                duration: 300,
                fileModified: Date(),
                fileSize: 1024,
                artworkKey: nil,
                scanGeneration: 1
            ))
        }
        try context.save()
    }

    private func milliseconds(_ body: () -> Void) -> Int {
        let started = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - started
        let parts = elapsed.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Reading the seven tables, which is what every write makes the next
    /// page do again.
    /// The scan behind the way into DIG.
    ///
    /// The landing page works its starting points out of every crate item and
    /// every track in the library. It was doing that inside `body`, so it ran
    /// on every redraw — every hover, and every time enrichment wrote a row
    /// anywhere. Half a second, repeatedly, for an answer that had not changed.
    ///
    /// Split three ways because "the scan is slow" is not actionable: what is
    /// wanted is whether the time is in SwiftData or in the normaliser, and
    /// those have completely different fixes.
    func testCostOfTheLibraryScanBehindTheDigPage() {
        var counted = 0
        let fetchOnly = milliseconds {
            counted = ((try? context.fetch(FetchDescriptor<Track>())) ?? []).count
        }

        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var keys = 0
        let normalising = milliseconds {
            for track in tracks { keys += DigEngine.artistKeys(for: track).count }
        }

        // The stored column, which the importer already normalised once.
        var stored = 0
        let storedCost = milliseconds {
            for track in tracks where !track.artistKey.isEmpty { stored += 1 }
        }

        record("dig start: fetch \(fetchOnly)ms, normalise \(normalising)ms, "
               + "stored-key read \(storedCost)ms over \(counted) tracks")

        XCTAssertGreaterThan(counted, 0)
        XCTAssertGreaterThan(keys, 0)
        XCTAssertGreaterThan(stored, 0)
    }

    func testCostOfReadingTheTables() {
        var built = 0
        let cost = milliseconds {
            let graph = GraphStore(context: context)
            // `compute` is what forces the caches to be assembled.
            built = graph.compute(.artist("Artist 0")).edges.count
        }
        record("tables+walk(cold) \(cost)ms \(built) edges")
        XCTAssertGreaterThanOrEqual(built, 0)
    }

    /// The walk itself, with the tables already in hand — which is the part
    /// that grows with how much has been dug into.
    func testCostOfWalkingWithTablesWarm() {
        let graph = GraphStore(context: context)
        _ = graph.compute(.artist("Artist 0"))

        var total = 0
        let cost = milliseconds {
            for index in 1...40 {
                total += graph.compute(.artist("Artist \(index)")).edges.count
            }
        }
        record("walk(warm) x40 \(cost)ms total, \(cost / 40)ms each, \(total) edges")
        XCTAssertGreaterThan(total, 0)
        // Sized to this seed — five thousand artists and four thousand
        // records, which is what the running app's trace looks like.
        //
        // The walk visited every artist in the store and asked each whether
        // it had anything in common with the subject: 242ms, almost all of it
        // spent deciding "no". Started from the subject's own imprints and
        // styles instead, and cut to what a page can show, it is 64ms. The
        // bound catches that sweep coming back, not ordinary variation.
        XCTAssertLessThan(
            cost / 40, 140,
            "A warm walk must not drift back into the hundreds of milliseconds"
        )
    }

    /// The whole design rests on this being true.
    ///
    /// `DigWorker` exists so the graph is walked somewhere other than the
    /// main thread. Sampling the running app found its work — `Caches.init`,
    /// `DeepCaches.init`, the walk itself — executing on the main thread
    /// during a scroll, which would make the type a comment rather than a
    /// mechanism.
    func testTheWorkerActuallyLeavesTheMainThread() async throws {
        let worker = DigWorker(modelContainer: container)
        let offMain = await worker.runsOffTheMainThread()
        XCTAssertTrue(
            offMain,
            "The graph must not be walked on the thread that is drawing the page"
        )
    }

    /// What one redraw of the connection lanes costs.
    ///
    /// Every write during a page load moves `revision`, which re-runs the
    /// page's `body` — while somebody is scrolling it. Six lanes of twelve
    /// is seventy-two rows, and each row's `body` reads `why` twice: once
    /// for the sentence under the name, once for the confidence mark.
    func testCostOfRedrawingTheConnectionLanes() {
        let kinds: [RelationshipKind] = [.sharedLabel, .sharedStyle, .sameEra, .collaborator]
        let peers: [RelatedArtist] = (0..<72).map { index in
            RelatedArtist(
                name: "Peer \(index)",
                mbid: nil,
                reasons: kinds.enumerated().map { offset, kind in
                    Relationship(
                        kind: kind, source: .discogs,
                        detail: "Both release on Imprint \(offset)",
                        confidence: 0.5 + Double(offset) / 10
                    )
                }
            )
        }

        let cost = milliseconds {
            for peer in peers {
                // Twice, exactly as the row's body reads it.
                _ = WhyThis(reasons: peer.reasons)?.summary(limit: 3)
                _ = WhyThis(reasons: peer.reasons)?.confidence
            }
        }
        record("laneRedraw 72 rows \(cost)ms")
        XCTAssertLessThan(
            cost, 8,
            "Redrawing the lanes happens inside a frame; it cannot cost one"
        )
    }

    /// What one pass of `body` costs.
    ///
    /// Scrolling re-evaluates a view's `body`, and the artist page asks the
    /// crate whether this artist is in it every time. Anything measured here
    /// happens between two frames — sixteen milliseconds — so it is the
    /// budget a scroll actually has.
    func testCostOfTheCrateLookupsAViewMakes() throws {
        for index in 0..<200 {
            context.insert(CrateItem(
                digKind: .artist,
                providerID: "dig.artist.name",
                entityID: "artist-\(index)",
                title: "Artist \(index)",
                subtitle: nil,
                artworkURL: nil
            ))
        }
        try context.save()
        let crate = CrateService(context: context)

        // Sixty passes is a second of scrolling at sixty frames.
        let cost = milliseconds {
            for index in 0..<60 {
                _ = crate.contains(
                    dig: .artist,
                    identifier: "artist-\(index % 200)",
                    providerID: "dig.artist.name"
                )
            }
        }
        record("crateLookup x60 \(cost)ms total, \(Double(cost) / 60.0)ms each")
        XCTAssertLessThan(
            cost, 60,
            "A crate lookup happens inside body; sixty of them must not cost a second"
        )
    }

    /// What a write costs the next page.
    ///
    /// Every write bumps the revision, which throws the graph's caches away,
    /// so the next thing to ask a question rebuilds them. A page does that
    /// three to five times while it loads — which is why a big catalogue,
    /// which writes more, stutters more.
    func testCostOfRebuildingAfterAWrite() {
        // The second build inherits the first's tables, which is what
        // `DigWorker` does on every generation — building two unrelated
        // stores measured the old path, not the one the app takes.
        let one = GraphStore(context: context)
        let first = milliseconds { _ = one.compute(.artist("Artist 0")) }
        let two = GraphStore(context: context, inheriting: one)
        let second = milliseconds { _ = two.compute(.artist("Artist 0")) }
        record("cacheBuild first \(first)ms, again \(second)ms")
        // A rebuild used to re-read every table: two and a half seconds, and
        // a session does sixty of them. Inheriting the rows it can — and the
        // shapes and credit folds derived from them — proves out at 113ms, so
        // the bound is set where a regression would show rather than where
        // the old behaviour would still pass.
        XCTAssertLessThan(
            second, 350,
            "A rebuild after a write must not re-read tables that did not change"
        )
    }

    /// The path a page actually takes, which is not the one `compute`
    /// measures.
    ///
    /// `neighbors` is what `relatedArtists` calls: it looks for a stored
    /// answer, walks when there is none, and writes what it found. The
    /// benchmark only ever measured the walk, so the reading and the writing
    /// around it — a fetch of every portrait on one side, a few thousand row
    /// inserts and a save on the other — were never in a number anybody
    /// looked at.
    func testCostOfTheWalkThePageActuallyAsksFor() {
        let graph = GraphStore(context: context)
        _ = graph.compute(.artist("Artist 0"))

        var edges = 0
        let cold = milliseconds {
            edges = graph.neighbors(of: .artist("Artist 1")).edges.count
        }
        let warm = milliseconds {
            _ = graph.neighbors(of: .artist("Artist 1")).edges.count
        }
        record("neighbors(first) \(cold)ms \(edges) edges, (stored) \(warm)ms")
        XCTAssertGreaterThan(edges, 0)
        // Reading a stored answer used to fetch the whole portrait table to
        // patch thumbnails into it — a table that grows all session. It reads
        // the fold now, and a stored answer must stay much cheaper than
        // working one out, or there is no point keeping it.
        XCTAssertLessThan(
            warm, max(cold / 2, 60),
            "Reading a kept answer must not cost what working it out costs"
        )
    }

    /// How much of the walk the page can use.
    ///
    /// The lanes show twelve rows each across six lanes. Everything past that
    /// is built, sorted, written to the store and read back so it can be
    /// thrown away by a `prefix`.
    func testTheWalkDoesNotBuildFarMoreThanThePageCanShow() {
        let graph = GraphStore(context: context)
        let peers = graph.relatedArtists(to: .artist("Artist 0"))
        record("relatedArtists \(peers.count) peers for 72 rows")
        XCTAssertLessThan(
            peers.count, 400,
            "A page shows seventy-two peers; building thousands is work nobody sees"
        )
    }

    /// What one edge costs to build.
    ///
    /// `link` runs once per neighbour per reason — nine hundred times for one
    /// artist — and the first thing it does is ask whether the name is a
    /// joint credit. Almost every name is just a name, so whatever that
    /// question costs is paid nine hundred times to answer "no".
    func testCostOfDecidingAPlainNameIsAPlainName() {
        let names = (0..<900).map { "Artist \($0)" }
        var total = 0
        let cost = milliseconds {
            for name in names { total += DiscogsClient.creditedNames(name).count }
        }
        record("creditedNames x900 \(cost)ms, \(total) names")
        XCTAssertEqual(total, 900)
        XCTAssertLessThan(
            cost, 40,
            "Deciding a plain name is plain happens nine hundred times a walk"
        )

        // The other question asked of every name, and the one that costs.
        // Folding a credit runs nine case-insensitive searches for a
        // collaboration marker before it normalises anything, and `link` used
        // to ask for the same name three times over — once for the key, once
        // for the key it might be stored under, once inside the node.
        var keys = 0
        let folding = milliseconds {
            for name in names { keys += RecordingKey.normalizeArtist(name).count }
        }
        record("normalizeArtist x900 \(folding)ms")
        XCTAssertGreaterThan(keys, 0)
    }

    /// What digging into somebody new costs the page.
    ///
    /// This is the write the cold path actually makes: enrichment inserts one
    /// artist row. The rebuild above measures a store nothing was written to,
    /// which is the easy case — a changed row count used to discard every
    /// table, so learning one artist meant re-reading the releases, the
    /// recordings and the metadata that had not moved.
    func testCostOfRebuildingAfterDiggingIntoSomebodyNew() throws {
        let one = GraphStore(context: context)
        _ = one.compute(.artist("Artist 0"))

        let newcomer = DiscogsArtist(
            nameKey: RecordingKey.normalizeArtist("Space Afrika"),
            discogsID: 999_999, name: "Space Afrika"
        )
        newcomer.labelNames = ["Sferic"]
        newcomer.styles = ["Ambient"]
        newcomer.releaseYears = ["2020"]
        context.insert(newcomer)
        try context.save()

        let two = GraphStore(context: context, inheriting: one)
        let cost = milliseconds { _ = two.compute(.artist("Artist 0")) }
        record("cacheBuild after one new artist \(cost)ms")
        // The artist table genuinely has to be read again — a row was added to
        // it. The releases, recordings and metadata did not change, and used
        // to be discarded along with it.
        XCTAssertLessThan(
            cost, 1500,
            "One new artist must not cost a re-read of every table in the store"
        )
    }

    /// The whole answer a page waits for.
    func testCostOfAnArtistProfile() {
        let cost = milliseconds {
            _ = DigEngine(context: context).artistProfile(name: "Artist 0", mbid: nil)
        }
        record("artistProfile(cold) \(cost)ms")
        XCTAssertGreaterThan(cost, -1)
    }

    /// What each write during a load costs the page.
    ///
    /// A cold artist is not one answer but five or six: the name, the
    /// portrait, the discography, the neighbourhood, then a batch of sleeves
    /// at a time. Every one of them moves `revision`, and the page reads the
    /// profile again. With the tables already in hand this is what the
    /// listener pays per burst — and it happens while they are scrolling.
    func testCostOfRereadingAProfileMidLoad() {
        let graph = GraphStore(context: context)
        let engine = DigEngine(context: context, graph: graph)
        _ = engine.artistProfile(name: "Artist 0", mbid: nil)

        var cost = 0
        cost = milliseconds {
            for index in 0..<5 {
                _ = engine.artistProfile(name: "Artist \(index)", mbid: nil)
            }
        }
        record("artistProfile(warm) x5 \(cost)ms total, \(cost / 5)ms each")
        // 775ms when the profile answered its own questions with a table scan
        // apiece — every recording filtered by a folded credit, every track in
        // the library folded twice, the crate walked per artist. Read from the
        // fold the graph had already built, 159ms.
        XCTAssertLessThan(
            cost / 5, 280,
            "A page re-reads its profile on every write; that cannot cost half a second"
        )
    }
}
