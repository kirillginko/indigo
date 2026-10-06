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
        case suggestion(ExploreSuggestion)
        case onNow(StationEntry)

        var id: String {
            switch self {
            case .cover: "cover"
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
                let slides: [Slide] = [.cover] + (suggestions.isEmpty
                    ? Self.sampler(entries).map(Slide.onNow)
                    : suggestions.map(Slide.suggestion))
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(slides) { slide in
                            Group {
                                switch slide {
                                case .cover:
                                    PhoneForYouGlobe(
                                        items: globeItems(suggestions: suggestions, entries: entries, playable: playable),
                                        insets: insets
                                    )
                                case .suggestion(let suggestion):
                                    PhoneForYouSlide(
                                        suggestion: suggestion,
                                        portrait: suggestion.node.kind == .artist
                                            ? dig.portraitURL(for: suggestion.node.title) : nil,
                                        insets: insets
                                    ) { Task { await open(suggestion.node) } }
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
        .task(id: crate.revision) { await dig.refreshExploreOffers(crateRevision: crate.revision) }
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
        if !suggestions.isEmpty {
            // All of them, as the Mac's For You shows: up to twenty-four.
            return suggestions.map { suggestion in
                GlobeItem(id: suggestion.id, label: Self.kind(of: suggestion.node), title: suggestion.node.title) {
                    Task { await open(suggestion.node) }
                }
            }
        }
        let stations = entries.map { entry in
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
        let archives = GlobeItem(id: "archives", label: "Archives", title: "Radio on YouTube") {
            PhoneFeeds.shared.showsStation = "Archives"
            appState.select(.shows)
        }
        return stations + [archives]
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

private struct PhoneForYouSlide: View {
    let suggestion: ExploreSuggestion
    let portrait: URL?
    let insets: EdgeInsets
    let open: () -> Void

    private var isShow: Bool { suggestion.node.kind == .broadcast }
    private var picture: URL? { suggestion.node.artworkURL ?? portrait }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Group {
                    if let picture {
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
                        ChipFlow {
                            Chip(text: isShow ? "Radio show" : kindLabel, tone: .lead, uppercase: true)
                            Chip(text: suggestion.node.title, size: 19)
                            if let subtitle = suggestion.node.subtitle, !subtitle.isEmpty {
                                Chip(text: subtitle, size: 13)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    ChipFlow {
                        Chip(text: suggestion.reason, size: 13)
                    }
                    if !suggestion.reason.contains(suggestion.via) {
                        ChipFlow {
                            Chip(text: "Via", tone: .sheen, size: 13, uppercase: true)
                            Chip(text: suggestion.via, size: 13)
                        }
                    }
                    Button(action: open) {
                        HStack(spacing: 10) {
                            Image(systemName: isShow ? "play.fill" : "arrow.down.right")
                            Text(isShow ? "LISTEN" : "DIG IN")
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
                .padding(.bottom, insets.bottom + 22)
            }
        }
        .foregroundStyle(.white)
    }

    private var kindLabel: String {
        switch suggestion.node.kind {
        case .artist: "Artist"
        case .label: "Label"
        case .release: "Release"
        case .recording: "Recording"
        default: "Suggestion"
        }
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
