//
//  PhoneForYouView.swift
//  Indigo
//
//  The phone's For You tab: what to explore next, one suggestion to a screen,
//  in the same language as Live -- the picture full-bleed, a few words, one
//  button, swiped up to the next. Artists and the next steps from what was
//  kept, with a radio show every third slide; each says in one line why it is
//  here and in one what it was reached through.
//
//  The feed opens on For You's own moving field, full screen; the suggestions
//  are swiped up from it. They are DIG's own (`DigStore.exploreOffers`),
//  refreshed when the crate changes, as the Mac's For You page refreshes
//  them. A suggestion is opened, not played: an artist opens its DIG page, a
//  show its page or latest broadcast.
//
//  Before anything has been kept there is nothing to suggest from, and a
//  first look at the app should not be an empty page: the feed is then what
//  the stations have on now, one show from each, to listen to straight away.
//

import SwiftUI

struct PhoneForYouView: View {
    @Environment(AppState.self) private var appState
    @Environment(DigStore.self) private var dig
    @Environment(CrateService.self) private var crate
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @Environment(DublabBrowseStore.self) private var dublabBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(N10ASBrowseStore.self) private var n10asBrowse
    @Environment(PlaybackCoordinator.self) private var player
    @Bindable private var feeds = PhoneFeeds.shared

    /// One screen of the feed.
    enum Slide: Identifiable {
        case cover
        /// Tracks to hear (`ForYouTracksFeature`, development builds only).
        case tracks
        /// Records like yours (`SimilarRecordsFeature`, development builds only).
        case similar
        /// One thing from For You's mix (`ForYouMixFeature`): a track that
        /// plays, a record, an artist or a show, each a slide of its own.
        case item(ForYouItem)
        case suggestion(ExploreSuggestion)
        case onNow(StationEntry)

        var id: String {
            switch self {
            case .cover: "cover"
            case .tracks: "tracks"
            case .similar: "similar"
            case .item(let item): "item." + item.id
            case .suggestion(let suggestion): "suggestion." + suggestion.id
            case .onNow(let entry): "onNow." + entry.id
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            StationDirectory { entries, playable in
                let suggestions = Self.slides(from: dig.exploreOffers)
                let mixed = ForYouMixFeature.isEnabled ? dig.forYouMix.items : []
                // With the mix on, the feed is the mix: tracks, records,
                // artists and shows woven together, one to a screen. Until it
                // is worked out, For You's own suggestions stand in.
                let slides: [Slide] = [.cover] + (!mixed.isEmpty ? mixed.map(Slide.item)
                    : (ForYouMixFeature.isEnabled ? [] : (ForYouTracksFeature.isEnabled ? [.tracks] : [])
                        + (SimilarRecordsFeature.isEnabled ? [.similar] : []))
                    + (suggestions.isEmpty ? Self.sampler(entries).map(Slide.onNow) : suggestions.map(Slide.suggestion)))
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(slides) { slide in
                            Group {
                                switch slide {
                                case .cover:
                                    PhoneForYouGlobe(
                                        items: globeItems(suggestions: suggestions, entries: entries, playable: playable),
                                        insets: insets
                                    ) {
                                        guard slides.count > 1 else { return }
                                        withAnimation(.easeInOut(duration: 0.4)) { feeds.forYouID = slides[1].id }
                                    }
                                case .tracks:
                                    PhoneForYouTracksSlide(insets: insets)
                                case .item(let item):
                                    PhoneForYouSlide(card: card(for: item), insets: insets) { act(item) }
                                case .similar:
                                    SimilarRecordsSection()
                                        .padding(.top, insets.top)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                        .background(Color.black)
                                case .suggestion(let suggestion):
                                    PhoneForYouSlide(card: card(for: suggestion), insets: insets) {
                                        Task { await open(suggestion.node) }
                                    }
                                case .onNow(let entry):
                                    PhoneLiveSlide(entry: entry, item: playable(entry), insets: insets) {
                                        appState.select(entry.route)
                                    }
                                }
                            }
                            .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $feeds.forYouID)
            }
            .ignoresSafeArea()
        }
        // Asked again when the crate moves, and when another device changed
        // something the offers are worked out from; the store decides
        // whether that is a rebuild. See `DigStore.refreshExploreOffers`.
        .task(id: [crate.revision, UserDataImports.shared.exploreRevision]) {
            await dig.refreshExploreOffers()
            await dig.refreshForYouMix()
        }
        // The mix again whenever a part of it arrives.
        .task(id: "\(dig.mixOffers.next.count)|\(dig.exploreOffers.next.count)|\(dig.discover.tracks.count)|\(dig.similarRecords.records.count)") {
            await dig.composeForYouMix()
        }
        // The suggested artists' portraits, asked for ahead of the rest -- and
        // a small one already held replaced with the full-size picture.
        .task(id: dig.exploreOffers.artists.count + dig.exploreOffers.next.count) {
            let names = Self.slides(from: dig.exploreOffers)
                .filter { $0.node.kind == .artist }
                .map(\.node.title)
            if !names.isEmpty { dig.wantPortraits(for: Array(names.prefix(24))) }
        }
    }

