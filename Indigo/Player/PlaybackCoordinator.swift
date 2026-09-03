//
//  PlaybackCoordinator.swift
//  Indigo
//
//  The only thing the UI talks to. It owns the queue, decides which engine
//  should be running, and hands the result to the system Now Playing centre.
//  Views never touch AVPlayer, and nothing here knows what NTS is.
//

import Foundation
import Observation

@Observable
final class PlaybackCoordinator {
    enum Source: String, Equatable {
        case none
        case local
        case stream
        /// An archived episode inside a hosted SoundCloud/Mixcloud widget.
        case embed
    }

    // MARK: State

    private(set) var source: Source = .none
    private(set) var current: MediaItem?
    private(set) var queue = PlaybackQueue()
    private(set) var volume: Double = 1
    /// Transient, dismissible playback problem. Never blocks the UI.
    var notice: String?

    // MARK: Engines

    private let local = LocalAudioEngine()
    private let stream = StreamAudioEngine()
    let embed = EmbedAudioEngine()
    private let nowPlaying = NowPlayingManager.shared

    @ObservationIgnored private var consecutiveFailures = 0
    /// A seek waiting on the engine to report how long the item is.
    @ObservationIgnored private var pendingSeek: Task<Void, Never>?
    /// Recordings already retried by their other route, so a broken one falls
    /// through to the next track rather than looping between two dead ends.
    @ObservationIgnored private var triedAlternates: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored static let volumeKey = "player.volume"

    /// `defaults` is injectable so tests never touch the user's real settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.volumeKey) as? Double
        volume = stored ?? 0.8
        local.setVolume(volume)
        stream.setVolume(volume)
        embed.setVolume(volume)

        local.onFinished = { [weak self] in self?.handleTrackFinished() }
        local.onFailure = { [weak self] message in self?.handleLocalFailure(message) }
        local.onStateChange = { [weak self] in self?.publishNowPlaying() }
        stream.onStateChange = { [weak self] in
            self?.handleStreamStateChange()
        }
        embed.onStateChange = { [weak self] in self?.handleEmbedStateChange() }
        embed.onFinished = { [weak self] in self?.handleTrackFinished() }

