//
//  DublabDJsView.swift
//  Indigo
//
//  dublab's roster — three hundred and sixty-odd DJs, current and past. Small
//  enough to hold whole, so searching it is a real search.
//

import SwiftUI

struct DublabDJsView: View {
    @Environment(AppState.self) private var appState
    @Environment(DublabBrowseStore.self) private var browse

    @State private var showsPast = false

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "DJs", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search the roster",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            controls
            content
        }
        .task { await browse.loadDJsIfNeeded() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Roster").microLabel(1.4).foregroundStyle(Palette.inkFaint)
            Button(showsPast ? "On air and past" : "On air only") { showsPast.toggle() }
                .buttonStyle(.plain)
                .microLabel(1.1, size: 9)
                .foregroundStyle(Palette.accent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 12)
        .background(Palette.paperChrome)
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.djs.isEmpty, browse.djsPhase.isLoading {
            LoadingPane(label: "Loading the roster")
        } else if browse.djs.isEmpty, let error = browse.djsPhase.error {
            EmptyStateView(headline: "dublab unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadDJs() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No DJs found",
                message: isSearching
                    ? "dublab has nobody on its roster matching “\(query)”."
                    : "Nobody on the roster matches that."
            ) {
                if !showsPast {
                    Button("Include Past Residents") { showsPast = true }
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { dj in
                        DublabDJTile(dj: dj) {
                            appState.open(.dublabDJ(slug: dj.slug))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [DublabDJ] {
        browse.djs.filter { dj in
            guard showsPast || dj.isActive else { return false }
            guard isSearching else { return true }
            let haystack = [dj.name] + dj.shows.map(\.title)
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "DJ" : "DJs") matching “\(query)”"
        }
        guard !browse.djs.isEmpty else { return "The dublab roster" }
        let active = browse.djs.filter(\.isActive).count
        return showsPast
            ? "\(browse.djs.count) DJs, \(active) on air"
            : "\(active) DJs on air"
    }
}
