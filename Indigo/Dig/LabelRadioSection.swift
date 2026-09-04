//
//  LabelRadioSection.swift
//  Indigo
//
//  §10. What radio knows about a label — the thing Discogs cannot tell you.
//
//  A catalogue can say who a label released. Only the radio graph can say that
//  those records keep turning up in the same eleven shows, which is the kind of
//  fact that makes a label worth following rather than merely worth reading.
//
//  Honest about its own derivation. Right now this is reached through the
//  label's artists rather than its records, because appearances matched to
//  canonical recordings barely exist yet — so the block says "artists on this
//  label" rather than implying Indigo matched the pressings.
//

import SwiftUI

struct LabelRadioSection: View {
    let labelName: String

    @Environment(AppState.self) private var appState

    @State private var summary: Catalog.LabelRadioSummary?

    var body: some View {
        if let summary, !summary.isEmpty {
            DigSection(title: "On radio", trailing: "\(summary.appearanceCount)") {
                VStack(alignment: .leading, spacing: 20) {
                    DigTallies(entries: [
                        ("Plays", "\(summary.appearanceCount)"),
                        ("Shows", "\(summary.showCount)"),
                        ("Episodes", "\(summary.episodeCount)"),
                        ("Artists", "\(summary.artistCount)")
                    ])
                    .padding(.top, 4)

                    if summary.isViaRoster {
                        // Said out loud rather than implied. These counts are
                        // this label's artists being played, which is not the
                        // same claim as this label's records being played, and
                        // a page that blurs the two is lying quietly.
                        Text("Counted from this label's artists, not yet from matched pressings.")
                            .font(Typeface.body(11))
                            .foregroundStyle(Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !summary.topShows.isEmpty {
                        block("Played most by", summary.topShows.map {
                            ($0.displayName, $0.appearanceCount, DetailPage?.none)
                        })
                    }

                    if !summary.topArtists.isEmpty {
                        block("Most played", summary.topArtists.map { artist in
                            (artist.name ?? "Unknown", artist.appearanceCount,
                             artist.name.map { DetailPage.digArtist(mbid: nil, name: $0) })
                        })
                    }
                }
            }
            .task(id: labelName) { await load() }
        } else {
            Color.clear
                .frame(height: 0)
                .task(id: labelName) { await load() }
        }
    }

    private func block(
        _ title: String,
        _ rows: [(String, Int, DetailPage?)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .microLabel(1.4, size: 9)
                .foregroundStyle(Palette.inkFaint)
                .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DigLine(
                    text: row.0,
                    detail: row.1 > 1 ? "×\(row.1)" : nil,
                    action: row.2.map { page in { appState.open(page) } }
                )
            }
        }
    }

    private func load() async {
        guard SupabaseService.isConfigured else { return }
        do {
            // As with artists: two labels sharing a normalized name are two
            // labels, and guessing between them would put one label's radio
            // history on the other's page with nothing on screen to say so.
            let matches = try await LabelRepository.shared.labels(named: labelName)
            guard matches.count == 1, let label = matches.first else {
                summary = nil
                return
            }
            summary = try await RadioRepository.shared.summary(forLabel: label.id)
        } catch is CancellationError {
        } catch {
            summary = nil
        }
    }
}