    /// One show from each station, in an order of its own -- not Live's -- so
    /// the first look at For You is not the Live tab again.
    static func sampler(_ entries: [StationEntry]) -> [StationEntry] {
        var byProvider: [String: StationEntry] = [:]
        for entry in entries where byProvider[entry.station.providerID] == nil {
            byProvider[entry.station.providerID] = entry
        }
        let firsts = entries.filter { byProvider[$0.station.providerID]?.id == $0.id }
        // Every other station from the far end, then the rest.
        return stride(from: firsts.count - 1, through: 0, by: -2).map { firsts[$0] }
            + stride(from: firsts.count - 2, through: 0, by: -2).map { firsts[$0] }
    }

    /// Artists and next steps, a show every third slide, nothing twice.
    static func slides(from offers: ExploreOffers) -> [ExploreSuggestion] {
        var seen = Set<String>()
        let main = (offers.next + offers.artists).filter { seen.insert($0.id).inserted }
        let shows = offers.shows.filter { seen.insert($0.id).inserted }
        var slides: [ExploreSuggestion] = []
        var showIndex = 0
        for (index, suggestion) in main.enumerated() {
            slides.append(suggestion)
            if index % 2 == 1, showIndex < shows.count {
                slides.append(shows[showIndex])
                showIndex += 1
            }
        }
        return slides + shows.dropFirst(showIndex)
    }

    /// What the globe carries: the suggestions, as the Mac's For You has
    /// them; before anything has been kept, every station and the archives.
    private func globeItems(
        suggestions: [ExploreSuggestion],
        entries: [StationEntry],
        playable: @escaping (StationEntry) -> MediaItem?
    ) -> [GlobeItem] {
        // Always one box into the archives, wherever the rest come from.
        let archives = GlobeItem(id: "archives", label: "", title: "Digital Archives") {
            PhoneFeeds.shared.showsStation = "Archives"
            appState.select(.shows)
        }
        if !suggestions.isEmpty {
            // All of them, as the Mac's For You shows: up to twenty-four.
            return [archives] + suggestions.map { suggestion in
                GlobeItem(id: suggestion.id, label: Self.kind(of: suggestion.node), title: suggestion.node.title) {
                    Task { await open(suggestion.node) }
                }
            }
        }
        return stationItems(entries, playable: playable) + [archives]
    }

    /// Every station, its city over its short name; tapped, it plays.
    private func stationItems(_ entries: [StationEntry], playable: @escaping (StationEntry) -> MediaItem?) -> [GlobeItem] {
        entries.map { entry in
            let item = playable(entry)
            let city = entry.location.split(separator: ",").first.map(String.init) ?? entry.location
            return GlobeItem(
                id: entry.id, label: city, title: entry.shortLabel,
                isOn: item.map { player.isCurrent($0.id) && player.isPlaying } ?? false
            ) {
                guard let item else { return }
                if player.isCurrent(item.id) { player.toggle() } else { player.playRadio(item) }
            }
        }
    }

    /// A suggestion as a slide.
    private func card(for suggestion: ExploreSuggestion) -> PhoneForYouSlide.Card {
        let isShow = suggestion.node.kind == .broadcast
        let portrait = suggestion.node.kind == .artist
            ? dig.portraitURL(for: suggestion.node.title, discogsID: suggestion.node.discogsID) : nil
        return .init(picture: portrait ?? suggestion.node.artworkURL,
                     kind: isShow ? "Radio show" : Self.kind(of: suggestion.node),
                     title: suggestion.node.title, subtitle: suggestion.node.subtitle,
                     reason: suggestion.reason, via: suggestion.reason.contains(suggestion.via) ? nil : suggestion.via,
                     heading: nil, button: isShow ? "LISTEN" : "DIG IN", icon: isShow ? "play.fill" : "arrow.down.right")
    }

    /// A thing from the mix as a slide: a track plays, a record opens, an
    /// artist or a show as above. Where it leads on the compass, when placed.
    private func card(for item: ForYouItem) -> PhoneForYouSlide.Card {
        let heading = dig.forYouMix.compass?.points.first { $0.id == item.id }?.heading
        switch item.payload {
        case .track(let track):
            return .init(picture: track.artworkURL, kind: track.isRecording ? "Track" : "In a radio show",
                         title: track.title, subtitle: track.artist, reason: track.reason, via: nil, heading: heading,
                         button: track.isRecording ? "PLAY TRACK" : "HEAR IN RADIO SHOW",
                         icon: track.isRecording ? "play.fill" : "dot.radiowaves.left.and.right")
        case .record(let found):
            return .init(picture: found.record.artworkURL, kind: "Record", title: found.record.title,
                         subtitle: item.subtitle, reason: item.reason, via: nil, heading: heading,
                         button: "OPEN RECORD", icon: "arrow.down.right")
        case .suggestion(let suggestion):
            var made = card(for: suggestion)
            made.heading = heading
            return made
        }
    }

