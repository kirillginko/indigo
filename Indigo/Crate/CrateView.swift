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
    @Environment(IdaBrowseStore.self) private var idaBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(PanikBrowseStore.self) private var panikBrowse
    @Environment(RovrBrowseStore.self) private var rovrBrowse
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @Environment(DublabBrowseStore.self) private var dublabBrowse
    @Environment(AlharaBrowseStore.self) private var alharaBrowse
    @Environment(CashmereBrowseStore.self) private var cashmereBrowse
    @Environment(LYLBrowseStore.self) private var lylBrowse
    @State private var selectedGenres: Set<String> = []

    var body: some View {
        @Bindable var state = appState
        // Reading `revision` here subscribes the view to crate writes, so
        // adding or removing refreshes the list without a manual reload.
        let _ = crate.revision
        let _ = dig.revision
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
                    message: "Keep a track, show, artist, release or label. Everything you crate stays ready to play or dig into again."
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
                                    // Worked out once. Every one of these used
                                    // to resolve the row's source again — three
                                    // times per row, each a fresh walk of the
                                    // ways it could be played, on every redraw.
                                    let playable = resolved[item.id]
                                    let current = isCurrent(playable)
                                    // Playable until proven otherwise. The map
                                    // is filled a moment after the list draws,
                                    // and a row that says it cannot be played
                                    // while we are still working it out is
                                    // worse than one that finds out on press —
                                    // which `play` does anyway.
                                    let canPlay = playable != nil || !hasResolved
                                    CrateRow(
                                        item: item,
                                        localArtworkKey: localTrack?.artworkKey,
                                        genres: itemGenres(item),
                                        canPlay: canPlay,
                                        isCurrent: current,
                                        isPlaying: current && player.isPlaying,
                                        digDestination: destinations[item.id],
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
        .task(id: crate.revision) { readRows() }
        .task(id: dig.revision) { readRows() }
        .task {
            // Needs no network, so it runs before anything that waits on one:
            // this is what restores the artist — and the DIG button — on rows
            // kept before the credit was read apart.
            dig.repairRadioCredits()
            crate.backfillLocalGenres()
            await hydrateMissingRadioGenres()
            await dig.enrichRadioCrateInBackground()
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
        SourceResolver(context: crate.context).best(item)
    }

    /// Where each row can be played from, and where its DIG button goes.
    ///
    /// Both read the store, so they are worked out when the crate changes
    /// rather than while it is being drawn.
    @State private var resolved: [UUID: AudioSource] = [:]
    @State private var destinations: [UUID: DetailPage] = [:]
    @State private var hasResolved = false

    private func readRows() {
        var sources: [UUID: AudioSource] = [:]
        var pages: [UUID: DetailPage] = [:]
        for item in crate.items() {
            if let found = source(for: item) { sources[item.id] = found }
            if let recording = item.recording, let page = dig.destination(for: recording) {
                pages[item.id] = page
            }
        }
        resolved = sources
        destinations = pages
        hasResolved = true
    }

    private func isCurrent(_ source: AudioSource?) -> Bool {
        guard case .play(let media) = source?.action else { return false }
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
        if let destination = digDestination(for: item) {
            appState.open(destination)
            return
        }
        if let track = localTrack(for: item) {
            appState.open(.album(track.albumKey))
            return
        }
        if let showID = item.showID {
            switch item.providerID {
            case NTSProvider.providerID where item.isLiveStream && !showID.hasPrefix("nts.episode."):
                // Older crate entries only know the station and show title.
                // Search the NTS archive instead of reopening today's stream.
                appState.select(.ntsSearch)
                appState.searchText = item.displayTitle
                return
            case NoodsProvider.providerID where showID.hasPrefix("noods.show."):
                appState.open(.noodsShow(path: "shows/\(showID.dropFirst("noods.show.".count))"))
                return
            case KioskProvider.providerID where showID.hasPrefix("kiosk.episode."):
                appState.open(.kioskEpisode(slug: String(showID.dropFirst("kiosk.episode.".count))))
                return
            case LYLProvider.providerID where showID.hasPrefix("lyl.episode."):
                appState.open(.lylEpisode(slug: String(showID.dropFirst("lyl.episode.".count))))
                return
            case CashmereProvider.providerID where showID.hasPrefix("cashmere.episode."):
                appState.open(.cashmereEpisode(slug: String(showID.dropFirst("cashmere.episode.".count))))
                return
            case IdaProvider.providerID where showID.hasPrefix("ida.episode."):
                appState.open(.idaEpisode(slug: String(showID.dropFirst("ida.episode.".count))))
                return
            case Radio80000Provider.providerID where showID.hasPrefix("radio80000.episode."):
                appState.open(.radio80000Episode(
                    id: String(showID.dropFirst("radio80000.episode.".count))
                ))
                return
            case PanikProvider.providerID where showID.hasPrefix("panik.episode."):
                appState.open(.panikEpisode(id: String(showID.dropFirst("panik.episode.".count))))
                return
            case RovrProvider.providerID where showID.hasPrefix("rovr.broadcast."):
                appState.open(.rovrBroadcast(
                    id: String(showID.dropFirst("rovr.broadcast.".count))
                ))
                return
            case AlharaProvider.providerID where showID.hasPrefix("alhara.show."):
                appState.open(.alharaShow(slug: String(showID.dropFirst("alhara.show.".count))))
                return
            case DublabProvider.providerID where showID.hasPrefix("dublab.broadcast."):
                appState.open(.dublabBroadcast(slug: String(showID.dropFirst("dublab.broadcast.".count))))
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
        // The row opens the track's own page — where it was heard, and what
        // was heard beside it. The DIG button still means the artist.
        if let recording = item.recording, let page = dig.recordingDestination(for: recording) {
            appState.open(page)
        }
    }

    private func digDestination(for item: CrateItem) -> DetailPage? {
        guard let identifier = item.showID else { return nil }
        switch (item.kind, item.providerID) {
        case (.artist, "dig.artist.mbid"):
            return .digArtist(mbid: identifier, name: item.displayTitle)
        case (.artist, "dig.artist.name"):
            return .digArtist(mbid: nil, name: item.displayTitle)
        case (.release, "dig.release.discogs"):
            guard let id = Int(identifier) else { return nil }
            return .digRelease(id: id, title: item.displayTitle)
        case (.label, "dig.label.mbid"):
            return .digLabel(mbid: identifier, name: item.displayTitle)
        case (.label, "dig.label.discogs"):
            return .digDiscogsLabel(name: item.displayTitle)
        default:
            return nil
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
            case NTSProvider.providerID where item.isLiveStream && !showID.hasPrefix("nts.episode."):
                guard let ref = await ntsBrowse.archivedEpisode(
                    matching: item.displayTitle, near: item.addedAt
                ) else { continue }
                await ntsBrowse.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
                let detail = ntsBrowse.detail(show: ref.show, episode: ref.episode)
                crate.migrateLegacyNTSBroadcast(item, ref: ref, media: detail?.mediaItem())
                genres = detail.map { $0.summary.genres + $0.summary.moods } ?? []
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
            case DublabProvider.providerID where showID.hasPrefix("dublab.broadcast."):
                let slug = String(showID.dropFirst("dublab.broadcast.".count))
                await dublabBrowse.loadBroadcastIfNeeded(slug: slug)
                genres = dublabBrowse.broadcast(slug: slug)?.genreNames ?? []
            case AlharaProvider.providerID where showID.hasPrefix("alhara.show."):
                let slug = String(showID.dropFirst("alhara.show.".count))
                await alharaBrowse.loadDetailIfNeeded(slug: slug)
                genres = alharaBrowse.show(slug: slug)?.genres ?? []
            case CashmereProvider.providerID where showID.hasPrefix("cashmere.episode."):
                let slug = String(showID.dropFirst("cashmere.episode.".count))
                await cashmereBrowse.loadDetailIfNeeded(slug: slug)
                genres = cashmereBrowse.episode(slug: slug)?.genres ?? []
            case LYLProvider.providerID where showID.hasPrefix("lyl.episode."):
                let slug = String(showID.dropFirst("lyl.episode.".count))
                await lylBrowse.loadDetailIfNeeded(slug: slug)
                genres = lylBrowse.episode(slug: slug)?.styles ?? []
            case IdaProvider.providerID where showID.hasPrefix("ida.episode."):
                let slug = String(showID.dropFirst("ida.episode.".count))
                await idaBrowse.loadDetailIfNeeded(slug: slug)
                genres = idaBrowse.episode(slug: slug)?.genres ?? []
            case Radio80000Provider.providerID where showID.hasPrefix("radio80000.episode."):
                let id = String(showID.dropFirst("radio80000.episode.".count))
                await radio80000Browse.loadDetailIfNeeded(id: id)
                genres = radio80000Browse.episode(id: id)?.genres ?? []
            case PanikProvider.providerID where showID.hasPrefix("panik.episode."):
                // Panik tags the show rather than the broadcast, so the show's
                // own headings are the closest thing an episode has.
                let id = String(showID.dropFirst("panik.episode.".count))
                guard let slug = PanikEpisodeID.showSlug(of: id) else { continue }
                await panikBrowse.loadShowsIfNeeded()
                genres = panikBrowse.show(slug: slug)?.categories ?? []
            case RovrProvider.providerID where showID.hasPrefix("rovr.broadcast."):
                let id = String(showID.dropFirst("rovr.broadcast.".count))
                await rovrBrowse.loadDetailIfNeeded(id: id)
                genres = rovrBrowse.broadcast(id: id)?.tags ?? []
            case NTSProvider.providerID where showID.hasPrefix("nts.episode."):
                let identity = String(showID.dropFirst("nts.episode.".count))
                guard let ref = NTSEpisodeRef.decode(identity) else { continue }
                await ntsBrowse.loadDetailIfNeeded(show: ref.show, episode: ref.episode)
                if let detail = ntsBrowse.detail(show: ref.show, episode: ref.episode) {
                    if let media = detail.mediaItem() {
                        crate.updateArchivedBroadcast(item, from: media)
                    }
                    let summary = detail.summary
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
    let canPlay: Bool
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
                if canPlay {
                    Button(action: play) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(GlyphButtonStyle())
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                }

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
