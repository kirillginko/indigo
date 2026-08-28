//
//  NoodsResidentsView.swift
//  Indigo
//
//  Noods runs on residencies — nearly three hundred of them. The index is a
//  searchable A–Z; a resident page is their schedule and their back catalogue.
//

import SwiftUI

struct NoodsResidentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var state = appState
        let matches = filtered

        VStack(spacing: 0) {
            PageHeader(title: "Residents", subtitle: subtitle(matches)) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Find a resident",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)

            if browse.residents.isEmpty, browse.residentsPhase.isLoading {
                LoadingPane(label: "Loading residents")
            } else if browse.residents.isEmpty, let error = browse.residentsPhase.error {
                EmptyStateView(headline: "Noods unreachable", message: error) {
                    Button("Try Again") { Task { await browse.loadResidentsIfNeeded() } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else if matches.isEmpty {
                EmptyStateView(
                    headline: "No residents found",
                    message: "Nobody on Noods matches “\(query)”."
                ) { EmptyView() }
            } else {
                ScrollView {
                    if query.isEmpty, !browse.promotedResidents.isEmpty {
                        HStack {
                            Text("Promoted").microLabel(1.8).foregroundStyle(Palette.ink)
                            Spacer()
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.top, 22)
                        .padding(.bottom, 12)

                        LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                            ForEach(browse.promotedResidents) { resident in
                                NoodsResidentTile(resident: resident) {
                                    appState.open(.noodsResident(path: resident.path))
                                }
                            }
                        }
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.bottom, 30)

                        Rule(color: Palette.outline)
                    }

                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(matches) { resident in
                            NoodsResidentTile(resident: resident) {
                                appState.open(.noodsResident(path: resident.path))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 22)
                }
                .scrollIndicators(.visible)
            }
        }
        .task { await browse.loadResidentsIfNeeded() }
        .onDisappear { appState.searchText = "" }
    }

    /// The whole index arrives in one response, so this filters what's on
    /// screen rather than querying — Noods has no resident search endpoint.
    private var filtered: [NoodsResidentRef] {
        guard !query.isEmpty else { return browse.residents }
        let key = LibraryKey.normalize(query)
        return browse.residents.filter { LibraryKey.normalize($0.name).contains(key) }
    }

    private func subtitle(_ matches: [NoodsResidentRef]) -> String {
        if !query.isEmpty {
            return "\(matches.count) matching “\(query)”"
        }
        return browse.residents.isEmpty ? "Noods residencies" : "\(browse.residents.count) residencies"
    }
}

struct NoodsResidentDetailView: View {
    let residentPath: String

    @Environment(AppState.self) private var appState
    @Environment(NoodsBrowseStore.self) private var browse
    @Environment(PlaybackCoordinator.self) private var player

    var body: some View {
        let resident = browse.resident(path: residentPath)

        VStack(spacing: 0) {
            PageHeader(
                title: resident?.name ?? NoodsPath.slug(residentPath).replacingOccurrences(of: "-", with: " ").capitalized,
                breadcrumb: appState.breadcrumbTitle,
                onBack: { appState.popDetail() },
                subtitle: [resident?.location, resident?.schedule]
                    .compactMap { $0 }.joined(separator: " · ")
            )
            Rule(color: Palette.outline)

            if let resident {
                content(resident)
            } else if let error = browse.residentError(path: residentPath) {
                EmptyStateView(headline: "Couldn't load this resident", message: error) {
                    Button("Try Again") { Task { await browse.loadResident(path: residentPath) } }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                LoadingPane(label: "Loading resident")
            }
        }
        .task(id: residentPath) { await browse.loadResidentIfNeeded(path: residentPath) }
    }

    private func content(_ resident: NoodsResident) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    ArtworkView(remoteURL: resident.artworkURL, side: 220)
                        .overlay(Rectangle().strokeBorder(Palette.outline, lineWidth: Metrics.hairline))

                    VStack(alignment: .leading, spacing: 14) {
                        if let schedule = resident.schedule, !schedule.isEmpty {
                            Text(schedule)
                                .microLabel(1.4)
                                .foregroundStyle(Palette.accent)
                        }
                        if let about = resident.about, !about.isEmpty {
                            Text(about)
                                .font(Typeface.body(12.5))
                                .foregroundStyle(Palette.inkMuted)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if let first = resident.shows.first(where: \.isPlayable) {
                            Button {
                                NoodsPlayback.toggle(first, within: resident.shows, using: player)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "play.fill").font(.system(size: 11))
                                    Text("Play Latest").microLabel(1.4, size: 11)
                                }
                                .foregroundStyle(Palette.inverseInk)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 13)
                                .background(Palette.inverse)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 30)

                if !resident.shows.isEmpty {
                    Rule(color: Palette.outline)
                    HStack {
                        Text("Shows").microLabel(1.8).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(resident.shows.count)").microLabel(1.2).foregroundStyle(Palette.inkFaint)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)

                    NoodsShowGrid(shows: resident.shows)

                    if resident.nextPage != nil {
                        LoadMoreFooter(
                            isLoading: browse.isLoadingResident(residentPath),
                            hasMore: true,
                            error: browse.residentError(path: residentPath),
                            loadedCount: resident.shows.count,
                            total: nil
                        ) {
                            await browse.loadMoreResidentShows(path: residentPath)
                        }
                    }
                }

                if !resident.similar.isEmpty {
                    Rule(color: Palette.outline)
                    HStack {
                        Text("Similar residents").microLabel(1.8).foregroundStyle(Palette.ink)
                        Spacer()
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 14)

                    LazyVGrid(columns: BrowseGrid.columns, spacing: 26) {
                        ForEach(resident.similar) { peer in
                            NoodsResidentTile(resident: peer) {
                                appState.open(.noodsResident(path: peer.path))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
            .padding(.bottom, 26)
        }
        .scrollIndicators(.visible)
    }
}
