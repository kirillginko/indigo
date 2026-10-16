//
//  DiscoverSection.swift
//  Indigo
//
//  DIG's Discover: tracks to hear, at the top of DIG and on artist pages.
//  Every row's first action plays -- "Play track" for a recording of the
//  track itself, "Hear in radio show" for the moment it was played in a show
//  -- and is only there because the track was checked to play. The artist,
//  the release and the episode are the way on. Development builds only
//  (`TrackDiscoveryFeature`).
//

import SwiftUI

/// At the top of DIG: discoveries from the listener's own starting points.
struct DiscoverSection: View {
    @Environment(DigStore.self) private var dig
    @State private var opened = Date()

    var body: some View {
        let state = dig.discover
        DigSection(title: "Discover", trailing: state.working && state.tracks.isEmpty ? "Listening around…"
                   : state.tracks.isEmpty ? nil : "\(state.tracks.count) tracks") {
            DiscoverList(tracks: state.tracks, opened: opened)
            #if DEBUG || INDIGO_INTERNAL
            // What happened after Play, on this device only: for judging it.
            let counts = DiscoverDiagnostics.shared.counts
            if counts.pressed > 0 {
                Text("Played \(counts.pressed) · began \(counts.began) · \(counts.medianSecondsToHear.map { String(format: "%.0fs", $0) } ?? "–") from opening DIG · heard out \(counts.completed) · skipped \(counts.skipped) · went on \(counts.continued) · crated \(counts.crated)")
                    .font(Typeface.mono(9.5)).opacity(0.5).padding(.top, 8)
            }
            #endif
        }
        .pageGutter()
        .padding(.top, 22)
        .task { opened = Date(); await dig.refreshDiscover() }
    }
}

/// On an artist page: a few of their own tracks, then tracks by artists the
/// record puts next to them -- the page with nothing else to offer most of all.
struct ArtistDiscoverSection: View {
    let name: String
    let discogsID: Int?
    @Environment(DigStore.self) private var dig
    @State private var opened = Date()

    var body: some View {
        let page = dig.artistPage(ArtistReference(name: name, discogsID: discogsID))
        let state = page.discogsID.flatMap { dig.artistDiscover["\($0)"] } ?? DiscoverState()
        Group {
            if !state.tracks.isEmpty || state.working {
                DigSection(title: "Listen", trailing: state.working && state.tracks.isEmpty ? "Listening around…" : nil) {
                    DiscoverList(tracks: state.tracks, opened: opened, ownArtistID: page.discogsID)
                }
            }
        }
        .task(id: page.discogsID) { opened = Date(); await dig.refreshArtistDiscover(name: name, discogsID: discogsID) }
    }
}

/// The rows, and what pressing Play does.
struct DiscoverList: View {
    let tracks: [DiscoveredTrack]
    let opened: Date
    /// On an artist page: whose page it is, so their own tracks are headed.
    var ownArtistID: Int? = nil
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(CrateService.self) private var crate
    @Environment(\.isPhoneLayout) private var isPhone

    private var recordings: [DiscoveredTrack] { tracks.filter(\.isRecording) }

    var body: some View {
        if isPhone { grid } else { list }
    }

    /// On the phone, the grid of two the rest of DIG uses: the picture,
    /// square, is the play button; what it is (a track, or a moment in a radio
    /// show) in a box at the top, its name in a box at the bottom, the reason
    /// under it. A long press goes to the artist, the release or the episode.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recordings.count > 1 {
                Button { play(recordings, from: 0) } label: {
                    Label("Play \(recordings.count) tracks", systemImage: "play.fill").font(Typeface.mono(12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chip.green)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: 2), spacing: 12) {
                ForEach(tracks) { track in
                    DiscoverTile(track: track, isOwn: ownArtistID == track.artistDiscogsID) {
                        if track.isRecording, let at = recordings.firstIndex(where: { $0.id == track.id }) {
                            play(recordings, from: at)
                        } else {
                            play(track)
                        }
                    } artist: {
                        appState.open(.digArtist(mbid: nil, name: track.artist, discogsID: track.artistDiscogsID))
                    } episode: {
                        if case .episode(let listen, _) = track.source, let page = listen.page.destination { appState.open(page) }
                    }
                }
            }
            // The grid runs to the screen's edges, as DIG's other grids do.
            .padding(.horizontal, -16)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recordings.count > 1 {
                Button { play(recordings, from: 0) } label: {
                    Label("Play \(recordings.count) tracks", systemImage: "play.fill").font(Typeface.mono(12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isPhone ? Chip.green : Palette.accent)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if let ownArtistID, index > 0, tracks[index - 1].artistDiscogsID == ownArtistID, track.artistDiscogsID != ownArtistID {
                    Text("Played and credited around them").microLabel(1.4, size: 9).opacity(0.6).padding(.top, 4)
                }
                DiscoverRow(track: track) {
                    if track.isRecording, let at = recordings.firstIndex(where: { $0.id == track.id }) {
                        play(recordings, from: at)
                    } else {
                        play(track)
                    }
                } artist: {
                    appState.open(.digArtist(mbid: nil, name: track.artist, discogsID: track.artistDiscogsID))
                } episode: {
                    if case .episode(let listen, _) = track.source, let page = listen.page.destination { appState.open(page) }
                }
            }
        }
        .padding(.top, isPhone ? 0 : 6)
    }

