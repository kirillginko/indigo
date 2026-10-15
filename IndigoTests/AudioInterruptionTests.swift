import XCTest
@testable import Indigo

/// iOS pauses every player when a call or Siri takes the audio session, and
/// says so only through `AVAudioSession`. Nothing listened: the station read
/// "playing" through the call and afterwards, silent. These drive the
/// coordinator's answers directly, since the session does not exist on the
/// Mac the tests run on.
@MainActor
final class AudioInterruptionTests: XCTestCase {
    private var player: PlaybackCoordinator!
    private var stream: URL!

    override func setUp() async throws {
        player = PlaybackCoordinator(defaults: UserDefaults(suiteName: "interruption-test")!)
        player.setVolume(0)
        stream = try StreamDropTests.shortStream(seconds: 30)
        player.playRadio(MediaItem(
            id: "probe.live", sourceID: "probe", kind: .radioStation, title: "Probe",
            playbackURL: stream
        ))
        await waitUntil(5) { self.player.isPlaying && !self.player.isBuffering }
        XCTAssertTrue(player.isPlaying)
    }

    override func tearDown() async throws {
        player.stopAll()
        player = nil
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testACallPausesTheStationAndItPlaysOnAfterwards() async {
        player.audioInterruptionBegan()
        XCTAssertFalse(player.isPlaying, "The bar says what the speaker is doing")

        player.audioInterruptionEnded(shouldResume: true)
        await waitUntil(5) { self.player.isPlaying && !self.player.isBuffering }
        XCTAssertTrue(player.isPlaying && !player.isBuffering, "Back on after the call")
    }

    /// Another app started its own music: it keeps the speaker.
    func testItStaysPausedWhenTheSystemSaysNotToResume() {
        player.audioInterruptionBegan()
        player.audioInterruptionEnded(shouldResume: false)
        XCTAssertFalse(player.isPlaying)
    }

    /// Paused by the listener before the call, paused after it.
    func testAStationPausedBeforeTheCallStaysPaused() {
        player.pause()
        player.audioInterruptionBegan()
        player.audioInterruptionEnded(shouldResume: true)
        XCTAssertFalse(player.isPlaying)
    }

    func testLosingTheCarOrHeadphonesPauses() {
        player.audioRouteLost()
        XCTAssertFalse(player.isPlaying)
    }
}
