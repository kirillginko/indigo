//
//  EmbedAudioEngine.swift
//  Indigo
//
//  NTS keeps its archive on SoundCloud and Mixcloud. Both publish an official
//  embed widget with a JavaScript control API, so Indigo hosts the widget in an
//  off-screen WKWebView and drives it from the normal transport — the audio
//  plays here instead of bouncing the listener to a browser.
//
//  This deliberately uses the sanctioned widget APIs rather than resolving the
//  underlying stream URLs, which would break both services' terms.
//

import Foundation
import Observation
import WebKit
#if os(iOS)
import UIKit
#endif

/// What the page reported, read apart.
///
/// The bridge prefixes provider-level codes onto the message — "youtube:150:…"
/// — because YouTube returns the same code for "the owner disabled embedding"
/// and "this origin is not allowed", and the app should not tell the listener
/// the first when it might be the second.
nonisolated struct EmbedFailure: Sendable {
    let message: String
    let isRecordingSpecific: Bool

    init(reported: String) {
        let parts = reported.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "youtube", let code = Int(parts[1]) else {
            message = reported
            isRecordingSpecific = false
            return
        }
        message = String(parts[2])
        // 100 gone, 101 and 150 refused, 2 unrecognised. All of them are about
        // this recording; anything else is the player.
        isRecordingSpecific = [2, 100, 101, 150].contains(code)
    }
}

nonisolated enum EmbedProvider: String, Codable, Hashable, Sendable {
    case soundcloud
    case mixcloud
    /// Played through YouTube's official IFrame Player API, for the same
    /// reason as the other two: their terms permit playback in their player
    /// and prohibit resolving the underlying stream. Indigo does not extract
    /// audio from YouTube and must not be made to.
    case youtube

    var displayName: String {
        switch self {
        case .soundcloud: "SoundCloud"
        case .mixcloud: "Mixcloud"
        case .youtube: "YouTube"
        }
    }
}

