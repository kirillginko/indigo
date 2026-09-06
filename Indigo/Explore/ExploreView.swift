import SwiftData
import SwiftUI

struct ExploreView: View {
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
    @Environment(DigStore.self) private var dig
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(KioskProvider.self) private var kiosk
    @Environment(NoodsProvider.self) private var noods
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(LYLProvider.self) private var lyl
    @Environment(AlharaProvider.self) private var alhara
    @Environment(LotProvider.self) private var lot
    @Environment(RovrProvider.self) private var rovr
    @Query(sort: [SortDescriptor(\Track.addedAt, order: .reverse)]) private var tracks: [Track]
    @State private var filter = ExploreFilter.all

    var body: some View {
        // The page the shader lives on. Every stall left in the trace happens
        // with nothing measured on the main actor, and a `body` is the last
        // main-thread surface nothing measures — so this one says so. Silent
        // under 50ms, which is nearly always.
        let kept = Trace.slowStep("explore.crate") { crateItems }
        ScrollView {
            VStack(spacing: 0) {
                Trace.slowStep("explore.header") { header(kept) }
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ExploreShaderField(seed: kept.prefix(8).reduce(193) { $0 &* 31 &+ stableSeed($1.displayTitle) })
                        Trace.slowStep("explore.objects") { objects(kept, in: proxy.size) }
                    }
                    .overlayPreferenceValue(ExploreGraphKey.self) { nodes in
                        GeometryReader { geometry in
                            ExploreGraphLines(nodes: nodes, geometry: geometry)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: Trace.slowStep("explore.height") { recommendationHeight(kept) })
            }
        }
        .foregroundStyle(Color.black)
        .background(MapColor.cobalt)
        .task { crate.backfillLocalGenres() }
        // Kept on the store, so coming back to this page shows what it showed
        // last time rather than emptying itself and filling in again. Keyed on
        // the crate rather than on the graph: enrichment moves the graph
        // several times a second and almost none of it changes what should be
        // suggested.
        .task(id: crate.revision) { await dig.refreshExploreOffers(crateRevision: crate.revision) }
    }

