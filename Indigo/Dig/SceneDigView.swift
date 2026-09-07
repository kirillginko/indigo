//
//  SceneDigView.swift
//  Indigo
//
//  A place and a sound.
//
//  The spec's SCENE: Berlin dub techno, and the labels, artists and tags that
//  cluster there. A city is not itself a scene — it is where several of them
//  happen — so the page is about one of them. Everything on this page is assembled from evidence the
//  app already holds — where a catalogue says an artist began, what they
//  tagged their own records with, when those records came out — rather than
//  from anybody's opinion about what a scene was.
//

import SwiftUI

struct SceneDigView: View {
    let city: String
    /// Which of the place's scenes. Nil means whichever is strongest, which is
    /// what a link naming only a city can mean now that a city holds several.
    var sound: String?

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    /// Gathered in a task, like every other page here. Reading it during the
    /// render pass reads most of the store.
    @State private var scene: MusicScene?
    @State private var hasGathered = false
    /// The rest of the scene, from the shared catalogue. The local engine can
    /// only know the artists this listener's own collection has already met —
    /// see `SceneRepository`.
    @State private var wider: [SceneRepository.Member] = []
    @State private var roster: SceneRepository.Roster?

    var body: some View {
        let _ = dig.revision
        let scene = scene

        VStack(spacing: 0) {
            PageHeader(
                title: scene?.title ?? city.uppercased(),
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                // What it sounds like, then when. A page headed by a date says
                // less about a scene than the two words that make it one.
                subtitle: scene.map { "\($0.soundLabel) · \($0.eraLabel)" } ?? "Scene"
            )
            Rule(color: Palette.outline)

            if let scene {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        DigTallies(entries: [
                            ("Artists", "\(scene.artists.count)"),
                            ("Labels", "\(scene.labels.count)"),
                            ("Radio", "\(scene.radioAppearances)"),
                            ("Your library", "\(scene.libraryTrackCount)"),
                            ("Your crate", "\(scene.crateCount)")
                        ])

                        VStack(alignment: .leading, spacing: 30) {
                            if !scene.artists.isEmpty {
                                DigSection(title: "Artists", trailing: "\(scene.artists.count)") {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(scene.artists, id: \.self) { artist in
                                            DigLine(text: artist) {
                                                appState.open(.digArtist(mbid: nil, name: artist))
                                            }
                                        }
                                    }
                                }
                            }

                            if !scene.labels.isEmpty {
                                DigSection(title: "Labels", trailing: "\(scene.labels.count)") {
                                    LazyVGrid(
                                        columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                                        alignment: .leading,
                                        spacing: 8
                                    ) {
                                        ForEach(scene.labels, id: \.self) { label in
                                            DigLine(text: label) {
                                                appState.open(.digDiscogsLabel(name: label))
                                            }
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 38)
                                            .background(Palette.wash)
                                            .overlay(
                                                Rectangle().strokeBorder(
                                                    Palette.outline,
                                                    lineWidth: Metrics.hairline
                                                )
                                            )
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !scene.tags.isEmpty {
                            DigSection(title: "Tags") {
                                TagFlow(tags: scene.tags)
                                    .padding(.top, 6)
                            }
                        }

                        DeepSectionView(origin: scene.node, isReady: hasGathered) { appState.open($0) }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            } else if hasGathered {
                EmptyStateView(
                    headline: city.uppercased(),
                    message: "Indigo hasn't gathered enough from here yet. Dig into a few artists and the scene fills in."
                ) { EmptyView() }
            } else {
                // Not yet looked is not the same as nothing found. Saying the
                // second before doing the first is a lie told quickly.
                ScrollView {
                    DigSkeleton(hasImage: false, sections: 3)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, 22)
                        // One treatment for the whole page. See `LoadingVeil`.
                        .loadingVeil(true)
                }
                .scrollIndicators(.visible)
            }
        }
        .task(id: city) {
            self.scene = await dig.scene(city: city, sound: sound)
            hasGathered = true
            await loadWiderScene()
            await rereadWiderScene()
        }
        .task(id: dig.revision) {
            self.scene = await dig.scene(city: city, sound: sound)
        }
    }

    /// Everybody else in the scene.
    ///
    /// The names the listener already has are shown in their own block above;
    /// this is the rest of it, and the two are kept apart on purpose. "You
    /// have eight of these and here are ninety more" is a scene. One list of
    /// ninety-eight with nothing to mark it is a directory.
    @ViewBuilder
    private func widerScene(mine: Set<String>) -> some View {
        let others = wider.filter { !mine.contains($0.normalizedName) }
        if !others.isEmpty {
            DigSection(
                title: "The wider scene",
                // A crawl still walking is worth showing — half a scene is
                // more than none — and worth saying so.
                trailing: roster.map { $0.isComplete ? "\(others.count)" : "\(others.count)…" }
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(others) { member in
                        DigLine(text: member.name, detail: member.evidence) {
                            appState.open(.digArtist(mbid: member.mbid, name: member.name))
                        }
                    }
                }
            }
        }
    }

    /// Asks the backend for the scene, and reads whatever it already has.
    ///
    /// Safe on every visit: the request will not queue a scene twice, and will
    /// not re-walk one filled recently. A page opened before the crawl has
    /// finished simply shows less of it and fills in next time — which is the
    /// bargain that keeps one polite crawler in place of a few hundred
    /// impolite ones.
    private func loadWiderScene() async {
        guard SupabaseService.isConfigured, let scene else { return }
        let found = try? await SceneRepository.shared.request(
            place: scene.city, sound: scene.sound
        )
        roster = found
        guard let found else { return }
        wider = (try? await SceneRepository.shared.members(rosterID: found.id)) ?? []

        // Nothing schedules the queue on its own from here, so browsing is
        // what turns it over — the same bargain a residency makes when its
        // episodes are ingested. Without this a scene asked for on a project
        // with no cron never arrives at all, and one with cron waits for the
        // next drain to come round.
        guard !found.isComplete else { return }
        Task.detached(priority: .background) {
            try? await RadioRepository.shared.drainEnrichmentQueue()
        }
    }

    /// Reads the roster again after a drain has had a chance to run.
    ///
    /// A page opened on a scene nobody has asked for before finds it empty,
    /// starts it, and would otherwise show nothing until the next visit. One
    /// look back is the difference between a scene appearing now and appearing
    /// tomorrow.
    private func rereadWiderScene() async {
        guard SupabaseService.isConfigured, let roster, !roster.isComplete else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        let refreshed = try? await SceneRepository.shared.roster(
            place: scene?.city ?? city, sound: scene?.sound
        )
        guard let refreshed, refreshed.memberCount > (self.roster?.memberCount ?? 0) else { return }
        self.roster = refreshed
        wider = (try? await SceneRepository.shared.members(rosterID: refreshed.id)) ?? []
    }
}