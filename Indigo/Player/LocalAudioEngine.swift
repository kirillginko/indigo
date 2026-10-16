//
//  LocalAudioEngine.swift
//  Indigo
//
//  AVPlayer wrapper for anything addressable and finite: on-disk files, and
//  archived broadcasts a station publishes as a plain URL rather than through
//  a widget. Reports position and duration, pre-rolls the next queue entry
//  so track changes are close to gapless, and reopens a remote episode whose
//  connection drops at the point it had reached.
//

import AVFoundation
import Foundation
import Network
import Observation
#if os(iOS)
import UIKit
#endif

@Observable
final class LocalAudioEngine {
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// A remote episode lost its connection and is being reopened where it
    /// was. The speaker is silent, but nothing has gone wrong yet that the
    /// listener needs telling about: this is buffering, not a failure.
    private(set) var isReopening = false
    /// Whether the listener last asked for sound rather than silence. Kept
    /// apart from `isPlaying`, which is what AVPlayer is doing, because a
    /// dropped episode is not playing and is still meant to be.
    private(set) var wantsToPlay = false

    /// Fired when the current file plays to its end.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Fired when a file cannot be played, and for a remote one only once
    /// reopening it has stopped working; the coordinator decides whether to
    /// skip.
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

    // MARK: Reopening

    /// What is loaded, so a dropped one can be asked for again.
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var reopen: ReconnectPolicy
    @ObservationIgnored private var reopenTask: Task<Void, Never>?
    /// Where the current item was opened from: zero, or where it dropped.
    @ObservationIgnored private var openedAt: TimeInterval = 0
    /// Whether the playhead has moved on from `openedAt` since. Until it
    /// has, the time observer's reading is the new item seeking, not the
    /// listener's place in the episode.
    @ObservationIgnored private var hasProgressed = false
    /// The failure has been handed to the coordinator. Every later report
    /// about this item is the same failure, noticed again.
    @ObservationIgnored private var hasReported = false
    @ObservationIgnored private var isOnline = true
    @ObservationIgnored private var isWaitingForNetwork = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Which URLs a dropped connection is worth reopening for. Anything off
    /// the network; tests widen it to the files that stand in for one.
    @ObservationIgnored private let reopens: (URL) -> Bool
    /// How long the item itself says it is, when it knows. Injectable
    /// because a file cannot be made to end early, and a dropped download
    /// is exactly a file that ends early.
    @ObservationIgnored private let itemLength: (AVPlayerItem) -> TimeInterval?
    /// How many times an item has been opened. Read by tests.
    @ObservationIgnored private(set) var connections = 0

    /// An episode that ends this much short of its length has been cut off
    /// rather than finished.
    ///
    /// AVPlayer reports a closed or reset connection as the item playing to
    /// its end — not as a failure — so on cellular an hour-long show could
    /// "finish" twenty minutes in and the queue moved on. Generous, because
    /// a catalogue's length is a rounded figure and a VBR file's is an
    /// estimate; and being wrong costs one reopen at the very end, which
    /// ends again without moving and is then believed. See `itemEnded`.
    @ObservationIgnored static let shortfall: TimeInterval = 10

    /// No chances for an item that has never played: a file that is not
    /// there is not a dropped connection, and the coordinator has a mirror
    /// to try and a queue to move on to. Six once it has played — the same
    /// backoff as a station, so a little under half a minute of trying, and
    /// none of it spent while there is no network at all.
    static let defaultReopenPolicy = ReconnectPolicy(limit: 0, sustainedLimit: 6)