    private func header(_ kept: [CrateItem]) -> some View {
        let ink = Color.white
        let inverseInk = Color.black
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start your search here").font(Typeface.display(40)).tracking(-0.7)
                    Text(kept.first.map { "Because you crated \($0.displayTitle)" }
                         ?? "Recommendations shaped by your crate and local library")
                        .microLabel(1.05, size: 9)
                }
                Spacer()
                Button("Crate · \(kept.count)") { appState.select(.crate) }
                    .buttonStyle(MapHeaderButtonStyle(ink: ink))
            }
            HStack(spacing: 7) {
                ForEach(ExploreFilter.allCases) { choice in
                    Button { filter = choice } label: {
                        HStack(spacing: 7) {
                            Rectangle().fill(choice.color).frame(width: 8, height: 8)
                            Text(choice.label).font(Typeface.body(11.5, weight: filter == choice ? .bold : .regular))
                        }
                        .padding(.horizontal, 10).frame(height: 27)
                        .foregroundStyle(filter == choice ? inverseInk : ink)
                        .background(filter == choice ? ink : Color.clear)
                        .overlay(Rectangle().stroke(ink, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.top, Metrics.titleBarInset + 18).padding(.horizontal, 28).padding(.bottom, 16)
        .foregroundStyle(ink)
        .background(IndigoGlassBackground(tint: 0.52, shaderOpacity: 0.27))
    }

    @ViewBuilder private func objects(_ kept: [CrateItem], in size: CGSize) -> some View {
        // Every card is numbered once, across all three kinds, and the three
        // blocks below simply take their slice of that numbering. Each kind
        // used to count from zero, so the first crated record, the first
        // station and the first local track were all placed as item nought and
        // landed on top of one another.
        let offers = dig.exploreOffers
        let suggestions = offers.next
        let showNext = (filter == .all || filter == .next) && !suggestions.isEmpty
        let showCrate = filter == .all || filter == .crate
        let showShows = (filter == .all || filter == .shows) && !offers.shows.isEmpty
        let showLibrary = filter == .all || filter == .library
        let local = localPicks
        let crateSections = recommendationSections(from: kept, adding: offers.artists)
        let hasScene = showNext && offers.movingToward != nil
        let nextTop: CGFloat = 112
        let crateTop = nextTop + (showNext ? sectionHeight(for: suggestions.count, in: size) : 0)
        let sceneTop = crateTop + (showCrate ? crateSections.reduce(0) { $0 + sectionHeight(for: $1.count, in: size) } : 0)
        let showsTop = sceneTop + (hasScene ? sectionHeight(for: 1, in: size) : 0)
        let libraryTop = showsTop + (showShows ? sectionHeight(for: offers.shows.count, in: size) : 0)

        // Directly over the trunk, which `ExploreGraphLines` roots at half the
        // width. It was offset to the right of it, so it read as a caption
        // for whatever happened to be under it rather than as the head of the
        // line everything hangs from.
        ExploreStartLabel()
            .graphNode("start", section: "start", connects: false)
            .position(x: size.width * 0.5, y: 46)

        if kept.isEmpty && tracks.isEmpty {
            Button("Find something to start with") { appState.select(.dig) }
                .buttonStyle(MapHeaderButtonStyle()).position(x: size.width * 0.58, y: 170)
        }
        // First, because it is the only block here that is not already yours.
        // Everything below is the crate, the stations and the library — things
        // this listener has already decided about — and a page that opens on
        // those is an inventory rather than a way of finding anything.
        if showNext {
            ExploreSectionLabel(
                title: "Where to go next",
                description: "Reached from what you keep, and not yet heard"
            )
                .graphNode("section.next", section: "next", connects: false)
                .position(x: size.width * 0.5, y: nextTop + 24)
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, suggestion in
                Button {
                    if let page = suggestion.node.destination { appState.open(page) }
                } label: {
                    MapLabel(suggestion.node.title, suggestion.node.kind.label,
                             MapColor.lavender, artwork(for: suggestion),
                             stableSeed(suggestion.node.id), cardWidth(in: size),
                             connection: suggestion.connection)
                }.buttonStyle(ExploreCardButtonStyle())
                    .graphNode("next.\(suggestion.id)", section: "next", legend: true)
                    .position(place(i, below: nextTop, in: size)).zIndex(5)
            }
        }
        if showCrate {
            ForEach(Array(crateSections.enumerated()), id: \.element.id) { sectionIndex, section in
                let top = crateSectionTop(sectionIndex, sections: crateSections,
                                          start: crateTop, in: size)
                ExploreSectionLabel(title: section.title, description: section.description)
                    .graphNode("section.\(section.id)", section: section.id, connects: false)
                    .position(x: size.width * 0.5, y: top + 24)
                ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                    Button { play(item) } label: {
                        MapLabel(item.displayTitle, item.displaySubtitle ?? item.sourceLine,
                                 MapColor.green, item.artworkURL, stableSeed(item.displayTitle),
                                 cardWidth(in: size))
                    }.buttonStyle(ExploreCardButtonStyle())
                        .contextMenu { Button("Open details") { open(item) } }
                        .graphNode("crate.\(item.id)", section: section.id)
                        .position(place(i, below: top, in: size)).zIndex(4)
                }
                ForEach(Array(section.suggested.enumerated()), id: \.element.id) { i, suggestion in
                    Button {
                        if let page = suggestion.node.destination { appState.open(page) }
                    } label: {
                        MapLabel(suggestion.node.title, suggestion.node.kind.label,
                                 MapColor.lavender, artwork(for: suggestion),
                                 stableSeed(suggestion.id), cardWidth(in: size),
                                 connection: suggestion.connection)
                    }.buttonStyle(ExploreCardButtonStyle())
                        .graphNode("suggested.\(suggestion.id)", section: section.id, legend: true)
                        .position(place(section.items.count + i, below: top, in: size)).zIndex(4)
                }
            }
        }
        // Shows rather than stations. A station is a name and a city — the
        // same seven for everybody, ranked against a bag of genre words —
        // where a show is an hour somebody chose, and Indigo can say what is
        // on it. See `ShowSuggestionEngine`.
        // Below what they can act on now, and only one card wide. A direction
        // is a slower claim than a list of things to try — it is about where
        // somebody is going rather than what to press next — and putting it
        // first pushed the recommendations off the top of the page, which is
        // where the page's actual work is.
        if showNext, let scene = offers.movingToward {
            ExploreSectionLabel(
                title: "You seem to be moving toward",
                description: scene.size
            )
                .graphNode("section.scene", section: "scene", connects: false)
                .position(x: size.width * 0.5, y: sceneTop + 24)
            Button { appState.open(.digScene(city: scene.city, sound: scene.sound)) } label: {
                MapLabel(scene.title, scene.sound, MapColor.lavender, nil,
                         stableSeed(scene.city), cardWidth(in: size),
                         connection: scene.size)
            }.buttonStyle(ExploreCardButtonStyle())
                .graphNode("scene.\(scene.city)", section: "scene", legend: true)
                .position(place(0, below: sceneTop, in: size)).zIndex(6)
        }

        if showShows {
            ExploreSectionLabel(
                title: "Radio shows to check out",
                description: "By who they played and how they sound"
            )
                .graphNode("section.radio", section: "radio", connects: false)
                .position(x: size.width * 0.5, y: showsTop + 24)
            ForEach(Array(offers.shows.enumerated()), id: \.element.id) { i, show in
                Button {
                    if let page = show.node.destination { appState.open(page) }
                } label: {
                    MapLabel(show.node.title, show.node.subtitle, MapColor.paleGreen,
                             show.node.artworkURL, stableSeed(show.id), cardWidth(in: size),
                             connection: show.connection)
                }.buttonStyle(ExploreCardButtonStyle())
                    .graphNode("radio.\(show.id)", section: "radio", legend: true)
                    .position(place(i, below: showsTop, in: size)).zIndex(3)
            }
        }
        if showLibrary {
            ExploreSectionLabel(
                title: "Back in your library",
                description: "Recent local tracks worth reopening"
            )
                .graphNode("section.library", section: "library", connects: false)
                .position(x: size.width * 0.5, y: libraryTop + 24)
            ForEach(Array(local.enumerated()), id: \.element.persistentModelID) { i, track in
                Button { play(i) } label: {
                    MapLabel(track.title, track.artist, MapColor.blue, nil,
                             stableSeed(track.path), cardWidth(in: size))
                        .localArtwork(track.artworkKey)
                }.buttonStyle(ExploreCardButtonStyle())
                    .graphNode("local.\(track.path)", section: "library")
                    .position(place(i, below: libraryTop, in: size)).zIndex(2)
            }
        }
    }

    /// How many of the library to show at once.
    private static let localPickCount = 8

    /// Which local tracks to offer, moved along a little each day.
    ///
    /// It used to be the newest eight, forever — which meant somebody with a
    /// library of twelve thousand files was shown the same eight of them every
    /// time they opened the page, and the block quietly became furniture. The
    /// window walks through the library instead, so a record filed two years
    /// ago comes back around.
    ///
    /// Rotated by the day rather than shuffled: within a day the page is the
    /// same page, which matters because a card that moves between two glances
    /// is one nobody can point at. Recency still decides the order the window
    /// travels in, so the walk starts at the newest and works back.
    private var localPicks: [Track] {
        let all = tracks
        guard all.count > Self.localPickCount else { return all }
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        let start = (day * Self.localPickCount) % all.count
        // Wrapping, so the last day of the cycle is a full block rather than
        // whatever happened to be left at the end of the list.
        return (0..<Self.localPickCount).map { all[(start + $0) % all.count] }
    }

    /// A face for a suggestion, where one has already been found.
    ///
    /// Only from what is in memory: the background portrait fill keeps an
    /// index, and DIG's own artwork ladder needs a store read per card. A row
    /// of names is a list and a row of faces is a shelf, but not at the price
    /// of a dozen fetches on the thread that draws.
    private func artwork(for suggestion: ExploreSuggestion) -> URL? {
        suggestion.node.artworkURL
            ?? (suggestion.node.kind == .artist ? dig.portraitURL(for: suggestion.node.title) : nil)
    }

    private func columnCount(in size: CGSize) -> Int { max(2, min(4, Int(size.width / 430))) }

    private func cellWidth(in size: CGSize) -> CGFloat {
        max(140, (size.width - max(150, size.width * 0.12) - 150) / CGFloat(columnCount(in: size)))
    }

    /// A card stops short of its cell, so that two neighbours never touch even
    /// when both are as wide as they are allowed to be.
    private func cardWidth(in size: CGSize) -> CGFloat { max(150, cellWidth(in: size) - 34) }

    /// Where one card sits, given its number and how many there are.
    ///
    /// The row pitch is divided out of the height actually available rather
    /// than fixed: a constant pitch overran the pane as soon as there were
    /// more than a few rows, and the clamp that caught it stacked every
    /// overflowing card on the bottom edge.
    private func place(_ ordinal: Int, below sectionTop: CGFloat, in size: CGSize) -> CGPoint {
        let columns = columnCount(in: size)
        let column = ordinal % columns, row = ordinal / columns

        let left = max(150, size.width * 0.12)
        let cell = cellWidth(in: size)
        let baseX = left + cell * (CGFloat(column) + 0.5)

        // Preserve a clear corridor around the fixed center spine. Staggered
        // rows used to push the inner cards across it, so the trunk visibly
        // ran through their boxes.
        let halfCard = cardWidth(in: size) * 0.5
        let center = size.width * 0.5
        let centerClearance = halfCard + 44
        let isLeftSide = column < columns / 2
        // Each recommendation drifts farther toward its outside edge by a
        // different amount. The deterministic wave keeps the composition
        // stable between redraws while avoiding a rigid two-column ladder.
        let outwardRange = min(72, max(28, cell * 0.18))
        let outwardDrift = outwardRange
            * (0.35 + 0.65 * abs(CGFloat(cos(Double(ordinal + 1) * 1.73))))
        let rawX = baseX + (isLeftSide ? -outwardDrift : outwardDrift)
        let separatedX = isLeftSide
            ? min(rawX, center - centerClearance)
            : max(rawX, center + centerClearance)
        let x = max(halfCard + 28, min(size.width - halfCard - 28, separatedX))

        // Well clear of the section heading above it. At 104 the first row of
        // cards sat almost against the title and its description, so a
        // section read as one crowded block rather than as a heading and the
        // things under it.
        let top = sectionTop + 148
        let pitch: CGFloat = 142
        let verticalDrift = CGFloat(sin(Double(ordinal + 1) * 1.91)) * 24

        return CGPoint(x: x, y: top + pitch * CGFloat(row) + verticalDrift)
    }

    private func sectionHeight(for count: Int, in size: CGSize) -> CGFloat {
        guard count > 0 else { return 86 }
        let rows = Int((Double(count) / Double(columnCount(in: size))).rounded(.up))
        // Matches the gap `place` leaves under a heading. The two have to move
        // together or the next section's title lands on the last row of cards.
        return 154 + CGFloat(rows) * 142
    }

    private func crateSectionTop(
        _ index: Int,
        sections: [CrateRecommendationSection],
        start: CGFloat,
        in size: CGSize
    ) -> CGFloat {
        start + sections.prefix(index).reduce(0) {
            $0 + sectionHeight(for: $1.count, in: size)
        }
    }

    private func recommendationSections(
        from items: [CrateItem], adding artists: [ExploreSuggestion] = []
    ) -> [CrateRecommendationSection] {
        let definitions: [(String, String, String, (CrateItem) -> Bool)] = [
            ("shows", "Shows", "Broadcasts and episodes you saved", { $0.kind == .broadcast }),
            ("releases", "Releases", "Records to return to", { $0.kind == .release }),
            ("labels", "Labels", "Catalogues connected to your taste", { $0.kind == .label }),
            ("artists", "Artists", "People you keep, and people to meet", { $0.kind == .artist }),
            ("tracks", "Saved tracks", "Individual recordings in your crate", { $0.kind == .recording })
        ]
        return definitions.compactMap { id, title, description, includes in
            let matches = items.filter(includes)
            // Artists you keep, then artists to meet. Kept in one block rather
            // than two, because they answer the same question — who to start
            // another search from — and the cards say which is which: a
            // suggestion carries the reason it is being offered, and a colour
            // of its own.
            let suggested = id == "artists" ? artists : []
            guard !matches.isEmpty || !suggested.isEmpty else { return nil }
            return CrateRecommendationSection(
                id: id, title: title, description: description,
                items: matches, suggested: suggested
            )
        }
    }

    private var crateItems: [CrateItem] { let _ = crate.revision; return crate.items() }
    private func recommendationHeight(_ kept: [CrateItem]) -> CGFloat {
        // Two columns is the narrowest supported layout, so this estimate is
        // conservative without leaving one full row of whitespace per card.
        let offers = dig.exploreOffers
        let sections = recommendationSections(from: kept, adding: offers.artists)
        let rows: Int
        switch filter {
        case .all:
            rows = (offers.next.count + 1) / 2 + (offers.movingToward == nil ? 0 : 1)
                + sections.reduce(0) { $0 + ($1.count + 1) / 2 }
                + (offers.shows.count + 1) / 2 + (localPicks.count + 1) / 2
        case .next:
            rows = (offers.next.count + 1) / 2
        case .crate:
            rows = sections.reduce(0) { $0 + ($1.count + 1) / 2 }
        case .shows:
            rows = (offers.shows.count + 1) / 2
        case .library:
            rows = (localPicks.count + 1) / 2
        }
        return max(760, 112 + CGFloat(rows) * 142 + CGFloat(visibleSectionCount(kept)) * 154)
    }
    private func visibleSectionCount(_ kept: [CrateItem]) -> Int {
        switch filter {
        case .all: recommendationSections(from: kept, adding: dig.exploreOffers.artists).count + 4
        case .crate: recommendationSections(from: kept, adding: dig.exploreOffers.artists).count
        case .next, .shows, .library: 1
        }
    }
    private func play(_ index: Int) {
        let queue = localPicks; guard queue.indices.contains(index) else { return }
        if player.isCurrent(queue[index].path) { player.toggle() } else { player.play(queue.mediaItems(), startingAt: index) }
    }
    private func play(_ item: CrateItem) {
        guard let source = SourceResolver(context: crate.context).best(item) else {
            open(item)
            return
        }
        switch source.action {
        case .play(let media): play(media)
        case .openBroadcast(let page, _): appState.open(page)
        }
    }

    private func play(_ media: MediaItem) {
        if player.isCurrent(media.id) {
            player.toggle()
        } else if media.isLive {
            player.playRadio(media)
        } else if media.isEmbedded {
            player.playEpisode(media)
        } else {
            player.play([media])
        }
    }

    private func open(_ item: CrateItem) {
        if let recording = item.recording { appState.open(.digRecording(id: recording.id, title: item.displayTitle)); return }
        if let id = item.showID, let provider = item.providerID,
           let page = BroadcastSource.destination(showID: id, providerID: provider) { appState.open(page); return }
        guard let id = item.showID else { appState.select(.crate); return }
        switch (item.kind, item.providerID) {
        case (.artist, "dig.artist.mbid"):
            appState.open(.digArtist(mbid: id, name: item.displayTitle))
        case (.artist, "dig.artist.name"):
            appState.open(.digArtist(mbid: nil, name: item.displayTitle))
        case (.release, "dig.release.discogs"):
            if let releaseID = Int(id) {
                appState.open(.digRelease(id: releaseID, title: item.displayTitle))
            } else {
                appState.select(.crate)
            }
        case (.label, "dig.label.mbid"):
            appState.open(.digLabel(mbid: id, name: item.displayTitle))
        case (.label, "dig.label.discogs"):
            appState.open(.digDiscogsLabel(name: item.displayTitle))
        default:
            appState.select(.crate)
        }
    }
}

