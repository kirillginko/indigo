//
//  ArtistDigView.swift
//  Indigo
//
//  One artist, and every way out of them. The point of the page is not the
//  biography — it's that every line is somewhere else you can go.
//

import SwiftUI
import SwiftData

struct ArtistDigView: View {
    let artistName: String
    let artistMBID: String?

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    var body: some View {
        let profile = dig.artistProfile(name: artistName, mbid: artistMBID)

        VStack(spacing: 0) {
            PageHeader(
                title: profile.name,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            )
            Rule(color: Palette.outline)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if dig.isEnriching {
                        BufferingGlyph()
                            .accessibilityLabel("Loading")
                    }
                    if let error = dig.notice {
                        VStack(alignment: .leading, spacing: 10) {
                            NoticeStrip(text: error) { dig.notice = nil }
                            Button("Try Again") {
                                Task { await dig.retryArtist(name: artistName, mbid: artistMBID) }
                            }
                            .buttonStyle(OutlineButtonStyle())
                        }
                    }

                    DigTallies(entries: [
                        ("Your library", "\(profile.libraryTrackCount)"),
                        ("Your crate", "\(profile.crateCount)"),
                        ("Radio", "\(profile.radioAppearances.reduce(0) { $0 + $1.count })")
                    ])

                    if profile.isBare {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing to dig into yet.")
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                            Text("Indigo knows this name but hasn't found releases or label connections yet.")
                                .font(Typeface.mono(10))
                                .foregroundStyle(Palette.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    }

                    HStack(alignment: .top, spacing: 34) {
                        VStack(alignment: .leading, spacing: 26) {
                            if !profile.releases.isEmpty {
                                DigSection(title: "Releases", trailing: "\(profile.releases.count)") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.releases.prefix(12)) { release in
                                            DigLine(text: release.title, detail: release.year)
                                        }
                                    }
                                }
                            }
                            if !profile.radioAppearances.isEmpty {
                                DigSection(title: "Radio appearances") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.radioAppearances) { appearance in
                                            DigLine(
                                                text: appearance.label,
                                                detail: appearance.count > 1 ? "×\(appearance.count)" : nil
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 26) {
                            if !profile.labels.isEmpty {
                                DigSection(title: "Labels") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.labels) { label in
                                            DigLine(text: label.name) {
                                                guard let mbid = label.mbid else { return }
                                                appState.open(.digLabel(mbid: mbid, name: label.name))
                                            }
                                        }
                                    }
                                }
                            }
                            if !profile.related.isEmpty {
                                DigSection(title: "Related", trailing: "\(profile.related.count)") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.related.prefix(12)) { peer in
                                            ConnectionExplainer(artist: peer) {
                                                appState.open(.digArtist(mbid: peer.mbid, name: peer.name))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
        .task(id: artistMBID ?? artistName) {
            await dig.enrichArtist(name: artistName, mbid: artistMBID)
        }
    }

    private func subtitle(_ profile: ArtistProfile) -> String {
        [profile.origin, profile.disambiguation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
