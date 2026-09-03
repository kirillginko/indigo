//
//  LocalAudioEngine.swift
//  Indigo
//
//  AVPlayer wrapper for anything addressable and finite: on-disk files, and
//  archived broadcasts a station publishes as a plain URL rather than through
//  a widget. Reports position and duration, and pre-rolls the next queue entry
//  so track changes are close to gapless.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class LocalAudioEngine {
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    /// Fired when the current file plays to its end.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Fired when a file cannot be played; the coordinator decides whether to skip.
    @ObservationIgnored var onFailure: ((String) -> Void)?
    /// Fired whenever play/pause state flips, so Now Playing can be refreshed.
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var preparedItem: (url: URL, item: AVPlayerItem)?

    init() {
        player.actionAtItemEnd = .pause
        installTimeObserver()
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.onStateChange?()
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    @ObservationIgnored private let levelMonitor = AudioLevelMonitor()
    func audioLevel() -> Float { levelMonitor.level() }

    // MARK: - Transport

    func load(url: URL, knownDuration: TimeInterval?, autoplay: Bool) {
        let item: AVPlayerItem
        if let prepared = preparedItem, prepared.url == url {
            item = prepared.item
        } else {
            item = AVPlayerItem(asset: AVURLAsset(url: url))
        }
        preparedItem = nil

        duration = knownDuration ?? 0
        position = 0
        // Starting the rate immediately is what makes an on-disk track feel
        // instant, and it is exactly wrong for a remote one: AVPlayer plays
        // into an empty buffer, reports itself as playing, and the playhead
        // never moves. Anything off the network is allowed to buffer first.
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        levelMonitor.attach(to: item)
        player.replaceCurrentItem(with: item)
        observe(item)
        if autoplay { player.play() } else { player.pause() }
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        levelMonitor.reset()
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedItem = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    func seek(to seconds: TimeInterval) {
        guard player.currentItem != nil, duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        position = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func setVolume(_ value: Double) {
        player.volume = Float(min(max(0, value), 1))
    }

    /// Warms up the next file so `load` can swap it in without a stall.
    func prepare(url: URL) {
        guard preparedItem?.url != url else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        preparedItem = (url, item)
        Task.detached(priority: .utility) {
            _ = try? await asset.load(.isPlayable, .duration)
        }
    }

    // MARK: - Observation

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.position = max(0, seconds) }
                if self.duration <= 0, let itemDuration = self.player.currentItem?.duration,
                   itemDuration.isNumeric {
                    let value = CMTimeGetSeconds(itemDuration)
                    if value.isFinite, value > 0 { self.duration = value }
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinished?() }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.onFailure?(error?.localizedDescription ?? "This file could not be played.")
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "This file could not be played."
            Task { @MainActor [weak self] in self?.onFailure?(message) }
        }
    }
}
