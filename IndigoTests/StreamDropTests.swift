import XCTest
import AVFoundation
@testable import Indigo

/// How a live stream's dropped connection reaches `StreamAudioEngine`.
///
/// Measured against a stand-in Icecast mount (200, no length, paced at
/// realtime) with a muted AVPlayer set up as the engine sets one up:
///
///   · server closes the connection   → didPlayToEndTime, then paused
///   · server resets it mid-stream     → didPlayToEndTime, then paused
///   · server stops sending, stays open → playbackStalled, ~13s later
///                                        failedToPlayToEndTime (-16830)
///
/// Only the last was ever answered. The first two left the bar reading
/// "playing" over silence. The sandboxed test host cannot listen on a port,
/// so these tests stand a short file in for the stream: a file ending is the
/// same notification a closed connection is.
@MainActor
final class StreamDropTests: XCTestCase {
    private var engine: StreamAudioEngine!
    private var states: [StreamAudioEngine.State] = []

    override func setUp() async throws {
        engine = StreamAudioEngine()
        engine.setVolume(0)
        states = []
        engine.onStateChange = { [weak self] in
            guard let self else { return }
            self.states.append(self.engine.state)
        }
    }

    override func tearDown() async throws {
        engine.stop()
        engine = nil
    }

    /// A second of silence, written where the sandboxed host may write.
    static func shortStream(seconds: Double = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-drop-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The end of a live stream is a dropped connection, and is reconnected.
    func testAStreamThatEndsIsReconnected() async throws {
        engine.play(url: try Self.shortStream())

        await waitUntil(10) { self.states.filter { $0 == .playing }.count >= 2 }

        let playing = states.enumerated().filter { $0.element == .playing }.map(\.offset)
        XCTAssertGreaterThanOrEqual(
            playing.count, 2,
            "The stream ended and nothing reopened it; states were \(states)"
        )
        if playing.count >= 2 {
            XCTAssertTrue(
                states[playing[0]...playing[1]].contains(.buffering),
                "Reopened through buffering, as a reconnect does: \(states)"
            )
        }
    }

    /// A drop with no network waits for one instead of spending the
    /// station's chances, and reopens the moment the path comes back.
    func testADropWithNoNetworkWaitsForOne() async throws {
        let engine = StreamAudioEngine(monitorsNetwork: false)
        engine.setVolume(0)
        defer { engine.stop() }
        engine.play(url: try Self.shortStream())
        await waitUntil(5) { engine.state == .playing }
        XCTAssertEqual(engine.state, .playing)

        // The car drives into a dead zone just as the stream closes.
        engine.networkChanged(isOnline: false)
        await waitUntil(5) { engine.connections >= 2 || engine.state != .playing }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(engine.state, .buffering)
        XCTAssertEqual(engine.connections, 1, "Nothing was tried with no way to reach the station")

        engine.networkChanged(isOnline: true)
        XCTAssertEqual(engine.connections, 2, "Reopened the moment the network came back")
        await waitUntil(5) { engine.state == .playing }
        XCTAssertEqual(engine.state, .playing)
    }

    /// A station that ran out of chances while it was the network's fault
    /// is put back on when the network returns.
    func testAStationThatGaveUpAfterPlayingComesBackWithTheNetwork() async throws {
        let engine = StreamAudioEngine(
            monitorsNetwork: false, reconnect: ReconnectPolicy(limit: 1, sustainedLimit: 1)
        )
        engine.setVolume(0)
        defer { engine.stop() }
        let file = try Self.shortStream()
        engine.play(url: file)
        await waitUntil(5) { engine.state == .playing }
        // The file goes, so every reconnect fails, as on a network that has
        // a path and carries nothing.
        try FileManager.default.removeItem(at: file)
        await waitUntil(10) { if case .failed = engine.state { true } else { false } }
        guard case .failed = engine.state else { return XCTFail("Never gave up: \(engine.state)") }
        let spent = engine.connections

        engine.networkChanged(isOnline: false)
        engine.networkChanged(isOnline: true)
        XCTAssertEqual(engine.connections, spent + 1)
    }
}
