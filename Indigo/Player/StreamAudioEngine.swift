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

/// One failure is one failure, however many observers notice it.
///
/// Three things report the same dropped connection: the item's status turning
/// `.failed`, a `playbackStalled` notification, and a `failedToPlayToEndTime`
/// notification. Each used to count as a separate failure, so one of them
/// could spend two of the five chances a station gets — and, worse, spend the
/// free one. The first retry waits no time at all by design, because a stall
/// already means the connection is in trouble and a second of deliberate
/// silence on top of it buys nothing: measured against a two-second underrun
/// on IDA's stream, reconnecting at once cost 1.12s of silence where a
/// one-second backoff cost 2.17s. The second retry waits a second. So a
/// duplicate report quietly turned the immediate retry into a delayed one,
/// which is exactly the cost that backoff was tuned to remove.
///
/// A trace of a livepeer stream shows it: the same station, failing the same
/// way, took 108ms and 133ms from restart to failure, and the first two
/// reconnect lines are 46ms apart. Nothing restarted in between. It also
/// matters more than the arithmetic suggests — several of these stations are
/// Icecast mounts that refuse a second connection while the first is still
/// open, so a retry the station was never going to accept is not a wasted
/// chance but a harmful one. See `start(url:)`.
nonisolated struct ReconnectPolicy {
    enum Response: Equatable {
        /// The failure already being dealt with, noticed again.
        case ignore
        case retry(after: Duration)
        /// Out of chances. The station is unavailable and should say so.
        case giveUp
    }

    /// How many chances a station gets before it is called unavailable.
    let limit: Int
    /// How many it has used. Shown in the trace, and nowhere else.
    private(set) var attempts = 0
    /// Whether a retry is scheduled and has not yet been acted on. This is
    /// the whole of what tells a second observer from a second failure.
    private var isAwaitingRetry = false

    init(limit: Int) { self.limit = limit }

    mutating func interrupted() -> Response {
        guard !isAwaitingRetry else { return .ignore }
        guard attempts < limit else { return .giveUp }
        attempts += 1
        isAwaitingRetry = true
        return .retry(after: Self.delay(attempt: attempts))
    }

    /// The stream is being opened again, so whatever fails next is new.
    mutating func opening() { isAwaitingRetry = false }

    /// Something played, or the listener took over.
    mutating func reset() {
        attempts = 0
        isAwaitingRetry = false
    }

    /// How long to wait before trying again.
    ///
    /// Waiting is right once a station is properly unreachable, so the
    /// backoff is kept for every attempt after the first.
    static func delay(attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        return .seconds(min(8, 1 << (attempt - 2)))
    }
}

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
    @ObservationIgnored private var reconnect = ReconnectPolicy(limit: 5)
    @ObservationIgnored private var volume: Double = 1
    @ObservationIgnored private var isUserPaused = false

    deinit {
        removeObservers()
    }

    @ObservationIgnored private let levelMonitor = AudioLevelMonitor()
    func audioLevel() -> Float { levelMonitor.level() }

    // MARK: - Transport

    func play(url: URL) {
        reconnectTask?.cancel()
        reconnect.reset()
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
        reconnect.reset()
        isUserPaused = false
        removeObservers()
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
        removeObservers()
        // Whatever failed last is behind us; the next failure is a new one.
        reconnect.opening()
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
                    self.reconnect.reset()
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
        switch reconnect.interrupted() {
        case .ignore:
            return
        case .giveUp:
            setState(.failed(message))
        case .retry(let delay):
            Trace.note("stream.reconnect \(reconnect.attempts)/\(reconnect.limit) \(message)")
            setState(.buffering)
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                self?.start(url: url)
            }
        }
    }

    /// Every way the outgoing stream could still speak.
    ///
    /// The notifications used to be torn down here and the two observations
    /// left alone until `observe(_:)` reassigned them — so between letting go
    /// of one stream and taking hold of the next, an item that was being
    /// discarded could still turn `.failed`, and a player that had just been
    /// replaced could still report its status. Either one arrives as news
    /// about the stream now opening, which it is not: a dying item's failure
    /// would be counted against its replacement's five chances.
    private func removeObservers() {
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        stallObserver = nil
        failureObserver = nil
        statusObservation = nil
        timeControlObservation = nil
    }
}