private enum ExploreFilter: String, CaseIterable, Identifiable {
    case all, next, crate, shows, library
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All recommendations"
        case .next: "Where to go next"
        case .crate: "From your crate"
        case .shows: "Radio shows to check out"
        case .library: "Your library"
        }
    }
    var color: Color {
        switch self {
        case .all: .black
        case .next: MapColor.lavender
        case .crate: MapColor.green
        case .shows: MapColor.paleGreen
        case .library: MapColor.blue
        }
    }
}

private enum MapColor {
    static let cobalt = Color(red: 0.10, green: 0.34, blue: 0.91)
    static let blue = Color(red: 0.12, green: 0.45, blue: 0.96)
    static let blueLight = Color(red: 0.28, green: 0.82, blue: 0.94)
    static let green = Color(red: 0.29, green: 0.94, blue: 0.57)
    static let paleGreen = Color(red: 0.45, green: 0.96, blue: 0.68)
    static let paper = Color(red: 0.94, green: 0.96, blue: 0.94)
    static let lavender = Color(red: 0.73, green: 0.83, blue: 0.98)
}

private struct CrateRecommendationSection: Identifiable {
    let id: String
    let title: String
    let description: String
    let items: [CrateItem]
    var suggested: [ExploreSuggestion] = []

    /// Both halves, for laying out and for measuring.
    var count: Int { items.count + suggested.count }
}

