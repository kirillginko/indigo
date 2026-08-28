//
//  NowPlayingManager.swift
//  Indigo
//
//  Publishes what's playing to the system (Control Centre / Now Playing) and
//  routes the media keys back into the coordinator.
//

import Foundation
import MediaPlayer

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system Now Playing centre is process-wide, so this is a process-wide
/// singleton rather than something the coordinator owns and releases.
@MainActor
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private init() {}

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?

    private var isActivated = false
    private var artworkKey: String?
    private var artworkTask: Task<Void, Never>?

    func activate() {
        guard !isActivated else { return }
        isActivated = true

        // The command centre is process-wide. Clear anything a previous
        // instance registered before adding our own handlers.
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand] as [MPRemoteCommand] {
            command.removeTarget(nil)
        }

        center.playCommand.addTarget { [weak self] _ in
            self?.onPlay?()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onPause?()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onToggle?()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onNext?()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onPrevious?()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek?(event.positionTime)
            return .success
        }
    }

    // MARK: - Publishing

    func update(
        item: MediaItem?,
        isPlaying: Bool,
        position: TimeInterval,
        duration: TimeInterval,
        canSkip: Bool
    ) {
        let center = MPNowPlayingInfoCenter.default()
        guard let item else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            configureCommands(canSkip: false, canSeek: false)
            artworkKey = nil
            return
        }

        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.subtitle ?? ""
        info[MPMediaItemPropertyAlbumTitle] = item.detail ?? ""
        info[MPNowPlayingInfoPropertyIsLiveStream] = item.isLive
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.isLive ? 0 : position

        if item.isLive || duration <= 0 {
            info[MPMediaItemPropertyPlaybackDuration] = nil
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        if artworkIdentity(for: item) != artworkKey {
            info[MPMediaItemPropertyArtwork] = nil
            loadArtwork(for: item)
        }

        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif

        configureCommands(canSkip: canSkip, canSeek: !item.isLive && duration > 0)
    }

    private func configureCommands(canSkip: Bool, canSeek: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = canSkip
        center.previousTrackCommand.isEnabled = canSkip
        center.changePlaybackPositionCommand.isEnabled = canSeek
    }

    // MARK: - Artwork

    private func artworkIdentity(for item: MediaItem) -> String {
        item.artworkKey ?? item.remoteArtworkURL?.absoluteString ?? item.id
    }

    private func loadArtwork(for item: MediaItem) {
        let identity = artworkIdentity(for: item)
        artworkKey = identity
        artworkTask?.cancel()

        artworkTask = Task { [weak self] in
            var image: PlatformImage?
            if let key = item.artworkKey {
                image = await Task.detached(priority: .utility) {
                    ArtworkStore.shared.image(for: key)
                }.value
            } else if let url = item.remoteArtworkURL {
                if let (data, _) = try? await NetworkEnvironment.session.data(from: url) {
                    image = PlatformImage(data: data)
                }
            }
            guard let self, !Task.isCancelled, let image, self.artworkKey == identity else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
