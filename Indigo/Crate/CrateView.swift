//
//  CrateView.swift
//  Indigo
//
//  Everything kept, newest first, grouped by the day it was kept. Each row
//  carries where it came from — a crate entry without provenance is just a
//  playlist row, which is the thing this deliberately isn't.
//

import SwiftUI
import SwiftData

struct CrateView: View {
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(DigStore.self) private var dig
    @Environment(KioskBrowseStore.self) private var kioskBrowse
    @Environment(NoodsBrowseStore.self) private var noodsBrowse
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState
        // Reading `revision` here subscribes the view to crate writes, so
        // adding or removing refreshes the list without a manual reload.
        let _ = crate.revision
        let allItems = crate.items()
        let genres = GenreTags.available(in: allItems.flatMap(itemGenres))
        let query = LibraryKey.normalize(appState.searchText)
        let visibleItems = allItems.filter {
            GenreTags.matches(itemGenres($0), selection: selectedGenres)
                && matchesSearch($0, query: query)
        }
        let days = days(from: visibleItems)

        VStack(spacing: 0) {
            PageHeader(title: "Crate", subtitle: subtitle(days)) {
                SearchField(
                    text: $state.searchText,
                    placeholder: "Shows, tracks, artists",
                    focusSignal: appState.searchFocusRequests
                )
            }
            Rule(color: Palette.outline)
            GenreFilterBar(genres: genres, selection: $selectedGenres)
            if !genres.isEmpty { Rule() }

            if allItems.isEmpty {
                EmptyStateView(
                    headline: "Nothing crated yet",
                    message: "Crate a track while it's playing, or keep a whole show. Everything you keep remembers where you heard it."
                ) {
                    EmptyView()
                }
            } else if days.isEmpty {
                EmptyStateView(
                    headline: "No matches",
                    message: "Nothing in your crate matches the current search and genre filters."
                ) {
                    Button("Clear Filters") {
                        selectedGenres.removeAll()
                        appState.searchText = ""
                    }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.items) { item in
                                    let localTrack = localTrack(for: item)
                                    CrateRow(
                                        item: item,
                                        localArtworkKey: localTrack?.artworkKey,
                                        genres: itemGenres(item),
                                        isCurrent: isCurrent(item),
                                        isPlaying: isCurrent(item) && player.isPlaying,
                                        digDestination: item.recording.flatMap { dig.destination(for: $0) },
                                        open: { open(item) },
                                        play: { play(item) },
                                        dig: { page in appState.open(page) },
                                        remove: { crate.remove(item) }
                                    )
                                    Rule()
                                }
                            } header: {
                                dayHeader(day)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible)
            }
        }
        .task {
            crate.backfillLocalGenres()
            await hydrateMissingRadioGenres()
        }
    }

    private func dayHeader(_ day: CrateService.Day) -> some View {
        HStack {
            Text(day.label)
                .microLabel(1.8)
                .foregroundStyle(Palette.ink)
            Spacer()
            Text("\(day.items.count)")
                .microLabel(1.2)
                .foregroundStyle(Palette.inkFaint)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .background(Palette.paper)
        .overlay(alignment: .bottom) { Rule(color: Palette.outline) }
    }

    private func subtitle(_ days: [CrateService.Day]) -> String {
        let total = days.reduce(0) { $0 + $1.items.count }
        guard total > 0 else { return "Your collection" }
        return "\(total) \(total == 1 ? "item" : "items")"
    }

    // MARK: Playback

    /// The view asks for the recording and takes whatever the resolver says is
    /// best — it never picks a provider. A crated broadcast is already an
    /// address, so it short-circuits.
    private func source(for item: CrateItem) -> AudioSource? {
        if let broadcast = item.broadcastMediaItem() {
            return AudioSource(
                kind: .broadcastAppearance,
                action: .play(broadcast),
                label: BroadcastSource.label(for: item.providerID ?? ""),
                detail: nil,
                rank: 0
            )
        }
        guard let recording = item.recording else { return nil }
        return SourceResolver(context: crate.context).best(recording)
    }

    private func isCurrent(_ item: CrateItem) -> Bool {
        guard case .play(let media) = source(for: item)?.action else { return false }
        return player.isCurrent(media.id)
    }

    private func play(_ item: CrateItem) {
        guard let source = source(for: item) else {
            crate.notice = "\(item.displayTitle) has no playable source yet."
            return
        }
        switch source.action {
        case .play(let media):
            if player.isCurrent(media.id) {
                player.toggle()
            } else if media.isLive {
                player.playRadio(media)
            } else if media.isEmbedded {
                player.playEpisode(media)
            } else {
                player.play([media])
            }
        case .openBroadcast(let page, _):
            // The music isn't addressable on its own — open the set it was in.
            appState.open(page)
        }
    }

    private func open(_ item: CrateItem) {
        if let track = localTrack(for: item) {
            appState.open(.album(track.albumKey))
            return
        }
        if let showID = item.showID {
            switch item.providerID {
            case NoodsProvider.providerID where showID.hasPrefix("noods.show."):
                appState.open(.noodsShow(path: "shows/\(showID.dropFirst("noods.show.".count))"))
                return
            case KioskProvider.providerID where showID.hasPrefix("kiosk.episode."):
                appState.open(.kioskEpisode(slug: String(showID.dropFirst("kiosk.episode.".count))))
                return
            case LotProvider.providerID where showID.hasPrefix("lot.episode."):
                let identity = String(showID.dropFirst("lot.episode.".count))
                if let ref = LotEpisodeRef.decode(identity) {
                    appState.open(.lotEpisode(show: ref.show, episode: ref.episode))
                    return
                }
            case NTSProvider.providerID where showID.hasPrefix("nts.episode."):
                let identity = String(showID.dropFirst("nts.episode.".count))
                if let ref = NTSEpisodeRef.decode(identity) {
                    appState.open(.ntsEpisode(show: ref.show, episode: ref.episode))
                    return
                }
            default: break
            }
        }
        if let recording = item.recording, let page = dig.destination(for: recording) {
            appState.open(page)
        }
    }

    private func localTrack(for item: CrateItem) -> Track? {
        guard let path = item.recording?.sources.first(where: { $0.kind == .localFile })?.identifier else {
            return nil
        }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try? crate.context.fetch(descriptor).first
    }

    private func itemGenres(_ item: CrateItem) -> [String] {
        let stored = item.genreTags
        if !stored.isEmpty { return stored }
        if let genre = localTrack(for: item)?.genre, !genre.isEmpty { return [genre] }
        if let recording = item.recording { return dig.genres(for: recording) }
        return []
    }

    private func hydrateMissingRadioGenres() async {
        for item in crate.items() where item.genreTags.isEmpty {
            guard let provider = item.providerID, let showID = item.showID else { continue }
            let genres: [String]
            switch provider {
            case KioskProvider.providerID where showID.hasPrefix("kiosk.episode."):
                let slug = String(showID.dropFirst("kiosk.episode.".count))
                await kioskBrowse.loadEpisodeDetailIfNeeded(slug: slug)
                genres = kioskBrowse.episodeDetail(slug: slug)?.episode.genres ?? []
            case NoodsProvider.providerID where showID.hasPrefix("noods.show."):
                let path = "shows/\(showID.dropFirst("noods.show.".count))"
                await noodsBrowse.loadShowIfNeeded(path: path)
                genres = noodsBrowse.showDetail(path: path)?.show.genres ?? []
            case LotProvider.providerID where showID.hasPrefix("lot.episode."):
                let identity = String(showID.dropFirst("lot.episode.".count))
                guard let ref = LotEpisodeRef.decode(identity) else { continue }
                await lotBrowse.loadEpisodeIfNeeded(ref: ref)
                genres = lotBrowse.episode(ref: ref)?.genreNames ?? []
            case NTSProvider.providerID where showID.hasPrefix("nts.episode."):
                let identity = String(showID.dropFirst("nts.episode.".count))
                guard let ref = NTSEpisodeRef.decode(identity) else { continue }
                await ntsBrowse.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
                if let summary = ntsBrowse.detail(show: ref.show, episode: ref.episode)?.summary {
                    genres = summary.genres + summary.moods
                } else {
                    genres = []
                }
            default:
                genres = []
            }
            crate.updateGenres(genres, for: item)
        }
    }

    private func days(from items: [CrateItem]) -> [CrateService.Day] {
        Dictionary(grouping: items, by: \.addedDay)
            .map { CrateService.Day(date: $0.key, items: $0.value.sorted { $0.addedAt > $1.addedAt }) }
            .sorted { $0.date > $1.date }
    }

    private func matchesSearch(_ item: CrateItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [item.displayTitle, item.displaySubtitle, item.sourceLine]
            .compactMap { $0 }
            .map(LibraryKey.normalize)
            .contains { $0.contains(query) }
            || itemGenres(item).map(LibraryKey.normalize).contains { $0.contains(query) }
    }
}