private struct ExploreSectionLabel: View {
    let title: String
    let description: String

    var body: some View {
        // Title left, description right, with the trunk passing between them.
        // Both halves are held back from the middle by the same clearance the
        // cards keep, so a long description cannot grow across the line —
        // which is the only way this row and the graph can collide, the two
        // never sharing a horizontal band with a card.
        GeometryReader { proxy in
            let half = max(120, proxy.size.width * 0.5 - 44)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(title)
                    .font(Typeface.body(15, weight: .bold))
                    .frame(maxWidth: half, alignment: .leading)
                Spacer(minLength: 24)
                Text(description)
                    .font(Typeface.body(11.5))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: half, alignment: .trailing)
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 34)
        .foregroundStyle(Color.black)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

private struct ExploreStartLabel: View {
    var body: some View {
        Text("Start your search here")
            .font(Typeface.body(11.5))
            .foregroundStyle(Color.black)
            .allowsHitTesting(false)
    }
}

private struct MapLabel: View {
    let title: String; let subtitle: String?; let color: Color; let imageURL: URL?; let seed: Int
    var localArtworkKey: String?
    /// What the card is allowed to grow to. Sized to its text instead, a long
    /// album title runs straight through whatever is placed beside it — which
    /// no amount of spacing in the layout can avoid, because the layout is
    /// working from a width the card has already exceeded.
    let maxWidth: CGFloat
    let connection: String?
    init(_ t: String, _ s: String?, _ c: Color, _ u: URL?, _ seed: Int, _ maxWidth: CGFloat, connection: String? = nil) {
        title=t; subtitle=s; color=c; imageURL=u; self.seed=seed; self.maxWidth=maxWidth
        self.connection = connection
        self.localArtworkKey = nil
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if localArtworkKey != nil || imageURL != nil {
                ArtworkView(localKey: localArtworkKey, remoteURL: imageURL, side: 42,
                            mark: String(title.prefix(1)))
                    .overlay(Rectangle().stroke(.black, lineWidth: 5))
            }
            else { MapGlyph(seed: seed, color: color).frame(width: 42, height: 42) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Rectangle().frame(width: 7, height: 7); Text(title).font(Typeface.body(12.5, weight: .bold)).lineLimit(1) }
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(Typeface.mono(8.5)).opacity(0.72).lineLimit(1).padding(.leading, 13) }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .foregroundStyle(Color.black)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().stroke(Color.black.opacity(0.48), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if let connection {
                Text(connection)
                    .font(Typeface.mono(8.5))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .offset(y: -19)
                    .allowsHitTesting(false)
                    .help(connection)
            }
        }
    }

