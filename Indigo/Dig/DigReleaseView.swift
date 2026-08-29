//
//  DigReleaseView.swift
//  Indigo
//

import SwiftUI

struct DigReleaseView: View {
    let releaseID: Int
    let fallbackTitle: String

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    var body: some View {
        let profile = dig.releaseProfile(id: releaseID)

        VStack(spacing: 0) {
            PageHeader(
                title: profile?.title ?? fallbackTitle,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            )
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if dig.isEnriching { BufferingGlyph().accessibilityLabel("Loading release") }
                    if let profile {
                        HStack(alignment: .top, spacing: 26) {
                            ArtworkView(remoteURL: profile.imageURL, side: 240, glyphScale: 0.23)
                                .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                            VStack(alignment: .leading, spacing: 24) {
                                if !profile.artists.isEmpty {
                                    DigSection(title: "Artists") {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(profile.artists, id: \.self) { artist in
                                                DigLine(text: artist) {
                                                    appState.open(.digArtist(mbid: nil, name: artist))
                                                }
                                            }
                                        }
                                    }
                                }
                                if !profile.labels.isEmpty {
                                    DigSection(title: "Labels") {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(Array(profile.labels.enumerated()), id: \.offset) { _, label in
                                                DigLine(text: label.name, detail: label.catalogNumber) {
                                                    appState.open(.digDiscogsLabel(name: label.name))
                                                }
                                            }
                                        }
                                    }
                                }
                                if !profile.genres.isEmpty || !profile.styles.isEmpty {
                                    DigSection(title: "Genres / styles") {
                                        Text((profile.styles + profile.genres).joined(separator: " · "))
                                            .font(Typeface.mono(10))
                                            .foregroundStyle(Palette.inkMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 5)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !profile.tracks.isEmpty {
                            DigSection(title: "Tracklist", trailing: "\(profile.tracks.count)") {
                                VStack(spacing: 0) {
                                    ForEach(profile.tracks) { track in
                                        HStack(spacing: 14) {
                                            Text(track.position.isEmpty ? "—" : track.position)
                                                .font(Typeface.mono(9.5))
                                                .foregroundStyle(Palette.inkFaint)
                                                .frame(width: 34, alignment: .leading)
                                            Text(track.title)
                                                .font(Typeface.body(12.5))
                                                .foregroundStyle(Palette.ink)
                                            Spacer(minLength: 8)
                                            if let duration = track.duration {
                                                Text(duration)
                                                    .font(Typeface.mono(9.5))
                                                    .foregroundStyle(Palette.inkFaint)
                                            }
                                        }
                                        .padding(.vertical, 7)
                                        Rule(color: Palette.outline.opacity(0.55))
                                    }
                                }
                            }
                        }

                        if let notes = profile.notes, !notes.isEmpty {
                            DigSection(title: "Release notes") {
                                Text(notes)
                                    .font(Typeface.body(12.5))
                                    .foregroundStyle(Palette.inkMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 5)
                            }
                        }

                        if !profile.related.isEmpty {
                            DigSection(title: "Continue digging", trailing: "\(profile.related.count) connections") {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                                    alignment: .leading,
                                    spacing: 12
                                ) {
                                    ForEach(profile.related.prefix(16)) { artist in
                                        ConnectionExplainer(artist: artist) {
                                            appState.open(.digArtist(mbid: artist.mbid, name: artist.name))
                                        }
                                    }
                                }
                                .padding(.top, 12)
                            }
                        }

                        if let sourceURL = profile.sourceURL {
                            Link("Data provided by Discogs", destination: sourceURL)
                                .font(Typeface.mono(9))
                                .foregroundStyle(Palette.inkFaint)
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
        .task(id: releaseID) { await dig.enrichRelease(id: releaseID) }
    }

    private func subtitle(_ profile: DigReleaseProfile?) -> String? {
        guard let profile else { return "Release" }
        var parts = profile.artists
        if let year = profile.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}