    /// Recordings as a queue, from the one pressed.
    private func play(_ queue: [DiscoveredTrack], from index: Int) {
        DiscoverDiagnostics.shared.pressed(Array(queue.dropFirst(index)), opened: opened, player: player, crate: crate)
        player.play(queue.map(\.mediaItem.item), startingAt: index)
    }

    /// One track in a radio show, from the moment it was played.
    private func play(_ track: DiscoveredTrack) {
        DiscoverDiagnostics.shared.pressed([track], opened: opened, player: player, crate: crate)
        let (item, start) = track.mediaItem
        if !player.isCurrent(item.id) { player.play([item]) }
        if let start { player.seekWhenReady(to: TimeInterval(start), in: item.id) }
    }
}

struct DiscoverRow: View {
    let track: DiscoveredTrack
    let play: () -> Void
    let artist: () -> Void
    let episode: () -> Void
    @Environment(\.isPhoneLayout) private var isPhone

    private var whereFrom: String {
        switch track.source {
        case .recording(_, let channel):
            if let release = track.release { return [release, track.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
            return channel.map { "Upload · \($0)" } ?? "Recording"
        case .episode(let listen, let at):
            let date = listen.airedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) }
            let moment = at > 0 ? "at \(at / 60):\(String(format: "%02d", at % 60))" : nil
            return [listen.showTitle ?? listen.episodeTitle, date, moment].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                ArtworkView(remoteURL: track.sharpArtwork.full, previewRemoteURL: track.sharpArtwork.preview,
                            side: isPhone ? 64 : 52, glyphScale: 0.3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.playLabel): \(track.title) by \(track.artist)")
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(Typeface.body(isPhone ? 15 : 13.5, weight: .medium))
                    .lineLimit(2)
                Button(action: artist) {
                    Text(track.artist).font(Typeface.mono(isPhone ? 12.5 : 11)).underline()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the artist in DIG")
                if track.isRecording {
                    Text(whereFrom).font(Typeface.mono(10.5))
                } else {
                    Button(action: episode) { Text(whereFrom).font(Typeface.mono(10.5)) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the episode")
                }
                Text(track.reason)
                    .font(Typeface.mono(10.5))
                    .opacity(0.65)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: play) {
                    Label(track.playLabel, systemImage: track.isRecording ? "play.fill" : "dot.radiowaves.left.and.right")
                        .font(Typeface.mono(11.5, weight: .medium))
                        .foregroundStyle(isPhone ? Chip.ink : Palette.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(track.isRecording ? (isPhone ? Chip.green : Palette.accent.opacity(0.25))
                                                      : (isPhone ? Color.white.opacity(0.75) : Palette.outline))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .foregroundStyle(isPhone ? Color.white : Palette.ink)
            Spacer(minLength: 0)
        }
    }
}

/// One discovery as a square tile.
struct DiscoverTile: View {
    let track: DiscoveredTrack
    var isOwn = false
    let play: () -> Void
    let artist: () -> Void
    let episode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: play) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            ArtworkView(remoteURL: track.sharpArtwork.full, previewRemoteURL: track.sharpArtwork.preview,
                                        side: proxy.size.width, glyphScale: 0.26, placeholder: .mosaic)
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Chip(text: track.isRecording ? "▶ Track" : "((•)) Radio", tone: track.isRecording ? .lead : .plain,
                             size: 10, uppercase: true)
                            .padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Chip(text: track.title, size: 12).lineLimit(2)
                            Chip(text: track.artist, tone: .lead, size: 10.5).lineLimit(1)
                        }
                        .padding(6)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.playLabel): \(track.title) by \(track.artist)")
            .accessibilityHint(track.reason)
            .contextMenu {
                Button(action: play) { Label(track.playLabel, systemImage: track.isRecording ? "play.fill" : "dot.radiowaves.left.and.right") }
                Button(action: artist) { Label("Open \(track.artist)", systemImage: "person") }
                if !track.isRecording { Button(action: episode) { Label("Open the radio show", systemImage: "dot.radiowaves.left.and.right") } }
                Text(track.reason)
            }
            Text(isOwn ? "By \(track.artist)" : track.shortReason)
                .font(Typeface.mono(9.5))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 6)
        }
    }
}