@Observable
final class EmbedAudioEngine: NSObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var pendingCommands: [String] = []
    @ObservationIgnored private var isBridgeReady = false
    @ObservationIgnored private var volume: Double = 1
    @ObservationIgnored private var currentRequest: (provider: EmbedProvider, url: URL)?
    /// An episode being put back after its web process was lost: whether it
    /// was playing, and where it had got to. Kept until it plays again, so a
    /// second loss in the middle of the first recovery restores what the
    /// listener had, not the half-recovered state.
    @ObservationIgnored private(set) var recovery: (autoplay: Bool, position: TimeInterval)?
    /// Whether the episode now loading was asked to play once it had.
    @ObservationIgnored private var loadAutoplays = false
    /// How many times the bridge page has been loaded. Read by tests.
    @ObservationIgnored private(set) var bridgeLoads = 0
    /// Which load the page's messages must belong to, to be listened to.
    ///
    /// Commands reach the page asynchronously, and its messages come back the
    /// same way, so switching shows leaves a gap in which the outgoing widget
    /// is still reporting: its half-second progress ticks were read as news
    /// about the item just put on, and a show that had not made a sound — and
    /// sometimes never did — read "playing". Every load and stop takes a new
    /// number, the page stamps each message with the one it is on, and a
    /// message stamped with any other is dropped.
    @ObservationIgnored private(set) var generation = 0
    /// Calls an item that never starts what it is. See `watchStart`.
    @ObservationIgnored private var startWatch: Task<Void, Never>?
    @ObservationIgnored private let startTimeout: Duration

    private static let bridgeName = "indigo"

    /// `startTimeout` is shorter only in tests.
    init(startTimeout: Duration = .seconds(30)) {
        self.startTimeout = startTimeout
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        // An iPhone plays web video full screen unless the web view allows it
        // inline, whatever the page asks (`playsinline`): a YouTube upload
        // took over the screen, and closing it stopped the music.
        configuration.allowsInlineMediaPlayback = true
        // Into every frame, YouTube's included: the page never says it has
        // been hidden, so the player has no reason of its own to pause when
        // the phone is locked. See `resumeYouTubeInBackground`.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.stayVisibleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        #endif
        configuration.userContentController.add(self, name: Self.bridgeName)
        #if os(macOS)
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        #endif

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200),
                            configuration: configuration)
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        loadBridge()
        #if os(iOS)
        observeBackgrounding()
        #endif
    }

    #if os(iOS)
    /// A page that always reports itself visible.
    private static let stayVisibleScript = """
    try {
      Object.defineProperty(document, 'hidden', { get: function () { return false; } });
      Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
      document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
      window.addEventListener('pagehide', function (e) { e.stopImmediatePropagation(); }, true);
    } catch (e) {}
    """

    /// Whether a YouTube upload was playing as the app left the screen.
    @ObservationIgnored private var youTubeWasPlaying = false

    /// iOS pauses a web view's video -- a YouTube upload is one, where
    /// SoundCloud's and Mixcloud's are audio -- when the app leaves the
    /// screen, so locking the phone stopped the music. One that was playing
    /// is told to play again a moment after; the audio background mode and
    /// the playback session let it carry on. Only within those first
    /// seconds: a pause from the lock screen after that is the listener's.
    private func observeBackgrounding() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.youTubeWasPlaying = self.currentRequest?.provider == .youtube && self.state == .playing
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeYouTubeInBackground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.youTubeWasPlaying = false }
        }
    }

    private func resumeYouTubeInBackground() {
        guard youTubeWasPlaying else { return }
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.youTubeWasPlaying, self.currentRequest?.provider == .youtube,
                      self.state != .playing else { return }
                self.run("indigoPlay()")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.youTubeWasPlaying = false
        }
    }
    #endif

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    // MARK: - Transport

    func load(provider: EmbedProvider, url: URL, autoplay: Bool) {
        recovery = nil
        loadAutoplays = autoplay
        currentRequest = (provider, url)
        generation += 1
        position = 0
        duration = 0
        setState(.loading)
        if autoplay { watchStart() } else { startWatch?.cancel() }

        // YouTube's player takes a video id, not an address. Extracted here
        // rather than in the page so the bridge stays a transport and every
        // URL shape a provider link can arrive in is handled in one place.
        let address = provider == .youtube
            ? (YouTubeLink.videoID(from: url) ?? url.absoluteString)
            : url.absoluteString
        let payload: [String: Any] = [
            "provider": provider.rawValue,
            "url": address,
            "autoplay": autoplay ? "1" : "0",
            "generation": generation
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: json, encoding: .utf8) else { return }
        run("indigoLoad(\(string))")
    }

    func play() {
        guard currentRequest != nil else { return }
        // Loading until the widget says it is playing, and held to the same
        // deadline as a first start: a play the widget quietly ignores must
        // not leave the button reading pause.
        setState(.loading)
        watchStart()
        run("indigoPlay()")
    }

    func pause() {
        startWatch?.cancel()
        // An item still loading is told not to start when it is ready, and
        // says so at once: it was reading "playing", and pausing it used to
        // change nothing until the widget began playing regardless.
        if state == .loading { setState(.paused) }
        run("indigoPause()")
    }

    func stop() {
        startWatch?.cancel()
        recovery = nil
        currentRequest = nil
        generation += 1
        position = 0
        duration = 0
        run("indigoStop(\(generation))")
        setState(.idle)
    }

    /// Gives an item the listener asked to hear a deadline to make a sound.
    ///
    /// The stream engine has had one for a long while; this never did, and
    /// loading counts as playing, so a widget that never started — a YouTube
    /// upload left cued, a play accepted and ignored — showed a pause button
    /// over silence for as long as the listener let it. Nudged once halfway,
    /// for the widget that was ready and simply did not begin, then called a
    /// failure, which the transport answers like any other.
    private func watchStart() {
        startWatch?.cancel()
        let half = startTimeout / 2
        let loadGeneration = generation
        startWatch = Task { [weak self] in
            try? await Task.sleep(for: half)
            guard !Task.isCancelled, let self, self.generation == loadGeneration,
                  self.state == .loading else { return }
            Trace.note("embed: not started after \(half), asking again")
            self.run("indigoPlay()")
            try? await Task.sleep(for: half)
            guard !Task.isCancelled, self.generation == loadGeneration,
                  self.state == .loading else { return }
            Trace.note("embed: never started")
            self.lastFailureIsRecordingSpecific = false
            self.setState(.failed("It never started playing."))
        }
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        position = target
        run("indigoSeek(\(target))")
    }

    func setVolume(_ value: Double) {
        volume = min(max(0, value), 1)
        run("indigoVolume(\(volume))")
    }

    /// Whether the last failure was about that particular recording rather
    /// than about the player itself.
    ///
    /// The difference decides what the transport should do: a video the
    /// uploader has locked down is a reason to move to the next one, and a
    /// broken player is a reason to stop and say so.
    private(set) var lastFailureIsRecordingSpecific = false

    func retry() {
        guard let request = currentRequest else { return }
        load(provider: request.provider, url: request.url, autoplay: true)
    }

    // MARK: - Bridge

    /// The origin the bridge page claims.
    ///
    /// It has to be a real https address — every one of these widgets refuses
    /// to hand-shake from `about:blank` or `file://` — and it is passed to
    /// YouTube's player as `origin`, which the player checks. It used to be
    /// SoundCloud's, which was fine for SoundCloud and a plausible reason for
    /// YouTube to refuse the frame.
    static let origin = "https://w.soundcloud.com"

    private func loadBridge() {
        bridgeLoads += 1
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: Self.origin + "/indigo"))
    }

    private func run(_ script: String) {
        guard isBridgeReady else {
            pendingCommands.append(script)
            return
        }
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.setState(.failed(error.localizedDescription))
            }
        }
    }

    private func flushPending() {
        let queued = pendingCommands
        pendingCommands = []
        for command in queued { run(command) }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?()
    }
}

