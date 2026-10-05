//
//  YouTubeChannelDetailView.swift
//  Indigo
//
//  One followed channel: its uploads and its playlists, each video playable
//  and each artist a way into DIG.
//
//  Played through YouTube's own player, which is shown while it plays — see
//  `RootView`. Nothing here resolves or downloads a video.
//

import SwiftUI

struct YouTubeChannelDetailView: View {
    let channelID: UUID

    @Environment(AppState.self) private var appState
    @Environment(YouTubeChannelStore.self) private var store
    @State private var selectedShelf: UUID?
    @Environment(\.isPhoneLayout) private var isPhone

    var body: some View {
        let channel = store.channel(id: channelID)
        let shelves = store.shelves(of: channelID)
        let shelf = shelves.first { $0.id == selectedShelf } ?? shelves.first

        Group {
            if isPhone {
                ArchivePhonePage(channel: channel, shelves: shelves, shelf: shelf, selectedShelf: $selectedShelf,
                                 isLoading: store.channelsPhase.isLoading || store.isLoading(channelID))
            } else {
                page(channel, shelves: shelves, shelf: shelf)
            }
        }
        .task(id: channelID) { await store.loadChannelIfNeeded(id: channelID) }
        .task(id: shelf?.id) {
            if let id = shelf?.id { await store.loadTracksIfNeeded(shelf: id) }
        }
    }

