//
//  NoodsCollectionsView.swift
//  Indigo
//
//  Collections are Noods' one-off projects — takeovers, festival broadcasts,
//  label partnerships. Each one is a set of shows that belong together.
//

import SwiftUI

struct NoodsCollectionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Collections",
                subtitle: browse.collections.isEmpty
                    ? "Takeovers and one-offs"
                    : "\(browse.collections.count) collections"
            )
            Rule(color: Palette.outline)

            if browse.collections.isEmpty, browse.collectionsPhase.isLoading {
                LoadingPane(label: "Loading collections")
            } else if browse.collections.isEmpty, let error = browse.collectionsPhase.error {
                EmptyStateView(headline: "Noods unreachable", message: error) {
                    Button("Try Again") { Task { await browse.loadCollectionsIfNeeded() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(browse.collections) { collection in
                            NoodsCollectionTile(collection: collection) {
                                appState.open(.noodsCollection(path: collection.path))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
        .task { await browse.loadCollectionsIfNeeded() }
    }
}

struct NoodsCollectionDetailView: View {
    let collectionPath: String

    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(\.isPhoneLayout) private var isPhone

    var body: some View {
        let collection = browse.collection(path: collectionPath)

        Group {
            if isPhone {
                phonePage(browse.collection(path: collectionPath))
            } else {
            VStack(spacing: 0) {
                PageHeader(
                    title: collection?.title ?? NoodsPath.slug(collectionPath)
                        .replacingOccurrences(of: "-", with: " ").capitalized,
                    breadcrumb: appState.breadcrumbTitle,
                    onBack: { appState.popDetail() },
                    subtitle: [collection?.kind, collection?.location, collection?.airedLabel]
                        .compactMap { $0 }.joined(separator: " · ")
                ) {
                    if let collection, let first = collection.shows.first(where: \.isPlayable) {
                        Button {
                            NoodsPlayback.toggle(first, within: collection.shows, using: player)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "play.fill").font(.system(size: 9))
                                Text("Play All").microLabel(1.4, size: 10)
                            }
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Palette.inverse)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Rule(color: Palette.outline)

                if let collection {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let excerpt = collection.excerpt, !excerpt.isEmpty {
                                Text(excerpt)
                                    .font(Typeface.body(12.5))
                                    .foregroundStyle(Palette.inkMuted)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, Metrics.gutter)
                                    .padding(.top, 22)
                                    .padding(.bottom, 22)
                            }

                            if collection.shows.isEmpty {
                                Text("Noods hasn't published the shows in this collection.")
                                    .font(Typeface.mono(10.5))
                                    .foregroundStyle(Palette.inkFaint)
                                    .padding(.horizontal, Metrics.gutter)
                                    .padding(.vertical, 22)
                            } else {
                                NoodsShowGrid(shows: collection.shows)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.bottom, 26)
                    }
                    .scrollIndicators(.visible)
                } else {
                    LoadingPane(label: "Loading collection")
                }
            }
            }
        }
        .task(id: collectionPath) {
            await browse.loadCollectionsIfNeeded()
            await browse.loadCollectionIfNeeded(path: collectionPath)
        }
    }
}

extension NoodsCollectionDetailView {
    fileprivate func phonePage(_ collection: NoodsCollection?) -> some View {
        let shows = collection?.shows ?? []
        return PhoneShowPage(
            title: collection?.title ?? NoodsPath.slug(collectionPath).replacingOccurrences(of: "-", with: " ").capitalized,
            station: collection?.kind ?? "Noods collection",
            host: collection?.location,
            imageURL: collection?.artworkURL,
            markURL: StationMark.logoURL(for: NoodsProvider.providerID),
            summary: collection?.excerpt,
            episodes: shows.map { s in
                PhoneEpisode(id: s.id, title: s.title, subtitle: s.artist, date: s.airedAt, genres: s.genres,
                             imageURL: s.artworkURL, isPlayable: s.isPlayable,
                             isCurrent: NoodsPlayback.isCurrent(s, in: player), isPlaying: NoodsPlayback.isPlaying(s, in: player),
                             play: { NoodsPlayback.toggle(s, within: shows, using: player) },
                             open: { appState.open(.noodsShow(path: s.path)) })
            },
            isLoading: collection == nil,
            emptyMessage: "Nothing in this collection."
        )
    }
}
