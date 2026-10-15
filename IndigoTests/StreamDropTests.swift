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
}