// MARK: - Messages from the page

extension EmbedAudioEngine: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }
        let position = body["position"] as? Double
        let duration = body["duration"] as? Double
        let detail = body["detail"] as? String
        let generation = (body["generation"] as? NSNumber)?.intValue ?? -1

        Task { @MainActor [weak self] in
            self?.handle(event: event, generation: generation,
                         position: position, duration: duration, detail: detail)
        }
    }

    /// One message from the page. Internal so tests can stand in for it.
    func handle(event: String, generation: Int, position: Double?, duration: Double?, detail: String?) {
        // The page announcing itself belongs to no load; everything else
        // belongs to the one it was sent about.
        guard event == "ready" || generation == self.generation else { return }
        if let duration, duration > 0 { self.duration = duration }
        if let position, position >= 0 { self.position = position }

        switch event {
        case "ready":
            isBridgeReady = true
            setVolume(volume)
            flushPending()
        case "loading":
            // A widget finishing its load is not a reason to undo a pause
            // the listener made while it was still loading.
            if state != .paused { setState(.loading) }
        case "play":
            startWatch?.cancel()
            setState(.playing)
            if let recovery, self.duration > 0 {
                self.recovery = nil
                if recovery.position > 0 { seek(to: recovery.position) }
            }
        case "pause":
            setState(.paused)
        case "progress":
            if state != .playing, state != .paused {
                startWatch?.cancel()
                setState(.playing)
            }
        case "finish":
            self.position = self.duration
            setState(.paused)
            onFinished?()
        case "error":
            startWatch?.cancel()
            let reported = detail ?? "This episode could not be played."
            let failure = EmbedFailure(reported: reported)
            lastFailureIsRecordingSpecific = failure.isRecordingSpecific
            setState(.failed(failure.message))
        default:
            break
        }
    }
}

extension EmbedAudioEngine: WKNavigationDelegate {
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in self?.contentProcessTerminated() }
    }

    /// The page's process is gone — iOS ends a background app's web
    /// processes when it wants the memory, and they crash.
    ///
    /// The widget, the bridge and the music all went with it, and nothing
    /// noticed: the bridge still counted as ready, so every command after it
    /// was run against a blank page, failed, and the episode could not be
    /// played again until the app was relaunched. The bridge is loaded again
    /// and the episode put back where it was, playing if it was playing.
    func contentProcessTerminated() {
        Trace.note("embed: web content process ended")
        isBridgeReady = false
        pendingCommands = []
        let wanted = recovery ?? (state == .playing || (state == .loading && loadAutoplays), position)
        loadBridge()
        guard let request = currentRequest else { return }
        // One widget, loaded once: the old page and its audio went with the
        // process, so nothing is left to play alongside it.
        load(provider: request.provider, url: request.url, autoplay: wanted.autoplay)
        recovery = wanted
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.setState(.failed(message)) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.setState(.failed(message)) }
    }
}

// MARK: - The page