    func localArtwork(_ key: String?) -> Self {
        var copy = self
        copy.localArtworkKey = key
        return copy
    }
}

private struct ExploreCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ExploreCardInteraction(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct ExploreCardInteraction<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .offset(y: reduceMotion || !isHovered || isPressed ? 0 : -3)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
    }
}

private struct ExploreGraphNode {
    let id: String
    let section: String
    let bounds: Anchor<CGRect>
    let legend: Bool
    let connects: Bool
}

private struct ExploreGraphKey: PreferenceKey {
    static var defaultValue: [ExploreGraphNode] { [] }
    static func reduce(value: inout [ExploreGraphNode], nextValue: () -> [ExploreGraphNode]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func graphNode(
        _ id: String,
        section: String,
        legend: Bool = false,
        connects: Bool = true
    ) -> some View {
        anchorPreference(key: ExploreGraphKey.self, value: .bounds) {
            [ExploreGraphNode(id: id, section: section, bounds: $0,
                              legend: legend, connects: connects)]
        }
    }
}

/// One drawing pass, independent of the animated shader. Actual card anchors
/// keep the branches attached when the window, filter, or hover position changes.
private struct ExploreGraphSegments {
    private var horizontal: [CGFloat: [ClosedRange<CGFloat>]] = [:]
    private var vertical: [CGFloat: [ClosedRange<CGFloat>]] = [:]

