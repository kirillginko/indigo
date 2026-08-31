//
//  LYLShowsView.swift
//  Indigo
//
//  LYL's shows. Style and studio narrow the directory at the station rather
//  than on screen, so the whole of it stays reachable.
//

import SwiftUI

struct LYLShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LYLBrowseStore.self) private var browse

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Shows", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search loaded shows",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            filters
            if !browse.styles.isEmpty || !browse.studios.isEmpty { Rule() }
            content
        }
        .task { await browse.loadShowsIfNeeded() }
    }

    /// Two hundred styles and five studios are far too many for a row of
    /// chips, and narrowing re-asks the station rather than filtering the
    /// page — so these are menus.
    private var filters: some View {
        HStack(spacing: 10) {
            Text("Narrow by").microLabel(1.4).foregroundStyle(Palette.inkFaint)

            if !browse.styles.isEmpty {
                Menu {
                    Button("All styles") { browse.setStyle(nil) }
                    Divider()
                    ForEach(browse.styles) { style in
                        Button(style.name) { browse.setStyle(style.name) }
                    }
                } label: {
                    chip(browse.selectedStyle ?? "Style", isSet: browse.selectedStyle != nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !browse.studios.isEmpty {
                Menu {
                    Button("All studios") { browse.setStudio(nil) }
                    Divider()
                    ForEach(browse.studios) { studio in
                        Button(studio.label) { browse.setStudio(studio.name) }
                    }
                } label: {
                    chip(browse.selectedStudio ?? "Studio", isSet: browse.selectedStudio != nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if browse.selectedStyle != nil || browse.selectedStudio != nil {
                Button("Clear") { browse.clearShowFilters() }
                    .buttonStyle(.plain)
                    .microLabel(1.0)
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
        .background(Palette.paperChrome)
    }

    private func chip(_ text: String, isSet: Bool) -> some View {
        Text(text)
            .microLabel(1.1, size: 9)
            .foregroundStyle(isSet ? Palette.inverseInk : Palette.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSet ? Palette.inverse : Color.clear)
            .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.shows.isEmpty, browse.showsPhase.isLoading {
            LoadingPane(label: "Loading shows")
        } else if browse.shows.isEmpty, let error = browse.showsPhase.error {
            EmptyStateView(headline: "LYL unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadShows() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No shows found",
                message: isSearching
                    ? "Nothing loaded matches “\(query)”."
                    : "LYL has no shows under that."
            ) {
                if browse.selectedStyle != nil || browse.selectedStudio != nil {
                    Button("Clear Filter") { browse.clearShowFilters() }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { show in
                        LYLShowTile(show: show) {
                            appState.open(.lylShow(slug: show.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                footer
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if browse.isLoadingMoreShows {
            Text("Loading more").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        } else if browse.canLoadMoreShows {
            Button("Load More") { Task { await browse.loadMoreShows() } }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)
        } else {
            Text("End of the directory").microLabel(1.4).foregroundStyle(Palette.inkFaint)
                .frame(maxWidth: .infinity)
        }
    }

    private var visible: [LYLShow] {
        guard isSearching else { return browse.shows }
        return browse.shows.filter { show in
            ([show.title, show.artists ?? ""] + show.styles)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "show" : "shows") matching “\(query)”"
        }
        guard !browse.shows.isEmpty else { return "LYL Radio shows" }
        let narrowed = [browse.selectedStyle, browse.selectedStudio].compactMap { $0 }
        let count = browse.canLoadMoreShows ? "\(browse.shows.count) shows so far" : "\(browse.shows.count) shows"
        return narrowed.isEmpty ? count : "\(count) · \(narrowed.joined(separator: " · "))"
    }
}