    private func page(
        _ channel: Catalog.RadioShow?,
        shelves: [Catalog.RadioEpisode],
        shelf: Catalog.RadioEpisode?
    ) -> some View {
        VStack(spacing: 0) {
            PageHeader(
                title: channel?.title ?? "Archive",
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(shelves)
            ) {
                EmptyView()
            }
            Rule(color: Palette.outline)

            if let channel {
                content(channel, shelves: shelves, shelf: shelf)
            } else if store.channelsPhase.isLoading || store.isLoading(channelID) {
                LoadingPane(label: "Loading archive")
            } else {
                EmptyStateView(
                    headline: "Archive unavailable",
                    message: store.error(channelID) ?? "Indigo no longer follows this archive."
                ) {
                    Button("Back") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private func subtitle(_ shelves: [Catalog.RadioEpisode]) -> String {
        let playlists = shelves.filter { !YouTubeChannelStore.isUploads($0) }.count
        guard playlists > 0 else { return "Archive" }
        return "\(playlists) \(playlists == 1 ? "playlist" : "playlists")"
    }

    private func content(
        _ channel: Catalog.RadioShow,
        shelves: [Catalog.RadioEpisode],
        shelf: Catalog.RadioEpisode?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 28) {
                    ArtworkView(
                        remoteURL: channel.imageURL.flatMap(URL.init(string:)),
                        side: 180,
                        placeholder: .mosaic,
                        mark: channel.title
                    )
                    .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel(text: "Archive")
                        Text(channel.title ?? "Archive")
                            .font(Typeface.display(30))
                            .tracking(-0.8)
                            .fixedSize(horizontal: false, vertical: true)
                        if let about = channel.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !about.isEmpty {
                            Text(about)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let address = channel.providerURL, let url = URL(string: address) {
                            Link("Open original", destination: url)
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                if shelves.count > 1 {
                    shelfPicker(shelves, selected: shelf?.id)
                }
                if let shelf {
                    videoList(shelf)
                } else if store.isLoading(channelID) {
                    LoadingPane(label: "Loading playlists")
                } else {
                    note("Nothing read from this archive yet. Archives are read every hour.")
                }
            }
        }
        .scrollIndicators(.visible)
    }

    private func shelfPicker(_ shelves: [Catalog.RadioEpisode], selected: UUID?) -> some View {
        VStack(spacing: 0) {
            Rule(color: Palette.outline)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(shelves) { shelf in
                        let isSelected = shelf.id == selected
                        Button { selectedShelf = shelf.id } label: {
                            Text(shelf.title ?? "Playlist")
                                .microLabel(1.2, size: 10)
                                .foregroundStyle(isSelected ? Palette.inverseInk : Palette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(isSelected ? Palette.inverse : Color.clear)
                                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            Rule()
        }
    }

    @ViewBuilder
    private func videoList(_ shelf: Catalog.RadioEpisode) -> some View {
        let tracks = store.tracks[shelf.id] ?? []
        if tracks.isEmpty {
            if store.isLoading(shelf.id) {
                LoadingPane(label: "Loading tracks")
            } else {
                note(store.error(shelf.id) ?? "Nothing in this list.")
            }
        } else {
            ArchiveTrackRows(tracks: tracks)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Typeface.mono(10))
            .foregroundStyle(Palette.inkFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 22)
            .background(Palette.wash)
    }
}

/// A list of archive lines, each playable, diggable and crateable. Shared by
/// an archive's own page and the search across all of them, so the two can
/// never disagree about what a press does.
struct ArchiveTrackRows: View {
    let tracks: [Catalog.EpisodeTrack]
    /// Which archive each line came from, for a list that spans several.
    var sources: [UUID: String] = [:]

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate

    var body: some View {
        // Read so a crate change anywhere redraws the buttons here.
        let _ = crate.revision
        LazyVStack(spacing: 0) {
            ForEach(tracks) { track in
                let videoID = YouTubeChannelPlayback.videoID(of: track)
                let address = track.mediaURL.flatMap(URL.init(string:))
                let isCurrent = videoID.map { player.isCurrent(YouTubeChannelPlayback.mediaID($0)) } ?? false
                YouTubeVideoRow(
                    track: track,
                    source: sources[track.id],
                    thumbnail: videoID.flatMap(YouTubeChannelPlayback.thumbnail),
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && player.isPlaying,
                    play: {
                        // Plays on through the list it was pressed in: the
                        // curator's order on an archive page, the results
                        // in a search.
                        YouTubeChannelPlayback.play(track, in: tracks, channel: "", using: player)
                    },
                    dig: digDestination(track).map { page in { appState.open(page) } },
                    isCrated: address.map { crate.isCrated(listening: $0) } ?? false,
                    keep: address.map { url in {
                        // As an artist page's Listen row keeps one: a
                        // recording with its artist and title, reachable
                        // through this upload.
                        crate.toggle(
                            listening: url,
                            title: track.rawTrackTitle ?? "Untitled",
                            artist: track.artistName ?? track.rawArtistName,
                            artworkURL: videoID.flatMap(YouTubeChannelPlayback.thumbnail)
                        )
                    } }
                )
                Rule()
            }
        }
    }

    /// The artist, where the line names one. By name: the crawl resolves it
    /// to the shared catalogue where it can, and DIG does the rest.
    private func digDestination(_ track: Catalog.EpisodeTrack) -> DetailPage? {
        guard let name = track.artistName ?? track.rawArtistName, !name.isEmpty else { return nil }
        return .digArtist(mbid: nil, name: name)
    }
}

private struct YouTubeVideoRow: View {
    let track: Catalog.EpisodeTrack
    let source: String?
    let thumbnail: URL?
    let isCurrent: Bool
    let isPlaying: Bool
    let play: () -> Void
    let dig: (() -> Void)?
    let isCrated: Bool
    let keep: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            // The video's own shape, rather than a square cut out of it.
            ArtworkView(remoteURL: thumbnail, side: 44, aspect: 16 / 9, placeholder: .mosaic,
                        mark: track.rawTrackTitle)
                .overlay(Rectangle().strokeBorder(
                    isCurrent ? Palette.accent : Palette.rule,
                    lineWidth: isCurrent ? 1.5 : Metrics.hairline
                ))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.rawTrackTitle ?? "Untitled")
                    .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                if let artist = track.artistName ?? track.rawArtistName {
                    Text(artist)
                        .font(Typeface.body(11.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
                if let source {
                    Text(source)
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let dig {
                DigButton(action: dig)
                    .opacity(isHovering ? 1 : 0.45)
            }

            Button(action: play) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(GlyphButtonStyle())
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            if let keep {
                // The plus every other track row keeps with, at the end of the
                // row as it is there.
                CrateGlyphButton(isCrated: isCrated, action: keep)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { isHovering = $0 }
    }
}

/// An archive on the phone: the show page, its uploads as the episodes, and
/// its playlists in boxes above them.
private struct ArchivePhonePage: View {
    let channel: Catalog.RadioShow?
    let shelves: [Catalog.RadioEpisode]
    let shelf: Catalog.RadioEpisode?
    @Binding var selectedShelf: UUID?
    let isLoading: Bool

    @Environment(AppState.self) private var appState
    @Environment(YouTubeChannelStore.self) private var store
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate

    var body: some View {
        let _ = crate.revision
        let tracks = shelf.map { store.tracks[$0.id] ?? [] } ?? []
        PhoneShowPage(
            title: channel?.title ?? "Archive",
            station: "Archive",
            imageURL: channel?.imageURL.flatMap(URL.init(string:)),
            summary: channel?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            episodes: tracks.map { episode($0, in: tracks) },
            isLoading: isLoading || shelf.map { store.isLoading($0.id) } ?? false,
            emptyMessage: shelf.flatMap { store.error($0.id) }
                ?? (channel == nil ? "Indigo no longer follows this archive." : "Nothing in this list."),
            accessory: shelves.count > 1 ? AnyView(picker) : nil
        )
    }

    private var picker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(shelves) { item in
                    let selected = item.id == shelf?.id
                    Button { selectedShelf = item.id } label: {
                        Chip(text: item.title ?? "Playlist", tone: selected ? .lead : .plain, size: 12, uppercase: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(PhoneShowPage.rowB)
    }

    private func episode(_ track: Catalog.EpisodeTrack, in tracks: [Catalog.EpisodeTrack]) -> PhoneEpisode {
        let videoID = YouTubeChannelPlayback.videoID(of: track)
        let thumbnail = videoID.flatMap(YouTubeChannelPlayback.thumbnail)
        let address = track.mediaURL.flatMap(URL.init(string:))
        let isCurrent = videoID.map { player.isCurrent(YouTubeChannelPlayback.mediaID($0)) } ?? false
        let artist = track.artistName ?? track.rawArtistName
        let play = { YouTubeChannelPlayback.play(track, in: tracks, channel: "", using: player) }
        return PhoneEpisode(
            id: track.id.uuidString,
            title: track.rawTrackTitle ?? "Untitled",
            subtitle: artist,
            imageURL: thumbnail,
            isPlayable: videoID != nil,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            play: play,
            // The row opens the artist, as DIG does; the picture plays.
            open: {
                if let artist, !artist.isEmpty {
                    appState.open(.digArtist(mbid: nil, name: artist))
                } else {
                    play()
                }
            },
            crate: address.map { url in
                AnyView(CrateGlyphButton(isCrated: crate.isCrated(listening: url)) {
                    crate.toggle(
                        listening: url,
                        title: track.rawTrackTitle ?? "Untitled",
                        artist: artist,
                        artworkURL: thumbnail
                    )
                })
            }
        )
    }
}