    mutating func add(from: CGPoint, to: CGPoint) {
        guard from != to else { return }
        if from.y == to.y {
            horizontal[from.y, default: []].append(min(from.x, to.x)...max(from.x, to.x))
        } else {
            vertical[from.x, default: []].append(min(from.y, to.y)...max(from.y, to.y))
        }
    }

    // Union collinear runs, including partially overlapping branches. Shared
    // trunks become one stroke instead of a bundle of darker parallel paths.
    var path: Path {
        var result = Path()
        func append(_ lines: [CGFloat: [ClosedRange<CGFloat>]], horizontal: Bool) {
            for (axis, ranges) in lines {
                let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
                guard var current = sorted.first else { continue }
                var merged: [ClosedRange<CGFloat>] = []
                for next in sorted.dropFirst() {
                    if next.lowerBound <= current.upperBound {
                        current = current.lowerBound...max(current.upperBound, next.upperBound)
                    } else {
                        merged.append(current)
                        current = next
                    }
                }
                merged.append(current)
                for range in merged {
                    result.move(to: horizontal ? CGPoint(x: range.lowerBound, y: axis)
                                               : CGPoint(x: axis, y: range.lowerBound))
                    result.addLine(to: horizontal ? CGPoint(x: range.upperBound, y: axis)
                                                  : CGPoint(x: axis, y: range.upperBound))
                }
            }
        }
        append(horizontal, horizontal: true)
        append(vertical, horizontal: false)
        return result
    }
}

private struct ExploreGraphLines: View {
    let nodes: [ExploreGraphNode]
    let geometry: GeometryProxy

