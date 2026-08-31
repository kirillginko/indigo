//
//  SceneDigView.swift
//  Indigo
//
//  A place and a stretch of time.
//
//  The spec's SCENE: Berlin 2010–2016, and the labels, artists and tags that
//  clustered there. Everything on this page is assembled from evidence the
//  app already holds — where a catalogue says an artist began, what they
//  tagged their own records with, when those records came out — rather than
//  from anybody's opinion about what a scene was.
//

import SwiftUI

struct SceneDigView: View {
    let city: String

    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig

    /// Gathered in a task, like every other page here. Reading it during the
    /// render pass reads most of the store.
    @State private var scene: MusicScene?
    @State private var hasGathered = false

    var body: some View {
        let _ = dig.revision
        let scene = scene

        VStack(spacing: 0) {
            PageHeader(
                title: scene?.title ?? city.uppercased(),
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: scene?.eraLabel ?? "Scene"
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

                        DeepSectionView(origin: scene.node) { appState.open($0) }
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
                WorkingPane()
            }
        }
        .task(id: city) {
            self.scene = SceneEngine(context: dig.context).scene(city: city)
            hasGathered = true
        }
        .task(id: dig.revision) {
            self.scene = SceneEngine(context: dig.context).scene(city: city)
        }
    }
}