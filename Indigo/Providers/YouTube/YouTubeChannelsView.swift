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

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Archives", subtitle: subtitle) { EmptyView() }
            Rule(color: Palette.outline)
            content
        }
        .task { await store.loadChannelsIfNeeded() }
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