// MARK: - Row

private struct CrateRow: View {
    let item: CrateItem
    let localArtworkKey: String?
    let genres: [String]
    let isCurrent: Bool
    let isPlaying: Bool
    let digDestination: DetailPage?
    let open: () -> Void
    let play: () -> Void
    let dig: (DetailPage) -> Void
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(localKey: localArtworkKey, remoteURL: item.artworkURL, side: 44)
                .overlay(Rectangle().strokeBorder(
                    isCurrent ? Palette.accent : Palette.rule,
                    lineWidth: isCurrent ? 1.5 : Metrics.hairline
                ))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(Typeface.body(12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                if let subtitle = item.displaySubtitle {
                    Text(subtitle)
                        .font(Typeface.body(11.5))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
                if let source = item.sourceLine {
                    Text(source)
                        .font(Typeface.mono(9.5))
                        .foregroundStyle(Palette.inkFaint)
                        .lineLimit(1)
                }
                if !genres.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(genres.prefix(3)), id: \.self) { genre in
                            TagChip(text: genre)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let status = item.statusItem {
                StatusChip(item: status)
            }

            if let digDestination {
                DigButton { dig(digDestination) }
                    .opacity(isHovering ? 1 : 0.45)
            }

            HStack(spacing: 2) {
                Button(action: play) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(GlyphButtonStyle())
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Remove from crate")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .background(isHovering ? Palette.wash : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
    }
}