    private func act(_ item: ForYouItem) {
        switch item.payload {
        case .track(let track):
            let (media, start) = track.mediaItem
            if !player.isCurrent(media.id) { player.play([media]) }
            if let start { player.seekWhenReady(to: TimeInterval(start), in: media.id) }
        case .record(let found):
            appState.open(.digRelease(id: found.record.id, title: found.record.title))
        case .suggestion(let suggestion):
            Task { await open(suggestion.node) }
        }
    }

    static func kind(of node: MusicNode) -> String {
        switch node.kind {
        case .artist: "Artist"
        case .label: "Label"
        case .release: "Release"
        case .recording: "Track"
        case .broadcast: "Show"
        default: "Suggestion"
        }
    }

    private func open(_ node: MusicNode) async {
        let stations = KeptShow.Stations(nts: ntsBrowse, lot: lotBrowse, dublab: dublabBrowse,
                                         radio80000: radio80000Browse, n10as: n10asBrowse)
        switch await KeptShow.destination(for: node, stations: stations) {
        case .page(let page): appState.open(page)
        case .section(let route): appState.select(route)
        case nil: break
        }
    }
}

struct PhoneForYouSlide: View {
    /// What a slide says, whatever it is.
    struct Card {
        var picture: URL?
        var kind: String
        var title: String
        var subtitle: String?
        var reason: String
        /// What it was reached through, when the reason does not say.
        var via: String?
        /// Where it leads on the compass ("Toward Glitch").
        var heading: String?
        var button: String
        var icon: String
    }

    let card: Card
    let insets: EdgeInsets
    let open: () -> Void
    @Environment(PlaybackCoordinator.self) private var player

    private var picture: URL? { card.picture }

    /// Discogs' thumb, which cannot be asked for larger: drawn as a square
    /// over the moving field at a size it holds, not blown up full-screen.
    private var isSmall: Bool { DiscogsClient.isSmallCut(picture?.absoluteString) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Group {
                    if let picture, isSmall {
                        ZStack {
                            PlayerShaderBackdrop()
                            ArtworkView(remoteURL: picture, side: min(proxy.size.width * 0.62, 260), glyphScale: 0.3)
                                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                                .offset(y: -proxy.size.height * 0.16)
                        }
                    } else if let picture {
                        ArtworkView(remoteURL: picture, side: max(proxy.size.width, proxy.size.height), glyphScale: 0.3)
                    } else {
                        PlayerShaderBackdrop()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 14) {
                    // What it is and its name, why it is here, and what it
                    // was reached through, in IDA's boxes; the button last, at
                    // the bottom, as on every slide.
                    Button(action: open) {
                        VStack(spacing: 8) {
                            ChipFlow { Chip(text: card.kind, tone: .lead, uppercase: true) }
                            ChipFlow { Chip(text: card.title, size: 19) }
                            if let subtitle = card.subtitle, !subtitle.isEmpty {
                                ChipFlow { Chip(text: subtitle, size: 13) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    ChipFlow {
                        Chip(text: card.reason, size: 13)
                    }
                    if let via = card.via {
                        ChipFlow {
                            Chip(text: "Via", tone: .sheen, size: 13, uppercase: true)
                            Chip(text: via, size: 13)
                        }
                    }
                    if let heading = card.heading {
                        ChipFlow { Chip(text: heading, tone: .sheen, size: 12, uppercase: true) }
                    }
                    Button(action: open) {
                        HStack(spacing: 10) {
                            Image(systemName: card.icon)
                            Text(card.button)
                                .font(Typeface.mono(16, weight: .medium))
                                .tracking(2)
                        }
                        .foregroundStyle(Color(red: 0.06, green: 0.1, blue: 0.07))
                        .frame(maxWidth: 260)
                        .frame(height: 54)
                        .background(Color(red: 0.36, green: 0.49, blue: 0.36))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, insets.bottom + 22 + (player.current == nil ? PhoneLayout.miniPlayerRoom : 0))
            }
        }
        .foregroundStyle(.white)
    }
}

private extension StationEntry {
    /// "NTS 1", "Kiosk", "Lot": short enough for a small card.
    var shortLabel: String {
        station.name
            .replacingOccurrences(of: " Radio", with: "")
            .replacingOccurrences(of: "Radio ", with: "")
    }
}
