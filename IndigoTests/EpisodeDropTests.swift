import XCTest
import AVFoundation
@testable import Indigo

/// A remote episode whose connection drops on cellular.
///
/// AVPlayer reports a closed or reset connection as the item playing to its
/// end, and a stalled one as a failure. Either way the coordinator used to
/// hear "finished" or "couldn't be played" and moved the queue on, an hour
/// into a two-hour show. `LocalAudioEngine` now reopens it where it was.
///
/// The sandboxed test host cannot listen on a port, so a short file stands
/// in for the episode, and is told to be a remote one. A file that ends at
/// two seconds of a sixty-second episode is what a dropped download looks
/// like: its own length is hidden from the engine so the catalogue's is used.
@MainActor
final class EpisodeDropTests: XCTestCase {
    private var finished = 0
    private var failures: [String] = []

    override func setUp() async throws {
        finished = 0
        failures = []
    }

    private func makeEngine(
        reopen: ReconnectPolicy = LocalAudioEngine.defaultReopenPolicy,
        trustsItsOwnLength: Bool = false
    ) -> LocalAudioEngine {
        let engine = LocalAudioEngine(
            monitorsNetwork: false,
            reopen: reopen,
            reopens: { _ in true },
            itemLength: trustsItsOwnLength ? LocalAudioEngine.reportedLength : { _ in nil }
        )
        engine.setVolume(0)
        engine.onFinished = { [weak self] in self?.finished += 1 }
        engine.onFailure = { [weak self] in self?.failures.append($0) }
        return engine
    }

    /// Silence of a given length, written over `url` when one is given.
    private func episode(seconds: Double, at url: URL? = nil) throws -> URL {
        let written = try StreamDropTests.shortStream(seconds: seconds)
        guard let url else { return written }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: written)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testTheRuleForCutShort() {
        XCTAssertTrue(LocalAudioEngine.endedShort(at: 1_200, of: 3_600))
        XCTAssertFalse(LocalAudioEngine.endedShort(at: 3_595, of: 3_600), "A rounded length is not a drop")
        XCTAssertFalse(LocalAudioEngine.endedShort(at: 12, of: nil), "With no length, an end is an end")
    }

    /// The drop comes with no network. Nothing is tried until there is one,
    /// and then the episode carries on from where it was, not from the top.
    func testAnEpisodeCutShortIsReopenedWhereItDropped() async throws {
        let engine = makeEngine()
        defer { engine.stop() }
        let url = try episode(seconds: 2)
        engine.load(url: url, knownDuration: 60, autoplay: true)
        await waitUntil(5) { engine.position > 0.6 }
        XCTAssertTrue(engine.isPlaying)

        engine.networkChanged(isOnline: false)
        await waitUntil(5) { engine.isReopening }
        XCTAssertTrue(engine.isReopening, "Two seconds of sixty is a drop, not an end")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(engine.connections, 1, "Nothing was tried with no way to reach the host")
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(failures, [])
        let droppedAt = engine.position
        XCTAssertGreaterThan(droppedAt, 1.5)

        // The rest of the episode is there by the time the network is.
        _ = try episode(seconds: 4, at: url)
        engine.networkChanged(isOnline: true)
        XCTAssertEqual(engine.connections, 2, "Reopened the moment the network came back")
        await waitUntil(5) { !engine.isReopening }
        XCTAssertFalse(engine.isReopening)
        XCTAssertGreaterThan(engine.position, droppedAt, "Carried on from the drop, not the top")
        XCTAssertTrue(engine.isPlaying)

        // Four seconds is still short of sixty, so the engine looks once
        // more, finds nothing past the end, and believes it.
        await waitUntil(8) { self.finished > 0 }
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(failures, [])
        XCTAssertEqual(engine.connections, 3)
    }

    /// An episode that runs to its length is finished, and nothing reopens it.
    func testAnEpisodeThatRunsToItsLengthFinishes() async throws {
        let engine = makeEngine(trustsItsOwnLength: true)
        defer { engine.stop() }
        engine.load(url: try episode(seconds: 1), knownDuration: nil, autoplay: true)
        await waitUntil(5) { self.finished > 0 }
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(engine.connections, 1)
        XCTAssertFalse(engine.isReopening)
    }

    /// When the host stays gone, a few tries and then the coordinator is told,
    /// once, so it can move on.
    func testAnEpisodeThatCannotBeReopenedIsReportedOnce() async throws {
        let engine = makeEngine(reopen: ReconnectPolicy(limit: 0, sustainedLimit: 2))
        defer { engine.stop() }
        let url = try episode(seconds: 2)
        engine.load(url: url, knownDuration: 60, autoplay: true)
        await waitUntil(5) { engine.position > 0.6 }
        try FileManager.default.removeItem(at: url)

        await waitUntil(10) { !self.failures.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(failures.count, 1, "One failure, however many observers saw it: \(failures)")
        XCTAssertEqual(engine.connections, 3, "The first open and two reopens")
        XCTAssertEqual(finished, 0)
        XCTAssertFalse(engine.isReopening)
    }

    /// Something that never played is not a dropped connection: it fails at
    /// once, so the coordinator's mirror is tried without a wait.
    func testAnEpisodeThatNeverPlayedIsNotRetried() async throws {
        let engine = makeEngine()
        defer { engine.stop() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("episode-drop-missing-\(UUID().uuidString).caf")
        engine.load(url: missing, knownDuration: 60, autoplay: true)
        await waitUntil(5) { !self.failures.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(engine.connections, 1)
    }

    /// The coordinator shows a reopening episode as on and buffering, and
    /// skips it only once the engine has given up.
    func testTheQueueMovesOnOnlyOnceReopeningHasFailed() async throws {
        let engine = LocalAudioEngine(
            monitorsNetwork: false,
            reopen: ReconnectPolicy(limit: 0, sustainedLimit: 2),
            reopens: { _ in true },
            itemLength: { _ in nil }
        )
        let player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "episode-drop-test")!, local: engine)
        player.setVolume(0)
        defer { player.stopAll() }
        let first = try episode(seconds: 2)
        let second = try episode(seconds: 30)
        player.play([
            MediaItem(id: "probe.a", sourceID: "probe", kind: .episode, title: "A",
                      playbackURL: first, duration: 60),
            MediaItem(id: "probe.b", sourceID: "probe", kind: .episode, title: "B",
                      playbackURL: second, duration: 30),
        ])
        await waitUntil(5) { engine.position > 0.6 }

        engine.networkChanged(isOnline: false)
        await waitUntil(5) { engine.isReopening }
        XCTAssertEqual(player.current?.id, "probe.a", "A drop is not a reason to skip")
        XCTAssertTrue(player.isPlaying, "Still on, so pause pauses it")
        XCTAssertTrue(player.isBuffering)
        XCTAssertNil(player.notice)

        try FileManager.default.removeItem(at: first)
        engine.networkChanged(isOnline: true)
        await waitUntil(10) { player.current?.id == "probe.b" }
        XCTAssertEqual(player.current?.id, "probe.b")
        XCTAssertNotNil(player.notice)
    }
}
