//
//  KioskMoodDetailView.swift
//  Indigo
//
//  One mood, as a running order. Playing any row loads the whole playlist as
//  the queue, so a mood behaves like an album of archived shows.
//

import SwiftUI

struct KioskMoodDetailView: View {
    let moodID: String

    @Environment(AppState.self) private var appState
    @Environment(KioskBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            if let mood = browse.mood(id: moodID) {
                PageHeader(
                    title: mood.title,
                    breadcrumb: appState.breadcrumbTitle,
                    onBack: { appState.popDetail() },
                    subtitle: subtitle(mood)
                ) {
                    playAllButton(mood)
                }
                Rule(color: Palette.outline)
                content(mood)
            } else if browse.moodsPhase.isLoading {
                LoadingPane(label: "Loading mood")
            } else {
                EmptyStateView(
                    headline: "Mood unavailable",
                    message: "Kiosk is no longer publishing this playlist."
                ) {
                    Button("Back to Moods") { appState.popDetail() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .task { await browse.loadMoodsIfNeeded() }
    }

    private func content(_ mood: KioskMood) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    ArtworkView(remoteURL: mood.artworkURL, side: 180)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                    VStack(alignment: .leading, spacing: 10) {
                        MicroLabel(text: "Kiosk Mood")
                        Text(topGenres(mood).joined(separator: " · "))
                            .font(Typeface.body(12.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 26)

                Rule(color: Palette.outline)
                header
                Rule()

                ForEach(Array(mood.episodes.enumerated()), id: \.element.id) { index, episode in
                    KioskEpisodeRow(
                        index: index + 1,
                        episode: episode,
                        isCurrent: KioskPlayback.isCurrent(episode, in: player),
                        isPlaying: KioskPlayback.isPlaying(episode, in: player),
                        open: { appState.open(.kioskEpisode(slug: episode.slug)) }
                    ) {
                        KioskPlayback.toggle(episode, within: mood.episodes, using: player)
                    }
                    Rule()
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("#").microLabel(1.0).frame(width: 26, alignment: .trailing)
            Text("Show").microLabel(1.4).frame(maxWidth: .infinity, alignment: .leading)
            Text("Genres").microLabel(1.4).frame(width: 200, alignment: .leading)
            Text("Aired").microLabel(1.0).frame(width: 88, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .foregroundStyle(Palette.inkFaint)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
    }

    private func playAllButton(_ mood: KioskMood) -> some View {
        Button {
            guard let first = mood.playableEpisodes.first else { return }
            KioskPlayback.toggle(first, within: mood.episodes, using: player)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "play.fill").font(.system(size: 9))
                Text("Play All").microLabel(1.4, size: 10)
            }
            .foregroundStyle(Palette.inverseInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.inverse)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mood.playableEpisodes.isEmpty)
    }

    private func subtitle(_ mood: KioskMood) -> String {
        let count = mood.episodes.count
        return "\(count) \(count == 1 ? "show" : "shows") · Kiosk Radio"
    }

    /// Moods carry no blurb, so the genres its shows share stand in for one.
    private func topGenres(_ mood: KioskMood) -> [String] {
        var counts: [String: Int] = [:]
        for episode in mood.episodes {
            for genre in episode.genres { counts[genre, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
            .map(\.key)
    }
}
