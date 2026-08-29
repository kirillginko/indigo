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
        let collaborators = profile.related.filter { artist in
            artist.reasons.contains { $0.kind == .collaborator || $0.kind == .appearsOnRelease }
        }
        let projects = profile.related.filter { artist in
            artist.reasons.contains { $0.kind == .aliasOrProject }
        }
        let labelArtists = profile.related.filter { artist in
            !collaborators.contains(where: { $0.id == artist.id })
                && !projects.contains(where: { $0.id == artist.id })
                && artist.reasons.contains { $0.kind == .sharedLabel }
        }
        let soundArtists = profile.related.filter { artist in
            !collaborators.contains(where: { $0.id == artist.id })
                && !labelArtists.contains(where: { $0.id == artist.id })
                && artist.reasons.contains { $0.kind == .sharedStyle }
        }
        let personalArtists = profile.related.filter { artist in
            !collaborators.contains(where: { $0.id == artist.id })
                && !labelArtists.contains(where: { $0.id == artist.id })
                && !soundArtists.contains(where: { $0.id == artist.id })
                && artist.reasons.contains { $0.kind == .sharedBroadcast || $0.kind == .sharedCollection }
        }
        let eraArtists = profile.related.filter { artist in
            !collaborators.contains(where: { $0.id == artist.id })
                && !projects.contains(where: { $0.id == artist.id })
                && !labelArtists.contains(where: { $0.id == artist.id })
                && !soundArtists.contains(where: { $0.id == artist.id })
                && !personalArtists.contains(where: { $0.id == artist.id })
        }

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
                    HStack(alignment: .top, spacing: 26) {
                        ArtworkView(remoteURL: profile.imageURL, side: 220, glyphScale: 0.24)
                            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
                        VStack(alignment: .leading, spacing: 20) {
                            DigTallies(entries: [
                                ("Your library", "\(profile.libraryTrackCount)"),
                                ("Your crate", "\(profile.crateCount)"),
                                ("Radio", "\(profile.radioAppearances.reduce(0) { $0 + $1.count })")
                            ])
                            VStack(alignment: .leading, spacing: 12) {
                                if let realName = profile.realName, realName != profile.name {
                                    DigSection(title: "Name") { DigLine(text: realName) }
                                }
                                if let biography = profile.biography, !biography.isEmpty {
                                    DigSection(title: "Profile") {
                                        Text(biography)
                                            .font(Typeface.body(12.5))
                                            .foregroundStyle(Palette.inkMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 5)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let discogsURL = profile.discogsURL {
                        Link(destination: discogsURL) {
                            HStack(spacing: 7) {
                                Text("Data provided by Discogs")
                                    .microLabel(1.2, size: 9)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Palette.inkFaint)
                        }
                        .buttonStyle(.plain)
                    }

                    if !profile.styles.isEmpty || !profile.genres.isEmpty || !profile.aliases.isEmpty {
                        HStack(alignment: .top, spacing: 34) {
                            if !profile.styles.isEmpty || !profile.genres.isEmpty {
                                DigSection(title: "Genres / styles") {
                                    Text((profile.styles + profile.genres).joined(separator: " · "))
                                        .font(Typeface.mono(10))
                                        .foregroundStyle(Palette.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.top, 5)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !profile.aliases.isEmpty {
                                DigSection(title: "Aliases") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(profile.aliases, id: \.self) { alias in
                                            DigLine(text: alias) {
                                                appState.open(.digArtist(mbid: nil, name: alias))
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

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

                    if !profile.releases.isEmpty {
                        DigSection(title: "Browse releases", trailing: "\(profile.releases.count)") {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 18, alignment: .top)],
                                alignment: .leading,
                                spacing: 22
                            ) {
                                ForEach(profile.releases.prefix(24)) { release in
                                    DigReleaseTile(release: release) {
                                        openRelease(release)
                                    }
                                }
                            }
                            .padding(.top, 14)
                        }
                    }

                    HStack(alignment: .top, spacing: 34) {
                        VStack(alignment: .leading, spacing: 26) {
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
                                                if let mbid = label.mbid {
                                                    appState.open(.digLabel(mbid: mbid, name: label.name))
                                                } else {
                                                    appState.open(.digDiscogsLabel(name: label.name))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !profile.related.isEmpty {
                        DigSection(title: "Continue digging", trailing: "\(profile.related.count) routes") {
                            VStack(alignment: .leading, spacing: 22) {
                                connectionLane("Collaborators", artists: collaborators)
                                connectionLane("Aliases & projects", artists: projects)
                                connectionLane("Label neighbours", artists: labelArtists)
                                connectionLane("Same frequency", artists: soundArtists)
                                connectionLane("Heard together", artists: personalArtists)
                                connectionLane("Same era", artists: eraArtists)
                            }
                            .padding(.top, 14)
                        }
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

    private func openRelease(_ release: ArtistProfile.ReleaseLine) {
        if let id = release.discogsID {
            appState.open(.digRelease(id: id, title: release.title))
            return
        }
        Task {
            guard let id = await dig.resolveRelease(title: release.title, artist: artistName) else { return }
            appState.open(.digRelease(id: id, title: release.title))
        }
    }

    @ViewBuilder
    private func connectionLane(_ title: String, artists: [RelatedArtist]) -> some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .microLabel(1.4, size: 9)
                    .foregroundStyle(Palette.inkMuted)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(artists.prefix(12)) { peer in
                        ConnectionExplainer(artist: peer) {
                            appState.open(.digArtist(mbid: peer.mbid, name: peer.name))
                        }
                    }
                }
            }
        }
    }
}