extension EmbedAudioEngine {
    /// Hosts whichever official widget the episode needs and normalises both
    /// APIs down to the same small command/event vocabulary.
    static let bridgeHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        /* The height chain has to reach the window. Without it "100%" on the
           host resolved against nothing, and YouTube's frame kept its default
           640x390 -- cropped and off-centre in the video panel. */
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
        #host { width: 100%; height: 100%; }
        iframe { border: 0; width: 100%; height: 100%; display: block; }
      </style>
      <script src="https://w.soundcloud.com/player/api.js"></script>
    </head>
    <body>
      <div id="host"></div>
      <script>
      (function () {
        var current = null;
        var volume = 1;
        var ticker = null;
        // The load every message is about; see `generation` in Swift.
        var generation = 0;
        // Whether the listener wants sound once the widget is ready. Read
        // when it gets there rather than fixed at load, so a pause made while
        // it loads is kept.
        var wantsPlay = false;

        // Whether a widget is still the one on the page. One being replaced
        // can still answer a question asked of it, or report an event that
        // was already on its way.
        function live(widget) { return current !== null && current.widget === widget; }

        function stopTicker() {
          if (ticker) { clearInterval(ticker); ticker = null; }
        }

        // Both widgets emit progress events, but not dependably across
        // buffering and seeks. Polling the position is the reliable source.
        function startTicker() {
          stopTicker();
          ticker = setInterval(function () {
            if (!current) { return; }
            var widget = current.widget;
            if (current.provider === 'soundcloud') {
              widget.getPosition(function (ms) {
                widget.getDuration(function (total) {
                  if (live(widget)) { send('progress', ms / 1000, total / 1000); }
                });
              });
            } else if (current.provider === 'youtube') {
              // YouTube answers synchronously, unlike the other two.
              try {
                send('progress', widget.getCurrentTime(), widget.getDuration());
              } catch (e) {}
            } else {
              Promise.all([widget.getPosition(), widget.getDuration()])
                .then(function (values) { if (live(widget)) { send('progress', values[0], values[1]); } })
                .catch(function () {});
            }
          }, 500);
        }

        function send(event, position, duration, detail) {
          try {
            window.webkit.messageHandlers.indigo.postMessage({
              event: event,
              generation: generation,
              position: (position === undefined || position === null) ? -1 : position,
              duration: (duration === undefined || duration === null) ? -1 : duration,
              detail: detail || ""
            });
          } catch (e) {}
        }

        function clear() {
          stopTicker();
          document.getElementById('host').innerHTML = '';
          current = null;
        }

        function makeFrame(src) {
          var frame = document.createElement('iframe');
          frame.setAttribute('allow', 'autoplay');
          frame.setAttribute('scrolling', 'no');
          frame.src = src;
          document.getElementById('host').appendChild(frame);
          return frame;
        }

        // --- SoundCloud -----------------------------------------------------

        function loadSoundCloud(url, autoplay) {
          if (typeof SC === 'undefined' || !SC.Widget) {
            send('error', null, null, 'The SoundCloud player could not be reached.');
            return;
          }
          var src = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent(url)
                  + '&auto_play=' + (autoplay ? 'true' : 'false')
                  + '&visual=false&show_comments=false&hide_related=true'
                  + '&sharing=false&download=false&buying=false';
          var widget = SC.Widget(makeFrame(src));
          current = { provider: 'soundcloud', widget: widget };

          widget.bind(SC.Widget.Events.READY, function () {
            if (!live(widget)) { return; }
            widget.setVolume(volume * 100);
            widget.getDuration(function (ms) { if (live(widget)) { send('loading', 0, ms / 1000); } });
            if (wantsPlay) { widget.play(); }
          });
          widget.bind(SC.Widget.Events.PLAY, function () {
            if (!live(widget)) { return; }
            // `auto_play` in the address starts it whatever has been said
            // since; a pause made while it loaded still stands.
            if (!wantsPlay) { widget.pause(); return; }
            startTicker();
            widget.getDuration(function (ms) { if (live(widget)) { send('play', null, ms / 1000); } });
          });
          widget.bind(SC.Widget.Events.PAUSE, function () { if (live(widget)) { stopTicker(); send('pause'); } });
          widget.bind(SC.Widget.Events.FINISH, function () { if (live(widget)) { stopTicker(); send('finish'); } });
          // The duration is what makes the seek bar usable; when READY did
          // not bring one (it can arrive late on a phone), ask while playing.
          var knownDuration = 0;
          widget.bind(SC.Widget.Events.PLAY_PROGRESS, function (e) {
            if (!live(widget)) { return; }
            if (knownDuration > 0) { send('progress', e.currentPosition / 1000); return; }
            widget.getDuration(function (ms) {
              if (ms > 0) { knownDuration = ms; }
              send('progress', e.currentPosition / 1000, ms > 0 ? ms / 1000 : null);
            });
          });
          widget.bind(SC.Widget.Events.ERROR, function () {
            if (!live(widget)) { return; }
            send('error', null, null, 'SoundCloud refused to play this episode.');
          });
        }

        // --- Mixcloud -------------------------------------------------------

        function ensureMixcloud(done) {
          if (window.Mixcloud) { done(); return; }
          var script = document.createElement('script');
          script.src = 'https://widget.mixcloud.com/media/js/widgetApi.js';
          script.onload = done;
          script.onerror = function () {
            send('error', null, null, 'The Mixcloud player could not be reached.');
          };
          document.head.appendChild(script);
        }

        // Mixcloud resolves `ready` as soon as the frame answers, which is
        // before it has actually loaded the cloudcast: until it has, the
        // duration is null and play() is accepted and then quietly ignored.
        // A real duration is the only signal it is actually ready to play.
        function whenMixcloudLoaded(widget, done) {
          var attempts = 0;
          (function poll() {
            widget.getDuration().then(function (d) {
              if (d && d > 0) { done(d); return; }
              if (++attempts > 40) { done(0); return; }
              setTimeout(poll, 250);
            }).catch(function () {
              if (++attempts > 40) { done(0); return; }
              setTimeout(poll, 250);
            });
          })();
        }

        function loadMixcloud(url, autoplay) {
          ensureMixcloud(function () {
            var path = url;
            // `pathname` is already percent-encoded, so encoding it again
            // would turn a show with an accent in its slug into a 404.
            try { path = decodeURIComponent(new URL(url).pathname); } catch (e) {}
            var src = 'https://player-widget.mixcloud.com/widget/iframe/?hide_cover=1&mini=1&feed='
                    + encodeURIComponent(path);
            var widget = Mixcloud.PlayerWidget(makeFrame(src));
            current = { provider: 'mixcloud', widget: widget };

            widget.ready.then(function () {
              if (!live(widget)) { return; }
              widget.setVolume(volume);
              widget.events.play.on(function () { if (live(widget)) { startTicker(); send('play'); } });
              widget.events.pause.on(function () { if (live(widget)) { stopTicker(); send('pause'); } });
              widget.events.ended.on(function () { if (live(widget)) { stopTicker(); send('finish'); } });
              widget.events.progress.on(function (position, duration) {
                if (live(widget)) { send('progress', position, duration); }
              });
              widget.events.error.on(function (error) {
                if (live(widget)) { send('error', null, null, String(error)); }
              });

              whenMixcloudLoaded(widget, function (duration) {
                if (!current || current.widget !== widget) { return; }
                if (duration > 0) {
                  send('loading', 0, duration);
                } else {
                  send('error', null, null, 'Mixcloud never loaded this show.');
                  return;
                }
                if (wantsPlay) { widget.play(); }
              });
            }).catch(function (error) {
              if (live(widget)) { send('error', null, null, String(error)); }
            });
          });
        }

        // --- Commands from Swift -------------------------------------------

        window.indigoLoad = function (config) {
          clear();
          generation = config.generation;
          var autoplay = config.autoplay === '1';
          wantsPlay = autoplay;
          send('loading', 0, 0);
          if (config.provider === 'mixcloud') {
            loadMixcloud(config.url, autoplay);
          } else if (config.provider === 'youtube') {
            loadYouTube(config.url, autoplay);
          } else {
            loadSoundCloud(config.url, autoplay);
          }
        };

        // --- YouTube --------------------------------------------------------

        function ensureYouTube(done) {
          if (window.YT && window.YT.Player) { done(); return; }
          window.onYouTubeIframeAPIReady = function () { done(); };
          if (document.getElementById('yt-api')) { return; }
          var script = document.createElement('script');
          script.id = 'yt-api';
          script.src = 'https://www.youtube.com/iframe_api';
          script.onerror = function () {
            send('error', null, null, 'The YouTube player could not be reached.');
          };
          document.head.appendChild(script);
        }

        function loadYouTube(videoID, autoplay) {
          var asked = generation;
          ensureYouTube(function () {
            // The API arrived after the listener had moved on.
            if (generation !== asked) { return; }
            var host = document.createElement('div');
            document.getElementById('host').appendChild(host);
            var player = new YT.Player(host, {
              videoId: videoID,
              // Fill the panel, whatever size it is, rather than 640x390.
              width: '100%',
              height: '100%',
              // No chrome. The listener is here for the music, and the
              // transport they are already using is the app's own.
              playerVars: {
                autoplay: autoplay ? 1 : 0, controls: 0, disablekb: 1,
                modestbranding: 1, rel: 0, playsinline: 1, fs: 0,
                // Unofficial, and YouTube may ignore it: ask for 720p rather
                // than leave the first stream to the player's size.
                vq: 'hd720',
                enablejsapi: 1, origin: window.location.origin
              },
              events: {
                onReady: function (event) {
                  if (!live(player)) { return; }
                  event.target.setVolume(volume * 100);
                  send('loading', 0, event.target.getDuration());
                  if (wantsPlay) { event.target.playVideo(); }
                },
                onStateChange: function (event) {
                  if (!live(player)) { return; }
                  if (event.data === YT.PlayerState.PLAYING) {
                    // The `autoplay` player variable, as SoundCloud's.
                    if (!wantsPlay) { event.target.pauseVideo(); return; }
                    startTicker();
                    send('play', null, event.target.getDuration());
                  } else if (event.data === YT.PlayerState.PAUSED) {
                    stopTicker();
                    send('pause');
                  } else if (event.data === YT.PlayerState.ENDED) {
                    stopTicker();
                    send('finish');
                  }
                },
                onError: function (event) {
                  if (!live(player)) { return; }
                  // Reported by code rather than as one message, because they
                  // are not the same problem: 100 is a video that no longer
                  // exists, 101 and 150 are a frame that was refused, and 2 is
                  // a malformed id, which would be our fault.
                  var code = event && event.data;
                  var detail;
                  if (code === 100) {
                    detail = 'That recording is no longer on YouTube.';
                  } else if (code === 101 || code === 150) {
                    detail = 'The uploader does not allow this one to play outside YouTube.';
                  } else if (code === 2) {
                    detail = 'YouTube did not recognise that video.';
                  } else {
                    detail = 'YouTube could not play that one.';
                  }
                  send('error', null, null, 'youtube:' + code + ':' + detail);
                }
              }
            });
            current = { provider: 'youtube', widget: player };
          });
        }

        // A command can arrive before the widget is ready — YouTube's player
        // has no playVideo until then — and a throw here reached Swift as the
        // episode failing. The widget plays on ready if it is still wanted.
        window.indigoPlay = function () {
          wantsPlay = true;
          if (!current) { return; }
          try {
            if (current.provider === 'youtube') { current.widget.playVideo(); }
            else { current.widget.play(); }
          } catch (e) {}
        };

        window.indigoPause = function () {
          wantsPlay = false;
          if (!current) { return; }
          try {
            if (current.provider === 'youtube') { current.widget.pauseVideo(); }
            else { current.widget.pause(); }
          } catch (e) {}
        };

        window.indigoStop = function (stopped) {
          wantsPlay = false;
          try {
            if (current && current.provider === 'youtube') { current.widget.stopVideo(); }
            else if (current) { current.widget.pause(); }
          } catch (e) {}
          clear();
          if (stopped !== undefined) { generation = stopped; }
        };

        window.indigoSeek = function (seconds) {
          if (!current) { return; }
          if (current.provider === 'soundcloud') {
            current.widget.seekTo(seconds * 1000);
          } else if (current.provider === 'youtube') {
            current.widget.seekTo(seconds, true);
          } else {
            current.widget.seek(seconds);
          }
        };

        window.indigoVolume = function (value) {
          volume = value;
          if (!current) { return; }
          if (current.provider === 'soundcloud' || current.provider === 'youtube') {
            current.widget.setVolume(value * 100);
          } else {
            current.widget.setVolume(value);
          }
        };

        send('ready');
      })();
      </script>
    </body>
    </html>
    """#
}
