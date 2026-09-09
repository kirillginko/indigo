import SwiftUI

nonisolated struct DiscogsLabelProfile: Sendable {
    let name: String
    let releases: [ArtistProfile.ReleaseLine]
    let artists: [String]
    let relatedLabels: [String]
    let styles: [String]

    /// A label's own catalogue, from `labels/{id}/releases`.
    ///
    /// The artist is a field here rather than glued to the front of the
    /// title, so nothing has to be unpicked and nothing can be unpicked
    /// wrongly. Related labels are not offered: a search hit names every
    /// company on a record and this endpoint names none, and inventing
    /// neighbours out of the wrong one is what put a pressing plant on an
    /// artist's page.
    init(name: String, catalogue: [DiscogsLabelRelease]) {
        self.name = name
        var seenArtists = Set<String>()
        artists = catalogue.compactMap { entry in
            guard let value = entry.artist.map(DiscogsClient.withoutDisambiguator) else { return nil }
            let key = RecordingKey.normalizeArtist(value)
            return !key.isEmpty && ArtistName.isRealArtist(value)
                && seenArtists.insert(key).inserted ? value : nil
        }
        releases = catalogue.compactMap { entry in
            guard let id = entry.id, let title = entry.title else { return nil }
            return ArtistProfile.ReleaseLine(
                title: title, year: entry.year.map(String.init), discogsID: id,
                imageURL: nil,
                thumbnailURL: DiscogsClient.usableImage(entry.thumbnail).flatMap(URL.init(string:)),
                label: name
            )
        }
        relatedLabels = []
        styles = []
    }

    init(name: String, results: [DiscogsSearchResult]) {
        self.name = name
        var seenArtists = Set<String>()
        artists = results.compactMap { result in
            guard let divider = result.title.range(of: " - ") else { return nil }
            // "Anika (2) - Change" names an artist, and the number is
            // Discogs' filing rather than part of it.
            let value = DiscogsClient.withoutDisambiguator(String(result.title[..<divider.lowerBound]))
            let key = RecordingKey.normalizeArtist(value)
            return !key.isEmpty && seenArtists.insert(key).inserted ? value : nil
        }
        releases = results.compactMap { result in
            guard let id = result.id else { return nil }
            let title = result.title.split(separator: " - ", maxSplits: 1).last.map(String.init) ?? result.title
            return ArtistProfile.ReleaseLine(
                title: title, year: result.year, discogsID: id,
                imageURL: result.coverImage.flatMap(URL.init(string:)),
                thumbnailURL: result.thumbnail.flatMap(URL.init(string:)),
                label: result.label?.first
            )
        }
        var seenLabels = Set<String>()
        relatedLabels = results.flatMap { $0.label ?? [] }.filter {
            let key = RecordingKey.normalizeArtist($0)
            return key != RecordingKey.normalizeArtist(name) && seenLabels.insert(key).inserted
        }
        var seenStyles = Set<String>()
        styles = results.flatMap { ($0.style ?? []) + ($0.genre ?? []) }.filter {
            seenStyles.insert($0.lowercased()).inserted
        }
    }
}

struct DiscogsLabelDigView: View {
    let labelName: String
    /// Which label, where a record said so. Without it this page can only
    /// search on the name, and two labels sharing one are indistinguishable.
    var labelDiscogsID: Int?
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    var body: some View {
        let _ = crate.revision
        let profile = dig.discogsLabelProfile(named: labelName, discogsID: labelDiscogsID)
        let crateID = RecordingKey.normalizeArtist(labelName)
        let isCrated = crate.contains(dig: .label, identifier: crateID, providerID: "dig.label.discogs")
        VStack(spacing: 0) {
            PageHeader(title: labelName, breadcrumb: appState.breadcrumbTitle,
                       onBack: { appState.popDetail() }, subtitle: "Label") {
                CrateButton(isCrated: isCrated) {
                    crate.toggle(
                        dig: .label, identifier: crateID, providerID: "dig.label.discogs",
                        title: profile?.name ?? labelName, subtitle: "Label", artworkURL: nil,
                        genres: profile?.styles ?? []
                    )
                }
            }
            Rule(color: Palette.outline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if profile == nil { DigSkeleton(hasImage: false, sections: 3) }
                    if let profile {
                        DigTallies(entries: [("Catalogue", "\(profile.releases.count)"),
                                             ("Artists", "\(profile.artists.count)"),
                                             ("Related labels", "\(profile.relatedLabels.count)")])
                        EncounterSection(node: .label(profile.name))

                        if !profile.styles.isEmpty {
                            DigSection(title: "Sound") {
                                Text(profile.styles.prefix(12).joined(separator: " · "))
                                    .font(Typeface.mono(10)).foregroundStyle(Palette.inkMuted)
                                    .padding(.top, 6)
                            }
                        }
                        DigSection(title: "Browse catalogue", trailing: "\(profile.releases.count)") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 18)], spacing: 22) {
                                ForEach(profile.releases) { release in
                                    DigReleaseTile(release: release) {
                                        // Always opens. A tile that does
                                        // nothing when clicked reads as a
                                        // broken app, not as a record with no
                                        // catalogue entry.
                                        if let id = release.discogsID {
                                            appState.open(.digRelease(id: id, title: release.title))
                                        } else {
                                            appState.open(.digReleaseNamed(
                                                title: release.title, artist: release.label ?? ""
                                            ))
                                        }
                                    }
                                }
                            }.padding(.top, 14)
                        }
                        HStack(alignment: .top, spacing: 34) {
                            DigSection(title: "Artists", trailing: "\(profile.artists.count)") {
                                ForEach(profile.artists, id: \.self) { artist in
                                    DigLine(text: artist) { appState.open(.digArtist(mbid: nil, name: artist)) }
                                }
                            }
                            DigSection(title: "Related labels", trailing: "\(profile.relatedLabels.count)") {
                                ForEach(profile.relatedLabels, id: \.self) { label in
                                    DigLine(text: label) {
                                        appState.open(.digDiscogsLabel(name: label))
                                    }
                                }
                            }
                        }

                        // The same descent the MusicBrainz label page has.
                        // A label reached by name rather than by MBID is the
                        // same label, and it is usually the smaller one —
                        // which is to say the one whose catalogue is worth
                        // reading to the end.
                        DeepSectionView(
                            origin: .label(profile.name), isReady: true,
                            showing: Self.shown(profile)
                        ) { appState.open($0) }
                    }
                }
                .padding(.horizontal, Metrics.gutter).padding(.vertical, 22)
                // One treatment for the whole page. See `LoadingVeil`.
                .loadingVeil(profile == nil)
            }
        }.task(id: "\(labelName)|\(labelDiscogsID ?? 0)") {
            await dig.enrichDiscogsLabel(named: labelName, discogsID: labelDiscogsID)
        }
    }

    /// The catalogue, the roster and the neighbouring imprints — everything
    /// already printed above DEEP. See
    /// `DeepEngine.results(from:distance:showing:)`.
    private static func shown(_ profile: DiscogsLabelProfile) -> Set<String> {
        var ids: Set<String> = []
        for artist in profile.artists { ids.insert(MusicNode.artist(artist).id) }
        for label in profile.relatedLabels { ids.insert(MusicNode.label(label).id) }
        for release in profile.releases {
            ids.insert(MusicNode.release(release.title, discogsID: release.discogsID).id)
        }
        return ids
    }
}
