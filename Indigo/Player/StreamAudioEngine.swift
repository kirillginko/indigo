//
//  StreamAudioEngine.swift
//  Indigo
//
//  AVPlayer wrapper for live internet radio. No seeking, no duration — but it
//  does report buffering and recovers from stalls and dropped connections.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class StreamAudioEngine {
    enum State: Equatable {
        case idle
        case buffering
        case playing
        case paused
        case failed(String)

        var isActive: Bool { self != .idle }
    }

    private(set) var state: State = .idle
    /// Fired whenever the stream state changes, so Now Playing can be refreshed.
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var stallObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var connectDeadline: Task<Void, Never>?

    /// How long a station gets to make a sound before it is called
    /// unavailable.
    ///
    /// AVPlayer's own patience is a minute, and it spends it silently: a host
    /// that accepts a connection and then sends nothing leaves the bar reading
    /// "Buffering" for the whole of it and only then reports a timeout. A
    /// listener has decided the app is broken long before that. Twenty
    /// seconds is longer than any of these stations takes on a working
    /// connection and short enough to be an answer.
    @ObservationIgnored private static let connectTimeout = Duration.seconds(20)
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var volume: Double = 1
    @ObservationIgnored private var isUserPaused = false

    private static let maxReconnectAttempts = 5

    deinit {
        removeNotificationObservers()
    }

    @ObservationIgnored private let levelMonitor = AudioLevelMonitor()
    func audioLevel() -> Float { levelMonitor.level() }

    // MARK: - Transport

    func play(url: URL) {
        reconnectTask?.cancel()
        reconnectAttempts = 0
        isUserPaused = false
        start(url: url)
    }

    func resume() {
        isUserPaused = false
        guard let currentURL else { return }
        // A live stream that has been paused is stale; reconnect at the live edge.
        start(url: currentURL)
    }

    func pause() {
        connectDeadline?.cancel()
        isUserPaused = true
        reconnectTask?.cancel()
        player.pause()
        setState(.paused)
    }

    func stop() {
        levelMonitor.reset()
        reconnectTask?.cancel()
        connectDeadline?.cancel()
        reconnectAttempts = 0
        isUserPaused = false
        removeNotificationObservers()
        statusObservation = nil
        timeControlObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        setState(.idle)
    }

    func setVolume(_ value: Double) {
        volume = min(max(0, value), 1)
        player.volume = Float(volume)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        // A few lines per station, and the only record of what a stream
        // actually did. "Radio does not play" was diagnosed three times from
        // request timings and system logs, none of which say whether a
        // station reached `playing`, stalled, or was never asked. This does.
        Trace.note("stream.\(Self.label(new)) \(currentURL?.host ?? "-")")
        state = new
        onStateChange?()
    }

    private static func label(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .buffering: "buffering"
        case .playing: "PLAYING"
        case .paused: "paused"
        case .failed(let message): "FAILED \(message)"
        }
    }

    // MARK: - Connection

    private func start(url: URL) {
        removeNotificationObservers()
        currentURL = url
        setState(.buffering)

        // A fresh player each time: reusing one after a network drop tends to
        // keep serving a dead item.
        //
        // The old item is released before the new one is made, and that
        // ordering is the point. Pausing a player does not close its
        // connection — the socket lives until the item is torn down, which
        // otherwise happens whenever the discarded player is finally
        // deallocated. Reconnecting in that window opens a *second*
        // connection to a mount that already has one, and these are Icecast
        // mounts: several of them refuse it. Since the first reconnect waits
        // no time at all, one stall was enough to put a station into a loop
        // where every retry was turned away and the fifth reported it
        // unavailable — while whichever station was already playing carried
        // on, because it never had to reconnect.
        player.replaceCurrentItem(with: nil)
        player.pause()
        player = AVPlayer()
        // Left alone, and not to be turned off again.
        //
        // It was, to make IDA start promptly: IDA's Icecast answers a range
        // request with `206` and a `Content-Range` ending `/1073741823`, so
        // AVPlayer sees a seekable file some seven hours long and buffers
        // proportionally before it will play. Turning the wait off was
        // written down at the time as unverified, and it cost every other
        // station. Told not to wait, AVPlayer starts a live stream with
        // nothing buffered, stalls on the first frame, and hands this engine
        // a stall to reconnect from — which stalls again, five times, and
        // then the station is reported unavailable. Noods was the one that
        // survived, and one station out of nine is not a policy.
        //
        // IDA buffering slowly is a smaller complaint than radio not
        // playing, so it goes back to being an open problem rather than one
        // paid for by everybody else.
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = Float(volume)

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": NetworkEnvironment.userAgent]
        ])
        let item = AVPlayerItem(asset: asset)
        // How much to have in hand before playing, rather than whether to
        // wait at all.
        //
        // Left to decide for itself, AVPlayer buffers in proportion to what
        // it thinks it is playing — and IDA's Icecast claims a length of
        // 1073741823 bytes, so it prepares for a seven-hour file. Measured
        // against the live stations: IDA took 4.73s to make a sound and NTS
        // 3.77s, where the ones that answer honestly took under a second.
        // Asked for two seconds instead, both start in about one, and the
        // stations that were already quick are unchanged.
        //
        // Two, not five: at five NTS goes back to nearly four seconds, which
        // is the proportional guess creeping back in.
        //
        // This is the setting that was wanted when
        // `automaticallyWaitsToMinimizeStalling` was turned off above. That
        // said "play with nothing buffered", which starts instantly and
        // stalls on the first frame — and a stall here means reconnecting,
        // which is how every station but the one already playing came to
        // report itself unavailable. This bounds the wait instead of
        // abolishing it.
        item.preferredForwardBufferDuration = 2
        levelMonitor.attach(to: item)
        player.replaceCurrentItem(with: item)
        observe(item)
        player.play()
        watchForSilence()
    }

    /// Calls a station that never starts what it is.
    ///
    /// Cancelled the moment anything plays — see the `timeControlStatus`
    /// observer, which is the only place that can say a sound was made.
    private func watchForSilence() {
        connectDeadline?.cancel()
        connectDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, !self.isUserPaused else { return }
            guard case .buffering = self.state else { return }
            // Slow is not silent. A station whose bytes are arriving is
            // buffering, which is the player doing its job — IDA's Icecast
            // claims a seven-hour length and is buffered proportionally, and
            // cutting that off would be this timer breaking the station it
            // was meant to report on. Only a stream that has loaded nothing
            // at all has failed to answer.
            let loaded = self.player.currentItem?.loadedTimeRanges ?? []
            guard loaded.isEmpty else { return }
            self.handleInterruption("The station did not respond.")
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The stream is unavailable."
            Task { @MainActor [weak self] in self?.handleInterruption(message) }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, !self.isUserPaused else { return }
                switch status {
                case .playing:
                    self.reconnectAttempts = 0
                    self.connectDeadline?.cancel()
                    self.setState(.playing)
                case .waitingToPlayAtSpecifiedRate:
                    if case .failed = self.state {} else { self.setState(.buffering) }
                case .paused:
                    break
                @unknown default:
                    break
                }
            }
        }

        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleInterruption("The connection stalled.")
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.handleInterruption(error?.localizedDescription ?? "The stream stopped unexpectedly.")
            }
        }
    }

    private func handleInterruption(_ message: String) {
        guard !isUserPaused, let url = currentURL else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            setState(.failed(message))
            return
        }
        reconnectAttempts += 1
        Trace.note("stream.reconnect \(reconnectAttempts)/\(Self.maxReconnectAttempts) \(message)")
        setState(.buffering)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self, delay = Self.reconnectDelay(attempt: reconnectAttempts)] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            self?.start(url: url)
        }
    }

    /// How long to wait before trying again.
    ///
    /// The first attempt does not wait at all. A stall already means the
    /// connection is in trouble, and a second of deliberate silence on top of
    /// it buys nothing — measured against a two-second underrun on IDA's
    /// stream, the old one-second first backoff cost 2.17s of silence where
    /// reconnecting at once cost 1.12s.
    ///
    /// Waiting is still right once a station is properly unreachable, so the
    /// backoff is kept for every attempt after the first.
    private static func reconnectDelay(attempt: Int) -> UInt64 {
        guard attempt > 1 else { return 0 }
        return UInt64(min(8, 1 << (attempt - 2))) * 1_000_000_000
    }

    private func removeNotificationObservers() {
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        stallObserver = nil
        failureObserver = nil
    }
}
