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

    private static let bridgeName = "indigo"

    override init() {
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
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
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    // MARK: - Transport

    func load(provider: EmbedProvider, url: URL, autoplay: Bool) {
        currentRequest = (provider, url)
        position = 0
        duration = 0
        setState(.loading)

        // YouTube's player takes a video id, not an address. Extracted here
        // rather than in the page so the bridge stays a transport and every
        // URL shape a provider link can arrive in is handled in one place.
        let address = provider == .youtube
            ? (YouTubeLink.videoID(from: url) ?? url.absoluteString)
            : url.absoluteString
        let payload = [
            "provider": provider.rawValue,
            "url": address,
            "autoplay": autoplay ? "1" : "0"
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: json, encoding: .utf8) else { return }
        run("indigoLoad(\(string))")
    }

    func play() {
        guard currentRequest != nil else { return }
        run("indigoPlay()")
    }

    func pause() {
        run("indigoPause()")
    }

    func stop() {
        currentRequest = nil
        position = 0
        duration = 0
        run("indigoStop()")
        setState(.idle)
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

        Task { @MainActor [weak self] in
            self?.handle(event: event, position: position, duration: duration, detail: detail)
        }
    }

    private func handle(event: String, position: Double?, duration: Double?, detail: String?) {
        if let duration, duration > 0 { self.duration = duration }
        if let position, position >= 0 { self.position = position }

        switch event {
        case "ready":
            isBridgeReady = true
            setVolume(volume)
            flushPending()
        case "loading":
            setState(.loading)
        case "play":
            setState(.playing)
        case "pause":
            setState(.paused)
        case "progress":
            if state != .playing, state != .paused { setState(.playing) }
        case "finish":
            self.position = self.duration
            setState(.paused)
            onFinished?()
        case "error":
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
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
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

        function stopTicker() {
          if (ticker) { clearInterval(ticker); ticker = null; }
        }

        // Both widgets emit progress events, but not dependably across
        // buffering and seeks. Polling the position is the reliable source.
        function startTicker() {
          stopTicker();
          ticker = setInterval(function () {
            if (!current) { return; }
            if (current.provider === 'soundcloud') {
              current.widget.getPosition(function (ms) {
                current.widget.getDuration(function (total) {
                  send('progress', ms / 1000, total / 1000);
                });
              });
            } else if (current.provider === 'youtube') {
              // YouTube answers synchronously, unlike the other two.
              try {
                send('progress', current.widget.getCurrentTime(), current.widget.getDuration());
              } catch (e) {}
            } else {
              Promise.all([current.widget.getPosition(), current.widget.getDuration()])
                .then(function (values) { send('progress', values[0], values[1]); })
                .catch(function () {});
            }
          }, 500);
        }

        function send(event, position, duration, detail) {
          try {
            window.webkit.messageHandlers.indigo.postMessage({
              event: event,
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
            widget.setVolume(volume * 100);
            widget.getDuration(function (ms) { send('loading', 0, ms / 1000); });
            if (autoplay) { widget.play(); }
          });
          widget.bind(SC.Widget.Events.PLAY, function () {
            startTicker();
            widget.getDuration(function (ms) { send('play', null, ms / 1000); });
          });
          widget.bind(SC.Widget.Events.PAUSE, function () { stopTicker(); send('pause'); });
          widget.bind(SC.Widget.Events.FINISH, function () { stopTicker(); send('finish'); });
          widget.bind(SC.Widget.Events.PLAY_PROGRESS, function (e) {
            send('progress', e.currentPosition / 1000);
          });
          widget.bind(SC.Widget.Events.ERROR, function () {
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
              widget.setVolume(volume);
              widget.events.play.on(function () { startTicker(); send('play'); });
              widget.events.pause.on(function () { stopTicker(); send('pause'); });
              widget.events.ended.on(function () { stopTicker(); send('finish'); });
              widget.events.progress.on(function (position, duration) {
                send('progress', position, duration);
              });
              widget.events.error.on(function (error) {
                send('error', null, null, String(error));
              });

              whenMixcloudLoaded(widget, function (duration) {
                if (!current || current.widget !== widget) { return; }
                if (duration > 0) {
                  send('loading', 0, duration);
                } else {
                  send('error', null, null, 'Mixcloud never loaded this show.');
                  return;
                }
                if (autoplay) { widget.play(); }
              });
            }).catch(function (error) {
              send('error', null, null, String(error));
            });
          });
        }

        // --- Commands from Swift -------------------------------------------

        window.indigoLoad = function (config) {
          clear();
          send('loading', 0, 0);
          var autoplay = config.autoplay === '1';
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
          ensureYouTube(function () {
            var host = document.createElement('div');
            document.getElementById('host').appendChild(host);
            var player = new YT.Player(host, {
              videoId: videoID,
              // No chrome. The listener is here for the music, and the
              // transport they are already using is the app's own.
              playerVars: {
                autoplay: autoplay ? 1 : 0, controls: 0, disablekb: 1,
                modestbranding: 1, rel: 0, playsinline: 1, fs: 0,
                enablejsapi: 1, origin: window.location.origin
              },
              events: {
                onReady: function (event) {
                  event.target.setVolume(volume * 100);
                  send('loading', 0, event.target.getDuration());
                  if (autoplay) { event.target.playVideo(); }
                },
                onStateChange: function (event) {
                  if (event.data === YT.PlayerState.PLAYING) {
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

        window.indigoPlay = function () {
          if (!current) { return; }
          if (current.provider === 'youtube') { current.widget.playVideo(); }
          else { current.widget.play(); }
        };

        window.indigoPause = function () {
          if (!current) { return; }
          if (current.provider === 'youtube') { current.widget.pauseVideo(); return; }
          current.widget.pause();
        };

        window.indigoStop = function () {
          try { if (current) { current.widget.pause(); } } catch (e) {}
          clear();
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
