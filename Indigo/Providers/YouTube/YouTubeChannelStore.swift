//
//  YouTubeChannelStore.swift
//  Indigo
//
//  The YouTube channels Indigo follows, read from Indigo's own database.
//
//  The app never asks YouTube for a channel. The backend reads each followed
//  channel every hour through the Data API (see supabase/functions/_shared/
//  youtube.ts) and files it the way a station is filed: the channel as a show,
//  each playlist as a broadcast, each upload as a line of its tracklist. So
//  this is three reads of tables the app already reads for radio, and the API
//  key and its quota stay on the server.
//

import Foundation
import Observation

@Observable
final class YouTubeChannelStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool { self == .loading }
        var error: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    static let providerID = "youtube"

    private(set) var channels: [Catalog.RadioShow] = []
    private(set) var channelsPhase: Phase = .idle
    private(set) var lists: [UUID: [Catalog.RadioEpisode]] = [:]
    private(set) var tracks: [UUID: [Catalog.EpisodeTrack]] = [:]
    private(set) var loading: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]

    /// The last search answered, and for which normalized query — so a
    /// slow answer to an old query never replaces a newer one.
    private(set) var searchQuery = ""
    private(set) var searchHits: [Catalog.ArchiveHit] = []
    private(set) var searchPhase: Phase = .idle

    @ObservationIgnored private let repository = RadioRepository.shared

    /// Searches every archive's uploads by artist and title.
    ///
    /// `query` is normalized here, with the rules the stored keys were
    /// written with, so the database compares like with like. Under two
    /// characters is not a search: it would match most of the archive.
    /// Asks, and if the answer is a failure rather than a cancellation, asks
    /// once more before saying so.
    ///
    /// The app's database role stops any statement at three seconds, and the
    /// first search after the database has been idle can come close: its rows
    /// are on disk. The second asking finds them in memory — which is what the
    /// listener was doing by hand when a search had to be typed twice.
    private func searchOnceMore(_ query: String) async throws -> [Catalog.ArchiveHit] {
        do {
            return try await repository.searchArchives(query)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(300))
            return try await repository.searchArchives(query)
        }
    }

    func search(_ text: String) async {
        let query = RecordingKey.normalize(text)
        guard query.count >= 2 else {
            searchQuery = ""
            searchHits = []
            searchPhase = .idle
            return
        }
        guard query != searchQuery || searchPhase.error != nil else { return }
        searchPhase = .loading
        do {
            let hits = try await searchOnceMore(query)
            // Typing on while this was in flight cancels the task that asked.
            guard !Task.isCancelled else { return }
            searchQuery = query
            searchHits = hits
            searchPhase = .loaded
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            searchQuery = query
            searchHits = []
            searchPhase = .failed(error.localizedDescription)
        }
    }

    func loadChannelsIfNeeded() async {
        guard channels.isEmpty, !channelsPhase.isLoading else { return }
        await loadChannels()
    }

    func loadChannels() async {
        channelsPhase = .loading
        do {
            channels = try await repository.shows(provider: Self.providerID)
            channelsPhase = .loaded
        } catch is CancellationError {
            channelsPhase = .idle
        } catch {
            channelsPhase = .failed(error.localizedDescription)
        }
    }

    func channel(id: UUID) -> Catalog.RadioShow? {
        channels.first { $0.id == id }
    }

    /// A channel's shelves: its uploads first, then its playlists by title.
    ///
    /// Uploads first because it is the whole of what the channel posts, and a
    /// curator's playlists are regroupings of it.
    func shelves(of channelID: UUID) -> [Catalog.RadioEpisode] {
        (lists[channelID] ?? []).sorted { lhs, rhs in
            let lhsUploads = Self.isUploads(lhs), rhsUploads = Self.isUploads(rhs)
            if lhsUploads != rhsUploads { return lhsUploads }
            return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
        }
    }

    func loadChannelIfNeeded(id: UUID) async {
        await loadChannelsIfNeeded()
        guard lists[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        errors[id] = nil
        defer { loading.remove(id) }
        do {
            lists[id] = try await repository.episodes(ofShow: id, limit: 100)
        } catch is CancellationError {
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    func loadTracksIfNeeded(shelf id: UUID) async {
        guard tracks[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        errors[id] = nil
        defer { loading.remove(id) }
        do {
            tracks[id] = try await repository.tracklist(forEpisode: id)
        } catch is CancellationError {
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    func isLoading(_ id: UUID) -> Bool { loading.contains(id) }
    func error(_ id: UUID) -> String? { errors[id] }

    /// A channel's uploads list shares its id with the channel: "UU…" for "UC…".
    static func isUploads(_ shelf: Catalog.RadioEpisode) -> Bool {
        shelf.externalID.hasPrefix("UU")
    }
}

// MARK: - Playing

enum YouTubeChannelPlayback {
    /// A line of a curator's list as something the player can queue.
    ///
    /// Nil for a line with no address, or one that is not a YouTube video —
    /// nothing is offered that the player would only fail on.
    static func media(for track: Catalog.EpisodeTrack, channel: String) -> MediaItem? {
        guard let address = track.mediaURL, let url = URL(string: address),
              let videoID = YouTubeLink.videoID(from: url) else { return nil }
        let title = track.rawTrackTitle ?? track.rawArtistName ?? "Untitled"
        return MediaItem(
            id: mediaID(videoID),
            sourceID: "youtube",
            kind: .track,
            title: title,
            subtitle: track.artistName ?? track.rawArtistName,
            // Not the channel. Crating from the player bar reads `detail` as
            // the release, and a channel is not an album.
            detail: nil,
            remoteArtworkURL: thumbnail(videoID),
            playbackURL: url,
            embedProvider: .youtube
        )
    }

    static func mediaID(_ videoID: String) -> String { "youtube.video.\(videoID)" }

    /// The still YouTube publishes for every video. A URL rather than a
    /// download — see `ArtworkView`; Indigo does not re-host images.
    ///
    /// `mqdefault`, the 16:9 cut. `hqdefault` is 4:3 with the picture
    /// letterboxed inside it, which drew black bars above and below the frame.
    static func thumbnail(_ videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    static func videoID(of track: Catalog.EpisodeTrack) -> String? {
        track.mediaURL.flatMap(URL.init(string:)).flatMap(YouTubeLink.videoID(from:))
    }

    /// Plays a shelf from the pressed line, so it carries on through the
    /// curator's order — which is the sequence the recommendations are read
    /// from, too.
    @MainActor
    static func play(_ track: Catalog.EpisodeTrack, in shelf: [Catalog.EpisodeTrack],
                     channel: String, using player: PlaybackCoordinator) {
        let items = shelf.compactMap { media(for: $0, channel: channel) }
        guard let pressed = videoID(of: track) else { return }
        if player.isCurrent(mediaID(pressed)) {
            player.toggle()
            return
        }
        let index = items.firstIndex { $0.id == mediaID(pressed) } ?? 0
        player.play(items, startingAt: index)
    }
}
