//
//  ArtistRadioSection.swift
//  Indigo
//
//  Where have I heard this artist on radio.
//
//  Not the same question as the "Radio appearances" block above it, which is
//  the listener's own provenance — what they were tuned in for. This is
//  Indigo's whole radio record: every tracklist anyone has ingested, which
//  means it can name broadcasts nobody here was listening to.
//
//  Self-contained on purpose. The rest of the artist page is built from the
//  local graph and must render with the network off; this is the one block
//  that talks to the backend, and it draws nothing at all when there is
//  nothing to say.
//

import SwiftUI

struct ArtistRadioSection: View {
    let artistName: String
    /// What the block calls itself. On an artist's own page "On radio" is the
    /// whole claim; on a track's page it has to say whose radio history this
    /// is, because it is the artist's and not that recording's.
    var title: String = "On radio"

    @Environment(AppState.self) private var appState

    @State private var summary: Catalog.ArtistRadioSummary?
    @State private var episodes: [Catalog.RadioEpisodeGroup] = []
    @State private var relations: [Catalog.RadioRelation] = []
    @State private var isExpanded = false

    /// Enough broadcasts to show a pattern without asking for a catalogue.
    private static let collapsedEpisodes = 6
    private static let appearanceLimit = 120

    var body: some View {
        // No spinner, no empty heading, no "nothing found". An artist Indigo
        // has never heard on air should look like an artist page without a
        // radio section, not like one whose radio section failed.
        if let summary, !summary.isEmpty, !episodes.isEmpty {
            DigSection(title: title, trailing: "\(summary.appearanceCount)") {
                VStack(alignment: .leading, spacing: 22) {
                    DigTallies(entries: [
                        ("Plays", "\(summary.appearanceCount)"),
                        ("Shows", "\(summary.showCount)"),
                        ("Episodes", "\(summary.episodeCount)"),
                        ("Since", sinceLabel(summary))
                    ])
                    .padding(.top, 4)

                    if summary.topShows.count > 1 {
                        selectors(summary.topShows)
                    }

                    // Who this artist gets played next to. The one thing here
                    // that is a recommendation rather than a record, so it is
                    // the one thing that has to say what it rests on.
                    let neighbours = relations.filter { $0.relationshipType == "radio_neighbor" }
                    if !neighbours.isEmpty {
                        playedAlongside(neighbours)
                    }

                    broadcasts
                }
            }
            .task(id: artistName) { await load() }
        } else {
            // A zero-height view that still runs the load. Without it the
            // section would need the page to know in advance whether it had
            // anything to draw.
            Color.clear
                .frame(height: 0)
                .task(id: artistName) { await load() }
        }
    }

    // MARK: Pieces

    /// The programmes that play this artist most. The spec's "played by" edge,
    /// and the one that turns an artist into a set of shows worth following.
    private func selectors(_ shows: [Catalog.ArtistRadioSummary.TopShow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Played most by")
                .microLabel(1.4, size: 9)
                .foregroundStyle(Palette.inkFaint)
                .padding(.bottom, 4)
            ForEach(shows) { show in
                DigLine(
                    text: show.displayName,
                    detail: show.appearanceCount > 1 ? "×\(show.appearanceCount)" : nil,
                    action: show.provider == "nts"
                        ? { appState.open(.ntsShow(alias: show.externalID)) }
                        : nil
                )
            }
        }
    }

    /// The radio-derived DIG edge, with its evidence on the same line.
    ///
    /// The spec is explicit that a recommendation must never be opaque, and a
    /// count of independent broadcasts is the most honest thing radio can say:
    /// two selectors reaching for these back to back is a fact, not a score.
    private func playedAlongside(_ neighbours: [Catalog.RadioRelation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Played alongside")
                .microLabel(1.4, size: 9)
                .foregroundStyle(Palette.inkFaint)
                .padding(.bottom, 4)
            ForEach(neighbours.prefix(8)) { relation in
                DigLine(
                    text: relation.displayName,
                    detail: relation.reason,
                    action: { appState.open(.digArtist(mbid: nil, name: relation.displayName)) }
                )
            }
        }
    }

    private var broadcasts: some View {
        let shown = isExpanded ? episodes : Array(episodes.prefix(Self.collapsedEpisodes))

        return VStack(alignment: .leading, spacing: 18) {
            ForEach(shown) { episode in
                VStack(alignment: .leading, spacing: 0) {
                    DigLine(
                        text: episode.heading,
                        detail: episode.dateLabel,
                        action: destination(for: episode).map { page in
                            { appState.open(page) }
                        }
                    )
                    // The tracks themselves, as the show announced them.
                    // Indented because they belong to the broadcast above
                    // rather than standing beside it.
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(episode.tracks) { track in
                            HStack(spacing: 10) {
                                Text(track.trackLine)
                                    .font(Typeface.body(12))
                                    .foregroundStyle(Palette.inkMuted)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let offset = track.offsetLabel {
                                    Text(offset)
                                        .font(Typeface.mono(10))
                                        .foregroundStyle(Palette.inkFaint)
                                }
                            }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.top, 2)
                }
            }

            if episodes.count > Self.collapsedEpisodes {
                Button(isExpanded ? "Show fewer" : "All \(episodes.count) broadcasts") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(Typeface.body(11, weight: .medium))
                .foregroundStyle(Palette.inkFaint)
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard SupabaseService.isConfigured else { return }

        do {
            // Two artists can share a normalized name, and the ingest resolver
            // refuses to guess between them for exactly that reason. Guessing
            // here would put one artist's broadcasts on the other's page with
            // nothing on screen to say it had happened.
            let matches = try await ArtistRepository.shared.artists(named: artistName)
            guard matches.count == 1, let artist = matches.first else {
                summary = nil
                episodes = []
                relations = []
                return
            }

            async let summaryTask = RadioRepository.shared.summary(forArtist: artist.id)
            async let appearancesTask = RadioRepository.shared.appearances(
                forArtist: artist.id, limit: Self.appearanceLimit)
            async let relationsTask = RadioRepository.shared.relations(forArtist: artist.id)

            let (loadedSummary, appearances, loadedRelations) =
                try await (summaryTask, appearancesTask, relationsTask)
            summary = loadedSummary
            episodes = Catalog.groupedByEpisode(appearances)
            relations = loadedRelations
        } catch is CancellationError {
        } catch {
            // The rest of the page is local and already drawn. A backend that
            // is unreachable means this block has nothing to add, not that the
            // artist has no radio history.
            summary = nil
            episodes = []
            relations = []
        }
    }

    private func sinceLabel(_ summary: Catalog.ArtistRadioSummary) -> String {
        guard let first = summary.firstAppearanceAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: first)
    }

    /// Where a broadcast lives in the app, when Indigo has a page for it.
    private func destination(for episode: Catalog.RadioEpisodeGroup) -> DetailPage? {
        guard episode.provider == "nts" else { return nil }
        let parts = episode.externalID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return .ntsEpisode(show: parts[0], episode: parts[1])
    }
}