        nowPlaying.onPlay = { [weak self] in self?.resume() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.toggle() }
        nowPlaying.onNext = { [weak self] in self?.next() }
        nowPlaying.onPrevious = { [weak self] in self?.previous() }
        nowPlaying.onSeek = { [weak self] position in self?.seek(to: position) }
        nowPlaying.activate()
    }

    // MARK: - Derived state

    var isPlaying: Bool {
        switch source {
        case .local: local.isPlaying
        case .stream: stream.state == .playing || stream.state == .buffering
        case .embed: embed.state == .playing || embed.state == .loading
        case .none: false
        }
    }

    /// Polled only by the backdrop; audio callbacks never invalidate the player UI.
    func audioLevel() -> Float {
        guard isPlaying, !isBuffering, volume > 0 else { return 0 }
        let level: Float
        switch source {
        case .local: level = local.audioLevel()
        case .stream: level = stream.audioLevel()
        case .embed, .none: level = 0
        }
        return level * Float(volume)
    }

    var isBuffering: Bool {
        (source == .stream && stream.state == .buffering)
            || (source == .embed && embed.state == .loading)
    }

    /// Where an archived episode is actually hosted, for on-screen credit.
    var embedProvider: EmbedProvider? {
        source == .embed ? current?.embedProvider : nil
    }

    var streamError: String? {
        if case .failed(let message) = stream.state { return message }
        if case .failed(let message) = embed.state, source == .embed { return message }
        return nil
    }

    var isLive: Bool { current?.isLive ?? false }

    var position: TimeInterval {
        switch source {
        case .local: local.position
        case .embed: embed.position
        default: 0
        }
    }

    var duration: TimeInterval {
        switch source {
        case .local: local.duration > 0 ? local.duration : (current?.duration ?? 0)
        case .embed: embed.duration
        default: 0
        }
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    var canSeek: Bool { (source == .local || source == .embed) && duration > 0 }
    var canSkipNext: Bool { source != .stream && queue.hasNext }
    var canSkipPrevious: Bool { source != .stream && (queue.hasPrevious || position > 0) }
    var hasSomethingLoaded: Bool { current != nil }

    /// True when this item is the one currently loaded in an engine.
    func isCurrent(_ itemID: String) -> Bool { current?.id == itemID }

    // MARK: - Commands

    /// Plays a list of local tracks, starting at `index`. Any live stream stops.
    func play(_ items: [MediaItem], startingAt index: Int = 0) {
        guard !items.isEmpty else { return }
        consecutiveFailures = 0
        queue.load(items, startingAt: index)
        startCurrent(autoplay: true)
    }

    /// Plays a live station. The queue collapses to that single item.
    func playRadio(_ item: MediaItem) {
        consecutiveFailures = 0
        queue.loadSingle(item)
        startCurrent(autoplay: true)
    }

    /// Plays an archived NTS episode through its host's embed widget.
    func playEpisode(_ item: MediaItem) {
        consecutiveFailures = 0
        queue.loadSingle(item)
        startCurrent(autoplay: true)
    }

    func toggle() {
        switch source {
        case .local:
            local.isPlaying ? local.pause() : local.play()
        case .stream:
            switch stream.state {
            case .playing, .buffering:
                stream.pause()
            case .paused, .failed, .idle:
                if let url = current?.playbackURL {
                    stream.state == .paused ? stream.resume() : stream.play(url: url)
                }
            }
        case .embed:
            switch embed.state {
            case .playing, .loading:
                embed.pause()
            case .paused:
                embed.play()
            case .failed, .idle:
                embed.retry()
            }
        case .none:
            if queue.current != nil { startCurrent(autoplay: true) }
        }
        publishNowPlaying()
    }

    func resume() {
        guard !isPlaying else { return }
        toggle()
    }

    func pause() {
        guard isPlaying else { return }
        toggle()
    }

    func next() {
        guard source != .stream else { return }
        guard queue.advance() != nil else {
            pause()
            seekActiveEngine(to: 0)
            publishNowPlaying()
            return
        }
        startCurrent(autoplay: true)
    }

    func previous() {
        guard source != .stream else { return }
        // Restart the track first, the way every other player behaves.
        if position > 3 {
            seekActiveEngine(to: 0)
            publishNowPlaying()
            return
        }
        guard queue.rewind() != nil else {
            seekActiveEngine(to: 0)
            publishNowPlaying()
            return
        }
        startCurrent(autoplay: true)
    }

    func seek(to seconds: TimeInterval) {
        guard canSeek else { return }
        seekActiveEngine(to: seconds)
        publishNowPlaying()
    }

    private func seekActiveEngine(to seconds: TimeInterval) {
        switch source {
        case .local: local.seek(to: seconds)
        case .embed: embed.seek(to: seconds)
        default: break
        }
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(1, max(0, fraction)))
    }

    /// Drops the playhead into an item that has only just been handed over.
    /// Jumping to a track inside an archived broadcast is one gesture for the
    /// listener and two for the player: the duration a seek is clamped against
    /// does not exist until the asset has been read.
    func seekWhenReady(to seconds: TimeInterval, in itemID: String) {
        guard seconds > 0 else { return }
        pendingSeek?.cancel()
        if canSeek, isCurrent(itemID) {
            seek(to: seconds)
            return
        }
        pendingSeek = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, self.isCurrent(itemID) else { return }
                if self.canSeek {
                    self.seek(to: seconds)
                    return
                }
            }
        }
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        local.setVolume(volume)
        stream.setVolume(volume)
        embed.setVolume(volume)
        defaults.set(volume, forKey: Self.volumeKey)
    }

    func retryStream() {
        if source == .embed {
            embed.retry()
            return
        }
        guard let url = current?.playbackURL, current?.isLive == true else { return }
        stream.play(url: url)
    }

    /// Stops everything and clears the bar. Used when the library disappears.
    func stopAll() {
        local.stop()
        stream.stop()
        embed.stop()
        queue.clear()
        current = nil
        source = .none
        publishNowPlaying()
    }

    // MARK: - Engine switching

    private func startCurrent(autoplay: Bool) {
        guard let item = queue.current else { return }
        pendingSeek?.cancel()
        current = item

        if item.isLive {
            local.stop()
            embed.stop()
            source = .stream
            stream.play(url: item.playbackURL)
        } else if let provider = item.embedProvider {
            local.stop()
            stream.stop()
            source = .embed
            embed.load(provider: provider, url: item.playbackURL, autoplay: autoplay)
        } else {
            stream.stop()
            embed.stop()
            source = .local
            local.load(url: item.playbackURL, knownDuration: item.duration, autoplay: autoplay)
            if let upcoming = queue.next, upcoming.embedProvider == nil, !upcoming.isLive {
                local.prepare(url: upcoming.playbackURL)
            }
        }
        publishNowPlaying()
    }

    // MARK: - Engine callbacks

    private func handleTrackFinished() {
        consecutiveFailures = 0
        next()
    }

    private func handleLocalFailure(_ message: String) {
        // A station that mirrors its archive gets one attempt at the mirror
        // before this is called a failure. Older files go missing far more
        // often than the copies on SoundCloud and Mixcloud do.
        if retryUsingAlternate() { return }

        consecutiveFailures += 1
        let name = current?.title ?? "That file"
        notice = "\(name) couldn't be played. \(message)"

        guard consecutiveFailures < 5, queue.hasNext else {
            local.stop()
            publishNowPlaying()
            return
        }
        next()
    }

    /// Called when a provider refuses a particular recording, so whatever
    /// offered it can stop offering it. Set by the app; the player has no
    /// business knowing where the catalogue lives.
    var onUnplayableRecording: ((URL) -> Void)?

    private func handleEmbedStateChange() {
        if case .failed(let message) = embed.state {
            if retryUsingAlternate() { return }

            // One locked-down video should not end the listening. A release
            // carries eight of them and the next is usually fine, so a
            // recording the provider will not play is skipped the way a
            // scratched track is — noted, and moved past.
            if embed.lastFailureIsRecordingSpecific, let url = current?.playbackURL {
                // So it is never offered again. Being shown something and
                // watching it skip itself is worse than never being offered
                // it at all.
                onUnplayableRecording?(url)
            }
            if embed.lastFailureIsRecordingSpecific, queue.hasNext {
                notice = "Skipped \(current?.title ?? "a track"). \(message)"
                next()
                return
            }
            notice = "\(current?.title ?? "This episode") couldn't be played. \(message)"
        }
        publishNowPlaying()
    }

    /// Restarts the current recording by whatever other route its provider
    /// published. Answers whether there was one left to try.
    private func retryUsingAlternate() -> Bool {
        guard let item = current,
              !triedAlternates.contains(item.id),
              let alternate = item.usingAlternate()
        else { return false }
        triedAlternates.insert(item.id)
        queue.replaceCurrent(with: alternate)
        startCurrent(autoplay: true)
        return true
    }

    private func handleStreamStateChange() {
        if case .failed(let message) = stream.state {
            // Four stations stream through here now, so the notice names the
            // one that actually dropped.
            let station = current.map { NowPlayingSummary.sourceLabel(for: $0) } ?? "The stream"
            notice = "\(station) is unavailable. \(message)"
        }
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        nowPlaying.update(
            item: current,
            isPlaying: isPlaying,
            position: position,
            duration: duration,
            canSkip: source != .stream && queue.items.count > 1
        )
    }
}
