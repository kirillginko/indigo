//
//  YouTubeChannelsView.swift
//  Indigo
//
//  The YouTube channels Indigo follows: curators uploading records that are
//  on no streaming service and no station's archive.
//
//  Which channels are followed is decided on the backend (`youtube_channels`,
//  see migration 0041), not here: a channel is read by the hourly crawl before
//  it can be shown, so a list the app could add to would be a list of empty
//  pages.
//

import SwiftUI

struct YouTubeChannelsView: View {
    @Environment(AppState.self) private var appState
    @Environment(YouTubeChannelStore.self) private var store

    /// Two characters before anything is asked; see `YouTubeChannelStore.search`.
    private var isSearching: Bool {
        RecordingKey.normalize(appState.searchText).count >= 2
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Archives", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Artists, records",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            if isSearching {
                results
            } else {
                content
            }
        }
        .task { await store.loadChannelsIfNeeded() }
        // A pause after the last keystroke before asking: each change cancels
        // the one before, so a word typed quickly is one query, not six.
        .task(id: appState.searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.search(appState.searchText)
        }
    }

    @ViewBuilder
    private var results: some View {
        let query = RecordingKey.normalize(appState.searchText)
        let isCurrent = store.searchQuery == query
        if !isCurrent || (store.searchHits.isEmpty && store.searchPhase.isLoading) {
            LoadingPane(label: "Searching archives")
        } else if let error = store.searchPhase.error {
            EmptyStateView(headline: "Search unavailable", message: error) {
                Button("Try Again") { Task { await store.search(appState.searchText) } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if store.searchHits.isEmpty {
            EmptyStateView(
                headline: "Nothing in the archives",
                message: "No upload by an artist or with a title matching “\(appState.searchText)”."
            ) {
                Button("Clear Search") { appState.searchText = "" }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            let hits = store.searchHits
            ScrollView {
                ArchiveTrackRows(
                    tracks: hits.map(\.track),
                    sources: Dictionary(
                        hits.compactMap { hit in hit.archiveTitle.map { (hit.appearanceID, $0) } },
                        uniquingKeysWith: { first, _ in first }
                    )
                )
                .padding(.bottom, 24)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.channels.isEmpty, store.channelsPhase.isLoading || store.channelsPhase == .idle {
            LoadingPane(label: "Loading archives")
        } else if store.channels.isEmpty, let error = store.channelsPhase.error {
            EmptyStateView(headline: "Archives unavailable", message: error) {
                Button("Try Again") { Task { await store.loadChannels() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if store.channels.isEmpty {
            EmptyStateView(
                headline: "No archives yet",
                message: "Archives appear here after their first read, within the hour."
            ) {
                EmptyView()
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(store.channels) { channel in
                        YouTubeChannelTile(channel: channel) {
                            appState.open(.youtubeChannel(id: channel.id))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    private var subtitle: String {
        if isSearching, store.searchQuery == RecordingKey.normalize(appState.searchText),
           store.searchPhase == .loaded {
            let count = store.searchHits.count
            // The server stops at 60; more than that is "60+", not a count.
            let shown = count >= 60 ? "60+" : "\(count)"
            return "\(shown) \(count == 1 ? "upload" : "uploads") matching “\(appState.searchText)”"
        }
        let count = store.channels.count
        guard count > 0 else { return "Curated uploads" }
        return "\(count) \(count == 1 ? "archive" : "archives")"
    }
}

struct YouTubeChannelTile: View {
    let channel: Catalog.RadioShow
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkView(
                remoteURL: channel.imageURL.flatMap(URL.init(string:)),
                placeholder: .mosaic,
                mark: channel.title
            )
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.title ?? "Archive")
                    .font(Typeface.body(12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("Archive")
                    .microLabel(0.8)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityLabel("Open \(channel.title ?? "archive")")
    }
}