    /// `monitorsNetwork` is off only in tests, which say what the network is
    /// doing through `networkChanged(isOnline:)`.
    init(
        monitorsNetwork: Bool = true,
        reopen: ReconnectPolicy = LocalAudioEngine.defaultReopenPolicy,
        reopens: @escaping (URL) -> Bool = { !$0.isFileURL },
        itemLength: @escaping (AVPlayerItem) -> TimeInterval? = LocalAudioEngine.reportedLength
    ) {
        self.reopen = reopen
        self.reopens = reopens
        self.itemLength = itemLength
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
        guard monitorsNetwork else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(isOnline: online) }
        }
        monitor.start(queue: DispatchQueue(label: "LocalAudioEngine.path"))
        pathMonitor = monitor
    }

    deinit {
        pathMonitor?.cancel()
        reopenTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
    }

    @ObservationIgnored private let levelMonitor = AudioLevelMonitor()
    func audioLevel() -> Float { levelMonitor.level() }

    // MARK: - Transport

    func load(url: URL, knownDuration: TimeInterval?, autoplay: Bool) {
        endReopening()
        reopen.reset()
        hasReported = false
        currentURL = url
        duration = knownDuration ?? 0
        open(url: url, at: 0, autoplay: autoplay)
    }

    private func open(url: URL, at start: TimeInterval, autoplay: Bool) {
        let item: AVPlayerItem
        if start == 0, let prepared = preparedItem, prepared.url == url {
            item = prepared.item
        } else {
            item = AVPlayerItem(asset: AVURLAsset(url: url))
        }
        preparedItem = nil

        connections += 1
        reopen.opening()
        openedAt = start
        hasProgressed = false
        position = start
        wantsToPlay = autoplay
        // Starting the rate immediately is what makes an on-disk track feel
        // instant, and it is exactly wrong for a remote one: AVPlayer plays
        // into an empty buffer, reports itself as playing, and the playhead
        // never moves. Anything off the network is allowed to buffer first.
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        levelMonitor.attach(to: item)
        player.replaceCurrentItem(with: item)
        observe(item)
        if start > 0 {
            // A little early rather than late: hearing the last second again
            // is better than missing one. Exact seeks on a remote MP3 cost a
            // round trip each.
            player.seek(
                to: CMTime(seconds: start, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 2, preferredTimescale: 600),
                toleranceAfter: .zero
            )
        }
        if autoplay { player.play() } else { player.pause() }
    }

    func play() {
        wantsToPlay = true
        guard player.currentItem != nil else { return }
        player.play()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        // A reopen still pending opens paused; the listener's place is kept.
    }

    func stop() {
        endReopening()
        currentURL = nil
        wantsToPlay = false
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
        // The listener chose this place, so it is where a drop reopens.
        openedAt = target
        hasProgressed = false
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
                if seconds.isFinite { self.timeAdvanced(to: max(0, seconds)) }
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
            MainActor.assumeIsolated { self?.itemEnded() }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self?.dropped(error?.localizedDescription ?? "This file could not be played.")
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription ?? "This file could not be played."
            Task { @MainActor [weak self] in
                // A status change queued by an item already replaced is news
                // about that item, not the one now opening.
                guard let self, let item, self.player.currentItem === item else { return }
                self.dropped(message)
            }
        }
    }

    // MARK: - Recovering a dropped episode

    /// How long an item says it is, when it has been told: a remote file's
    /// length comes from its headers and outlives the connection.
    static func reportedLength(of item: AVPlayerItem) -> TimeInterval? {
        guard item.duration.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(item.duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Whether an item that stopped at `position` stopped short of `length`.
    static func endedShort(at position: TimeInterval, of length: TimeInterval?) -> Bool {
        guard let length, length > 0 else { return false }
        return length - position > shortfall
    }

    private func timeAdvanced(to seconds: TimeInterval) {
        if !hasProgressed {
            // Until the reopened item has found its place, its clock reads
            // zero, and a second drop in that window must not take zero for
            // where the listener had got to. Measured from where it dropped,
            // not where the seek landed: a reopen that lands two seconds
            // early and replays them to the same dead end has not moved, and
            // counting it would reopen an episode with a long length forever.
            guard seconds > openedAt + 0.5 else { return }
            hasProgressed = true
            reopen.playing()
            if isReopening { endReopening() }
        }
        position = seconds
    }

    private func itemEnded() {
        guard let url = currentURL, reopens(url), !hasReported else {
            onFinished?()
            return
        }
        let length = player.currentItem.flatMap(itemLength) ?? (duration > 0 ? duration : nil)
        // A reopen that ends again without moving is the real end: the
        // length was a little long, and there is nothing past this point.
        guard Self.endedShort(at: position, of: length), hasProgressed || openedAt == 0 else {
            endReopening()
            onFinished?()
            return
        }
        dropped("The connection closed before the end.")
    }

    /// A remote episode lost its connection, however AVPlayer put it.
    private func dropped(_ message: String) {
        guard !hasReported else { return }
        guard let url = currentURL, reopens(url) else {
            onFailure?(message)
            return
        }
        switch reopen.interrupted(isOnline: isOnline) {
        case .ignore:
            return
        case .giveUp:
            endReopening()
            hasReported = true
            onFailure?(message)
        case .waitForNetwork:
            Trace.note("local.reopen waiting for a network \(message)")
            reopenTask?.cancel()
            isWaitingForNetwork = true
            beginReopening()
        case .retry(let delay):
            Trace.note("local.reopen \(reopen.attempts)/\(reopen.currentLimit) at \(Int(position))s \(message)")
            beginReopening()
            reopenTask?.cancel()
            reopenTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                self?.reopenNow()
            }
        }
    }

    private func reopenNow() {
        guard let url = currentURL else { return }
        reopenTask?.cancel()
        reopenTask = nil
        isWaitingForNetwork = false
        // Where the listener had got to, not where the dead item's clock
        // stopped: that may be the seek of an earlier reopen still settling.
        let resumeAt = hasProgressed ? position : openedAt
        open(url: url, at: resumeAt, autoplay: wantsToPlay)
    }

    /// The device gained or lost its network path. An episode waiting for
    /// one, or sleeping off a backoff, reopens the moment it comes back.
    func networkChanged(isOnline online: Bool) {
        let cameBack = online && !isOnline
        guard online != isOnline else { return }
        isOnline = online
        guard cameBack, isReopening, currentURL != nil else { return }
        if isWaitingForNetwork || reopenTask != nil { reopenNow() }
    }

    private func beginReopening() {
        guard !isReopening else { return }
        isReopening = true
        #if os(iOS)
        holdBackgroundTime()
        #endif
        onStateChange?()
    }

    private func endReopening() {
        reopenTask?.cancel()
        reopenTask = nil
        isWaitingForNetwork = false
        #if os(iOS)
        releaseBackgroundTime()
        #endif
        guard isReopening else { return }
        isReopening = false
        onStateChange?()
    }

    #if os(iOS)
    @ObservationIgnored private var backgroundTime: UIBackgroundTaskIdentifier = .invalid

    /// Keeps a locked phone's app running while the episode is silent
    /// between connections. See `StreamAudioEngine.holdBackgroundTime`.
    private func holdBackgroundTime() {
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Reopen episode") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackgroundTime() }
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }
    #endif
}
