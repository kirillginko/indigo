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

    // MARK: - Switching shows

    private let episode = URL(string: "https://soundcloud.com/example/episode")!

    /// The outgoing widget's last progress tick, arriving after the next show
    /// was put on, used to make that show read "playing" before it had made
    /// a sound.
    func testTheOutgoingShowsMessagesAreNotTakenForTheNewOne() {
        let engine = EmbedAudioEngine()
        defer { engine.stop() }
        engine.load(provider: .soundcloud, url: episode, autoplay: false)
        let outgoing = engine.generation
        engine.load(provider: .youtube, url: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!, autoplay: false)

        engine.handle(event: "progress", generation: outgoing, position: 1200, duration: 3600, detail: nil)
        engine.handle(event: "play", generation: outgoing, position: nil, duration: 3600, detail: nil)
        XCTAssertEqual(engine.state, .loading, "Still loading: nothing about this show has been heard")
        XCTAssertEqual(engine.duration, 0, "Nor its length taken from the last one")

        engine.handle(event: "play", generation: engine.generation, position: nil, duration: 240, detail: nil)
        XCTAssertEqual(engine.state, .playing)
        XCTAssertEqual(engine.duration, 240)
    }

    /// Stopped for a station: the widget's farewell does not wake it.
    func testAStoppedEngineIgnoresTheWidgetItStopped() {
        let engine = EmbedAudioEngine()
        engine.load(provider: .soundcloud, url: episode, autoplay: false)
        let stopped = engine.generation
        engine.stop()
        engine.handle(event: "progress", generation: stopped, position: 30, duration: 3600, detail: nil)
        XCTAssertEqual(engine.state, .idle)
    }

    /// Paused while loading, it says paused, and the widget finishing its
    /// load does not undo that.
    func testAPauseWhileLoadingHolds() {
        let engine = EmbedAudioEngine()
        defer { engine.stop() }
        engine.load(provider: .soundcloud, url: episode, autoplay: true)
        engine.pause()
        XCTAssertEqual(engine.state, .paused)
        engine.handle(event: "loading", generation: engine.generation, position: 0, duration: 3600, detail: nil)
        XCTAssertEqual(engine.state, .paused)
    }

    /// One that never starts is called a failure, rather than loading — which
    /// the bar shows as playing — for ever.
    func testAShowThatNeverStartsFails() async {
        let engine = EmbedAudioEngine(startTimeout: .milliseconds(600))
        defer { engine.stop() }
        engine.load(provider: .soundcloud, url: episode, autoplay: true)
        await waitUntil(5) { if case .failed = engine.state { true } else { false } }
        guard case .failed = engine.state else { return XCTFail("Still \(engine.state)") }
    }

    func testAShowThatStartsIsNotFailedLater() async {
        let engine = EmbedAudioEngine(startTimeout: .milliseconds(600))
        defer { engine.stop() }
        engine.load(provider: .soundcloud, url: episode, autoplay: true)
        engine.handle(event: "play", generation: engine.generation, position: nil, duration: 3600, detail: nil)
        try? await Task.sleep(for: .seconds(1))
        // The real widget may yet say something of its own about a made-up
        // episode; what must not happen is the deadline firing.
        XCTAssertNotEqual(engine.state, .failed("It never started playing."))
    }
}
