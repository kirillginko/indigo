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
        isUserPaused = true
        reconnectTask?.cancel()
        player.pause()
        setState(.paused)
    }

    func stop() {
        levelMonitor.reset()
        reconnectTask?.cancel()
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
        state = new
        onStateChange?()
    }

    // MARK: - Connection

    private func start(url: URL) {
        removeNotificationObservers()
        currentURL = url
        setState(.buffering)

        // A fresh player each time: reusing one after a network drop tends to
        // keep serving a dead item.
        player.pause()
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = Float(volume)

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": NetworkEnvironment.userAgent]
        ])
        let item = AVPlayerItem(asset: asset)
        levelMonitor.attach(to: item)
        player.replaceCurrentItem(with: item)
        observe(item)
        player.play()
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
