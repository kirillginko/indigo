//
//  DiscoverSection.swift
//  Indigo
//
//  DIG's Discover: a short list of tracks to hear, at the top of DIG. Play
//  is the first thing on every row and is only there because the track was
//  checked to play; the artist and the episode are the way on from it.
//  Development builds only (`TrackDiscoveryFeature`).
//

import SwiftUI

struct DiscoverSection: View {
    @Environment(DigStore.self) private var dig
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(\.isPhoneLayout) private var isPhone
    /// When DIG opened, for the time it takes to hear something new.
    @State private var opened = Date()

    private var tracks: [DiscoveredTrack] { dig.discover.tracks }
    private var recordings: [DiscoveredTrack] { tracks.filter { if case .recording = $0.source { true } else { false } } }

    var body: some View {
        DigSection(title: "Discover", trailing: dig.discover.working && tracks.isEmpty ? "Listening around…" : tracks.isEmpty ? nil : "\(tracks.count) tracks") {
            VStack(alignment: .leading, spacing: isPhone ? 14 : 10) {
                if !recordings.isEmpty {
                    Button { play(recordings, from: 0) } label: {
                        Label("Play \(recordings.count) recordings", systemImage: "play.fill")
                            .font(Typeface.mono(12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isPhone ? Chip.green : Palette.accent)
                }
                ForEach(tracks) { track in
                    DiscoverRow(track: track) {
                        if case .recording = track.source, let index = recordings.firstIndex(where: { $0.id == track.id }) {
                            play(recordings, from: index)
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
        .pageGutter()
        .padding(.top, 22)
        .task { opened = Date(); await dig.refreshDiscover() }
    }

    /// Recordings as a queue, from the one pressed.
    private func play(_ queue: [DiscoveredTrack], from index: Int) {
        mark(queue[index])
        player.play(queue.map(\.mediaItem.item), startingAt: index)
    }

    /// One episode track, from the moment it was played.
    private func play(_ track: DiscoveredTrack) {
        mark(track)
        let (item, start) = track.mediaItem
        if !player.isCurrent(item.id) { player.play([item]) }
        if let start { player.seekWhenReady(to: TimeInterval(start), in: item.id) }
    }

    private func mark(_ track: DiscoveredTrack) {
        let seconds = Date().timeIntervalSince(opened)
        Trace.step("dig.discover.play", "\(track.artist) — \(track.title) after \(String(format: "%.1f", seconds))s") {}
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
        case .recording(_, let channel): return channel.map { "Recording · \($0)" } ?? "Recording"
        case .episode(let listen, let at):
            let date = listen.airedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).year()) }
            let moment = at > 0 ? "at \(at / 60):\(String(format: "%02d", at % 60))" : nil
            return [listen.showTitle ?? listen.episodeTitle, date, moment].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: play) {
                ZStack {
                    ArtworkView(remoteURL: track.artworkURL, side: isPhone ? 64 : 52, glyphScale: 0.3)
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title) by \(track.artist)")
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(Typeface.body(isPhone ? 15 : 13.5, weight: .medium))
                    .lineLimit(2)
                Button(action: artist) {
                    Text(track.artist).font(Typeface.mono(isPhone ? 12.5 : 11)).underline()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the artist in DIG")
                if case .episode = track.source {
                    Button(action: episode) { Text(whereFrom).font(Typeface.mono(10.5)) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the episode")
                } else {
                    Text(whereFrom).font(Typeface.mono(10.5))
                }
                Text(track.reason)
                    .font(Typeface.mono(10.5))
                    .opacity(0.65)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isPhone ? Color.white : Palette.ink)
            Spacer(minLength: 0)
        }
    }
}
