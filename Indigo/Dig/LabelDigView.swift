//
//  LabelDigView.swift
//  Indigo
//
//  Labels are first-class here, not a field on a release. Following a label is
//  how you find the next four artists worth hearing, which is the whole reason
//  people read run-out grooves.
//

import SwiftUI

struct LabelDigView: View {
    let labelMBID: String
    let labelName: String

    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig

    /// Held rather than read in `body` — see `ArtistDigView`.
    @State private var profile: LabelProfile?
    @State private var hasEnriched = false

    var body: some View {
        let _ = crate.revision
        let profile = self.profile ?? dig.cachedLabelProfile(mbid: labelMBID)
        let isCrated = crate.contains(dig: .label, identifier: labelMBID, providerID: "dig.label.mbid")

        VStack(spacing: 0) {
            PageHeader(
                title: profile?.name ?? labelName,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: subtitle(profile)
            ) {
                CrateButton(isCrated: isCrated) {
                    crate.toggle(
                        dig: .label, identifier: labelMBID, providerID: "dig.label.mbid",
                        title: profile?.name ?? labelName, subtitle: "Label", artworkURL: nil
                    )
                }
            }
            Rule(color: Palette.outline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    // A label profile is returned even when nothing is
                    // cached, so its emptiness is not evidence of anything
                    // until the catalogue has been asked.
                    if profile == nil || (!hasEnriched && (profile?.artists.isEmpty ?? true)) {
                        DigSkeleton(hasImage: false, sections: 3)
                    }
                    if let profile {
                        DigTallies(entries: [
                            ("Catalogue", "\(profile.catalogueSize)"),
                            ("Your library", "\(profile.libraryTrackCount)"),
                            ("Your crate", "\(profile.crateCount)"),
                            ("Radio", "\(profile.radioAppearances)")
                        ])

                        EncounterSection(node: .label(profile.name, mbid: profile.mbid))

                        // What no catalogue can tell you about a label:
                        // that its records keep turning up in the same shows.
                        LabelRadioSection(labelName: profile.name)

                        HStack(alignment: .top, spacing: 34) {
                            DigSection(title: "Artists", trailing: "\(profile.artists.count)") {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(profile.artists.prefix(20)) { artist in
                                        DigLine(text: artist.name) {
                                            appState.open(.digArtist(mbid: artist.mbid, name: artist.name))
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            DigSection(title: "Releases", trailing: profile.catalogueSize > profile.releases.count
                                       ? "\(profile.releases.count) of \(profile.catalogueSize)" : nil) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(profile.releases.prefix(20), id: \.self) { title in
                                        DigLine(text: title, action: open(release: title))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        catalogue
                        DeepSectionView(
                            origin: node(profile), isReady: hasEnriched, showing: shown(profile)
                        ) { appState.open($0) }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
                // One treatment for the whole page. See `LoadingVeil`.
                // A label profile comes back even when nothing is cached, so
                // its emptiness only means something once the catalogue has
                // actually been asked for.
                .loadingVeil(profile == nil || (!hasEnriched && (profile?.artists.isEmpty ?? true)))
            }
            .scrollIndicators(.visible)
        }
        .task(id: dig.revision) {
            self.profile = await dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            await readCatalogue()
        }
        .task(id: labelMBID) {
            self.profile = await dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            await readCatalogue()
            await dig.enrichLabel(mbid: labelMBID)
            self.profile = await dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            await readCatalogue()
            hasEnriched = true
        }
    }

    private func node(_ profile: LabelProfile) -> MusicNode {
        .label(profile.name, mbid: labelMBID)
    }

    @State private var catalogueNumbers: [MusicGraph.Connection] = []
    /// Where each release in the list actually goes, by folded title.
    ///
    /// The names in `Releases` come from MusicBrainz, which knows the record
    /// exists and nothing else about it — no id, so no page. The graph knows
    /// the same catalogue from Discogs, where the records do have ids. Meeting
    /// the two on the title is what turns a column of strings into a column of
    /// records; a name we cannot place stays a name, because sending somebody
    /// to a page that will say "no catalogue has this" is a dead end with an
    /// extra step in it.
    @State private var releasePages: [String: DetailPage] = [:]
    /// Everything the walk above this page already put on it — the roster, the
    /// catalogue, the numbers — so DEEP is the part of a label nobody arrives
    /// at by accident rather than a second printing of its front page.
    @State private var catalogueNodes: Set<String> = []

    private func readCatalogue() async {
        let subject = node(profile ?? LabelProfile(
            name: labelName, mbid: labelMBID, origin: nil, founded: nil, artists: [],
            releases: [], catalogueSize: 0, libraryTrackCount: 0, crateCount: 0,
            radioAppearances: 0
        ))
        let connections = await dig.connections(from: subject)
        catalogueNodes = Set(
            connections.lazy
                .filter { $0.to.kind == .release || $0.to.kind == .catalogNumber }
                .map(\.to.id)
        )
        releasePages = connections.reduce(into: [:]) { found, connection in
            guard connection.to.kind == .release,
                  let page = connection.to.destination else { return }
            found[ArtistProfile.ReleaseLine.key(connection.to.title)] = page
        }
        catalogueNumbers = connections
            .filter { $0.to.kind == .catalogNumber }
            .sorted { lhs, rhs in
                let left = CatalogNumber.split(lhs.to.title)
                let right = CatalogNumber.split(rhs.to.title)
                guard let left, let right,
                      left.prefix == right.prefix, left.suffix == right.suffix else {
                    return lhs.to.title < rhs.to.title
                }
                return left.number < right.number
            }
    }

    /// What this page has already shown, in the graph's terms: its roster,
    /// its catalogue and its catalogue numbers.
    private func shown(_ profile: LabelProfile) -> Set<String> {
        var ids = catalogueNodes
        for artist in profile.artists {
            ids.insert(MusicNode.artist(artist.name, mbid: artist.mbid).id)
        }
        return ids
    }

    /// The page a listed release opens, when the graph could place it.
    private func open(release title: String) -> (() -> Void)? {
        guard let page = releasePages[ArtistProfile.ReleaseLine.key(title)] else { return nil }
        return { appState.open(page) }
    }

    /// The run itself. Catalogue numbers are the label's spine, and reading
    /// along one is how a pressing nobody wrote about gets found.
    ///
    /// Gathered in a task: both this and the deep cuts walk the graph, and
    /// doing that during the render pass meant the page rebuilt a label's
    /// whole catalogue on every hover.
    @ViewBuilder
    private var catalogue: some View {
        let numbers = catalogueNumbers
        if !numbers.isEmpty {
            DigSection(title: "Catalogue", trailing: "\(numbers.count)") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 116), spacing: 10)],
                    alignment: .leading, spacing: 10
                ) {
                    ForEach(numbers) { entry in
                        CatalogChip(number: entry.to.title) {
                            appState.open(.digCatalog(number: entry.to.title))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func subtitle(_ profile: LabelProfile?) -> String {
        guard let profile else { return "Label" }
        return [profile.origin, profile.founded.map { "Since \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
