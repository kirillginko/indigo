//
//  RovrCuratorsView.swift
//  Indigo
//
//  The people behind ROVR's shows — two hundred and seventy-six of them, from
//  wherever they happen to be.
//
//  Which is the point of the page rather than a detail of it: a station with
//  no home timezone has no home city either, and the roster is the closest
//  thing it has to a map of itself.
//

import SwiftUI

struct RovrCuratorsView: View {
    @Environment(AppState.self) private var appState
    @Environment(RovrBrowseStore.self) private var browse

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { query.count >= 2 }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            PageHeader(title: "Curators", subtitle: subtitle) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Search curators",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            content
        }
        .task { await browse.loadCuratorsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        let visible = self.visible
        if browse.curators.isEmpty, browse.curatorsPhase.isLoading {
            LoadingPane(label: "Loading curators")
        } else if browse.curators.isEmpty, let error = browse.curatorsPhase.error {
            EmptyStateView(headline: "ROVR unreachable", message: error) {
                Button("Try Again") { Task { await browse.loadCurators() } }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else if visible.isEmpty {
            EmptyStateView(
                headline: "No curators found",
                message: "Nothing matches “\(query)”."
            ) {
                Button("Clear Search") { appState.searchText = "" }
                    .buttonStyle(OutlineButtonStyle())
            }
        } else {
            ScrollView {
                LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                    ForEach(visible) { curator in
                        RovrCuratorTile(curator: curator) {
                            appState.open(.rovrCurator(id: curator.documentID))
                        }
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 22)

                Text("The whole roster")
                    .microLabel(1.4)
                    .foregroundStyle(Palette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.visible)
        }
    }

    private var visible: [RovrCurator] {
        guard isSearching else { return browse.curators }
        return browse.curators.filter { curator in
            ([curator.name, curator.about ?? ""] + curator.showTitles)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var subtitle: String {
        if isSearching {
            let count = visible.count
            return "\(count) \(count == 1 ? "curator" : "curators") matching “\(query)”"
        }
        guard !browse.curators.isEmpty else { return "ROVR curators" }
        return "\(browse.curators.count) curators"
    }
}
