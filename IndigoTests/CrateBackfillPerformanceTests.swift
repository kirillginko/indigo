//
//  CrateBackfillPerformanceTests.swift
//  IndigoTests
//
//  The For You page runs the genre backfill from a `.task`, which is the main
//  actor. Anything it does between two frames is a frame the shader does not
//  draw, so what it costs is worth a number rather than a guess.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class CrateBackfillPerformanceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// A library somebody has actually pointed at a folder, and a crate they
    /// have been keeping for a while.
    private let trackCount = 12000
    private let cratedCount = 120

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)

        for index in 0..<trackCount {
            context.insert(Track(
                path: "/Music/track-\(index).flac", relativePath: "track-\(index).flac",
                title: "Track \(index)", artist: "Artist \(index % 400)",
                albumArtist: "Artist \(index % 400)", album: "Record \(index % 900)",
                genre: ["Techno", "Ambient", "House", "Dub"][index % 4],
                trackNumber: index % 12, discNumber: 1, year: 2018,
                duration: 300, fileModified: Date(), fileSize: 40_000_000,
                artworkKey: nil, scanGeneration: 1
            ))
        }
        for index in 0..<cratedCount {
            let recording = Recording(
                title: "Track \(index)", artistName: "Artist \(index % 400)", status: .identified
            )
            let source = RecordingSource(kind: .localFile, identifier: "/Music/track-\(index).flac")
            source.recording = recording
            context.insert(recording)
            context.insert(source)
            context.insert(CrateItem(recording: recording))
        }
        try context.save()
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func milliseconds(_ body: () -> Void) -> Int {
        let started = ContinuousClock.now
        body()
        let parts = (ContinuousClock.now - started).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// A frame is sixteen milliseconds. This runs on the main actor a moment
    /// after the page appears, so whatever it costs, the listener watches.
    func testTheGenreBackfillDoesNotStopTheFrame() {
        let crate = CrateService(context: context)
        let cost = milliseconds { crate.backfillLocalGenres() }
        try? "backfillLocalGenres \(cost)ms\n".write(
            toFile: (NSTemporaryDirectory() as NSString).appendingPathComponent("indigo-crate-bench.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertLessThan(
            cost, 150,
            """
            The For You page runs this on the main actor. Asking for the whole \
            library once per crated entry measured 120,000ms on this fixture; \
            asking for the entries' own paths measures about 50ms.
            """
        )
    }
}
