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
                        WorkingPane()
                    } else if dig.isEnriching {
                        WorkingBar()
                    }
                    if let profile {
                        DigTallies(entries: [
                            ("Catalogue", "\(profile.catalogueSize)"),
                            ("Your library", "\(profile.libraryTrackCount)"),
                            ("Your crate", "\(profile.crateCount)"),
                            ("Radio", "\(profile.radioAppearances)")
                        ])

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
                                        DigLine(text: title)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        catalogue
                        deepCuts
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
        .task(id: dig.revision) {
            self.profile = dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            readCatalogue()
        }
        .task(id: labelMBID) {
            self.profile = dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            readCatalogue()
            await dig.enrichLabel(mbid: labelMBID)
            self.profile = dig.labelProfile(mbid: labelMBID, fallbackName: labelName)
            readCatalogue()
            hasEnriched = true
        }
    }

    private func node(_ profile: LabelProfile) -> MusicNode {
        .label(profile.name, mbid: labelMBID)
    }

    @State private var catalogueNumbers: [MusicGraph.Connection] = []
    @State private var undergroundCuts: [DeepResult] = []

    private func readCatalogue() {
        let subject = node(profile ?? LabelProfile(
            name: labelName, mbid: labelMBID, origin: nil, founded: nil, artists: [],
            releases: [], catalogueSize: 0, libraryTrackCount: 0, crateCount: 0,
            radioAppearances: 0
        ))
        catalogueNumbers = dig.connections(from: subject)
            .filter { $0.to.kind == .catalogNumber }
            .sorted { lhs, rhs in
                let left = CatalogNumber.split(lhs.to.title)
                let right = CatalogNumber.split(rhs.to.title)
                guard let left, let right, left.prefix == right.prefix else {
                    return lhs.to.title < rhs.to.title
                }
                return left.number < right.number
            }
        undergroundCuts = DeepEngine(context: dig.context).results(from: subject, at: .underground)
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

    /// The spec's DEEP CUTS: the end of the catalogue nobody arrives at by
    /// accident — small pressings, white labels, the records a label puts out
    /// and never mentions again.
    @ViewBuilder
    private var deepCuts: some View {
        let cuts = undergroundCuts
        if !cuts.isEmpty {
            DigSection(title: "Deep cuts", trailing: "\(cuts.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cuts) { cut in
                        DigLine(
                            text: cut.node.title,
                            detail: [
                                cut.signals.releaseKind == .unknown
                                    ? nil : cut.signals.releaseKind.label,
                                cut.node.subtitle
                            ].compactMap { $0 }.joined(separator: " · "),
                            action: cut.node.destination.map { page in { appState.open(page) } }
                        )
                        Rule()
                    }
                }
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
