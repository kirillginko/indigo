//
//  NTSSearchView.swift
//  Indigo
//
//  Searches the whole NTS catalogue, not the rows already on screen. Track
//  results are the interesting ones: they point at the episode that played
//  them, which is the shortest path from "what was that?" to a tracklist.
//

import SwiftUI

struct NTSSearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(NTSBrowseStore.self) private var browse

    @State private var scope: NTSSearchScope = .all

    var body: some View {
        @Bindable var state = appState
        let results = browse.searchResults

        VStack(spacing: 0) {
            PageHeader(title: "Search", subtitle: subtitle(results)) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Shows, episodes, tracks",
                    focusSignal: appState.searchFocusRequests
                )
            }

            HStack {
                SegmentedTabs(
                    options: NTSSearchScope.allCases.map { ($0, $0.title) },
                    selection: $scope
                )
                Spacer()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 14)

            Rule(color: Palette.outline)
            body(for: results)
        }
        .onAppear {
            browse.updateSearch(query: appState.searchText, scope: scope)
        }
        .onChange(of: appState.searchText) { _, query in
            browse.updateSearch(query: query, scope: scope)
        }
        .onChange(of: scope) { _, newScope in
            browse.updateSearch(query: appState.searchText, scope: newScope)
        }
    }

    @ViewBuilder
    private func body(for results: NTSBrowseStore.Feed<NTSSearchResult>) -> some View {
        if appState.searchText.trimmingCharacters(in: .whitespaces).count < 2 {
            EmptyStateView(
                headline: "Search NTS",
                message: "Find a residency, a single broadcast, or a track — track results tell you which episode played it."
            ) { EmptyView() }
        } else if results.items.isEmpty, results.isLoading {
            LoadingPane(label: "Searching NTS")
        } else if results.items.isEmpty, let error = results.error {
            EmptyStateView(headline: "Search failed", message: error) {
                Button("Try Again") { Task { await browse.retrySearch() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if results.items.isEmpty, results.hasLoadedOnce {
            EmptyStateView(
                headline: "No results",
                message: "NTS has nothing for “\(appState.searchText)”\(scope == .all ? "" : " in \(scope.title.lowercased())")."
            ) { EmptyView() }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results.items) { result in
                        SearchResultRow(result: result) {
                            if let destination = result.destination {
                                appState.open(destination)
                            }
                        }
                        Rule()
                    }
                }
                LoadMoreFooter(
                    isLoading: results.isLoading,
                    hasMore: results.hasMore,
                    error: results.error,
                    loadedCount: results.items.count,
                    total: results.total
                ) {
                    await browse.loadMoreSearchResults()
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private func subtitle(_ results: NTSBrowseStore.Feed<NTSSearchResult>) -> String {
        guard browse.hasActiveSearch, let total = results.total else { return "The NTS catalogue" }
        return "\(total.formatted(.number)) \(total == 1 ? "result" : "results")"
    }
}

// MARK: - Row

struct SearchResultRow: View {
    let result: NTSSearchResult
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ArtworkView(remoteURL: result.artworkURL, side: 46)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Metrics.hairline))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(result.kindLabel)
                            .microLabel(1.1, size: 8.5)
                            .foregroundStyle(Palette.inverseInk)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(result.kind == .track ? Palette.accent : Palette.inverse)

                        Text(result.title)
                            .font(Typeface.body(12.5, weight: .semibold))
                            .lineLimit(1)
                    }

                    if let secondary {
                        Text(secondary)
                            .font(Typeface.body(11.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(1)
                    } else if !result.highlight.isEmpty {
                        highlightText
                            .font(Typeface.body(11.5))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    if let date = result.date {
                        Text(date)
                            .font(Typeface.mono(9.5))
                            .foregroundStyle(Palette.inkFaint)
                    }
                    if let location = result.location {
                        Text(location)
                            .microLabel(0.8)
                            .foregroundStyle(Palette.inkFaint)
                    }
                }

                Image(systemName: result.destination == nil ? "minus" : "arrow.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovering && result.destination != nil
                                     ? Palette.ink : Palette.inkFaint.opacity(0.5))
                    .frame(width: 12)
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: 64)
            .background(isHovering && result.destination != nil ? Palette.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(result.destination == nil)
        .onHover { isHovering = $0 }
    }

    /// Tracks read best as "Artist — played on Some Show".
    private var secondary: String? {
        guard result.kind == .track else { return nil }
        var parts: [String] = []
        if !result.artists.isEmpty { parts.append(result.artists.joined(separator: ", ")) }
        if let context = result.contextTitle { parts.append("Played on \(context)") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var highlightText: Text {
        result.highlight.reduce(Text("")) { partial, run in
            partial + Text(run.text)
                .foregroundStyle(run.isMatch ? Palette.ink : Palette.inkMuted)
                .fontWeight(run.isMatch ? .semibold : .regular)
        }
    }
}