    var body: some View {
        Canvas { context, _ in
            guard !nodes.isEmpty else { return }
            // Merged rather than required-unique. Two cards sharing an id is
            // a mistake in whatever laid them out, and the honest response to
            // it is one missing line — not `uniqueKeysWithValues` trapping
            // inside a display list and taking the window with it, which is
            // exactly what a section id colliding with a crate section's id
            // did.
            let frames = Dictionary(
                nodes.map { ($0.id, geometry[$0.bounds]) }, uniquingKeysWith: { first, _ in first }
            )
            // The cards reserve a matching clear corridor around this fixed
            // midpoint, so the trunk cannot drift into a recommendation.
            let centerX = geometry.size.width * 0.5
            let root = CGPoint(x: centerX, y: 72)
            var segments = ExploreGraphSegments()
            var lastJunction = root.y
            var connected = Set<String>()
            for node in nodes {
                guard node.connects,
                      connected.insert(node.id).inserted,
                      let frame = frames[node.id] else { continue }
                let destination = CGPoint(x: frame.midX,
                                          y: frame.minY - (node.legend ? 26 : 5))
                let entryY = destination.y - 18
                lastJunction = max(lastJunction, entryY)
                // One branch per card, irrespective of which labelled section
                // it belongs to. Sections organize the recommendations; they
                // do not introduce another layer of wiring.
                segments.add(from: CGPoint(x: centerX, y: entryY),
                             to: CGPoint(x: destination.x, y: entryY))
                segments.add(from: CGPoint(x: destination.x, y: entryY), to: destination)
            }
            segments.add(from: root, to: CGPoint(x: centerX, y: lastJunction))
            context.stroke(segments.path, with: .color(.black.opacity(0.27)),
                           style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))

        }
    }
}

private struct MapGlyph: View {
    let seed: Int; let color: Color
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black)); let u=size.width/6
            for y in 0..<6 { for x in 0..<6 {
                let n=(seed &+ x &* 13 &+ y &* 29 &+ x &* y) & 15
                context.fill(Path(CGRect(x: CGFloat(x)*u, y: CGFloat(y)*u, width: u+0.3, height: u+0.3)), with: .color(n < 5 ? color : n < 8 ? .white.opacity(0.3) : .black))
            }}
        }.padding(5).background(.black).accessibilityHidden(true)
    }
}

private struct ExploreShaderField: View {
    let seed: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white)
                    .colorEffect(
                        ShaderLibrary.exploreOffsetField(
                            .float2(proxy.size),
                            .float(reduceMotion
                                   ? 0
                                   : timeline.date.timeIntervalSince(startedAt)),
                            .float(Float(seed & 1023))
                        )
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Drawn in one ink or the other, because the same button sits on the black
/// header and on the field, and a single colour is invisible on one of them.
private struct MapHeaderButtonStyle: ButtonStyle {
    var ink: Color = .black
    private var ground: Color { ink == .black ? .white : .black }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.microLabel(0.9, size: 9)
            .padding(.horizontal, 11).frame(height: 30)
            .foregroundStyle(configuration.isPressed ? ground : ink)
            .background(configuration.isPressed ? ink : .clear)
            .overlay(Rectangle().stroke(ink))
    }
}
private func stableSeed(_ text:String)->Int { text.unicodeScalars.reduce(5381){($0 &* 33)^Int($1.value)} }
