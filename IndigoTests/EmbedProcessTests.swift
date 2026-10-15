import XCTest
@testable import Indigo

/// iOS ends a background app's web processes when it wants the memory. The
/// embed engine's bridge went with the process and nothing noticed, so an
/// archived episode could not be played again until the app was relaunched.
@MainActor
final class EmbedProcessTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testALostWebProcessReloadsTheBridgeAndTheEpisode() async {
        let engine = EmbedAudioEngine()
        engine.setVolume(0)
        defer { engine.stop() }
        engine.load(
            provider: .soundcloud,
            url: URL(string: "https://soundcloud.com/example/episode")!,
            autoplay: false
        )
        XCTAssertEqual(engine.bridgeLoads, 1)

        engine.webViewWebContentProcessDidTerminate(engine.webView)
        await waitUntil(5) { engine.bridgeLoads == 2 }

        XCTAssertEqual(engine.bridgeLoads, 2, "The bridge page was loaded again")
        XCTAssertEqual(engine.state, .loading, "And the episode put back on it")
    }

    func testNothingIsReloadedWhenNothingWasOn() async {
        let engine = EmbedAudioEngine()
        engine.webViewWebContentProcessDidTerminate(engine.webView)
        await waitUntil(5) { engine.bridgeLoads == 2 }
        XCTAssertEqual(engine.bridgeLoads, 2)
        XCTAssertEqual(engine.state, .idle)
    }

    /// Lost again in the middle of recovering: what is restored is what the
    /// listener had, not the half-recovered loading state.
    func testASecondLossRestoresWhatTheListenerHad() async {
        let engine = EmbedAudioEngine()
        defer { engine.stop() }
        engine.load(
            provider: .soundcloud,
            url: URL(string: "https://soundcloud.com/example/episode")!,
            autoplay: false
        )
        engine.webViewWebContentProcessDidTerminate(engine.webView)
        await waitUntil(5) { engine.bridgeLoads == 2 }
        XCTAssertEqual(engine.recovery?.autoplay, false, "Not asked to play, so not played")

        engine.webViewWebContentProcessDidTerminate(engine.webView)
        await waitUntil(5) { engine.bridgeLoads == 3 }
        XCTAssertEqual(engine.recovery?.autoplay, false, "Still what the listener had")
        XCTAssertEqual(engine.state, .loading)
    }

    func testAPlayingEpisodeIsPutBackPlaying() async {
        let engine = EmbedAudioEngine()
        defer { engine.stop() }
        engine.load(
            provider: .soundcloud,
            url: URL(string: "https://soundcloud.com/example/episode")!,
            autoplay: true
        )
        engine.webViewWebContentProcessDidTerminate(engine.webView)
        await waitUntil(5) { engine.bridgeLoads == 2 }
        XCTAssertEqual(engine.recovery?.autoplay, true)

        engine.load(
            provider: .soundcloud,
            url: URL(string: "https://soundcloud.com/example/other")!,
            autoplay: false
        )
        XCTAssertNil(engine.recovery, "A load the listener asked for starts afresh")
    }
}
