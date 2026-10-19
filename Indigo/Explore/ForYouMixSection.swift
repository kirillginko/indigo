//
//  ForYouMixSection.swift
//  Indigo
//
//  For You as one list beside its compass (`ForYouMix`, `MusicalCompass`):
//  on the Mac a band above the map, on the phone a slide after the cover.
//  Each row is numbered as its point on the compass is, says what it is and
//  why it is here, and which way it leads; a track plays, everything else
//  opens. Development and internal builds only (`ForYouMixFeature`).
//

import SwiftUI
import SwiftData

struct ForYouMixState: Sendable {
    var items: [ForYouItem] = []
    var compass: MusicalCompass?
    var at: Date?
}

extension DigStore {
    /// Everything the mix is made of, then the mix.
    func refreshForYouMix() async {
        guard ForYouMixFeature.isEnabled else { return }
        await composeForYouMix()
        async let tracks: Void = refreshDiscover()
        async let records: Void = refreshSimilarRecords()
        _ = await (tracks, records)
        await composeForYouMix()
        if ForYouClusterSeedsFeature.isEnabled {
            await refreshClusterSeedPicks()
            await composeForYouMix()
        }
    }

    /// Cluster-seed picks, worked out off the main thread at most every half
    /// hour: building the profile reads the whole history (seconds), and the
    /// seeds' releases and every pick's recording are asked about.
    func refreshClusterSeedPicks() async {
        guard ForYouClusterSeedsFeature.isEnabled else { return }
        if let at = clusterSeedPicksAt, Date().timeIntervalSince(at) < 30 * 60 { return }
        clusterSeedPicksAt = Date()
        let container = context.container, vectors = similarRecords.styleVectors
        let offered = Set(forYouMix.items.flatMap(\.artistKeys))
        let picks = await Task.detached(priority: .utility) { () -> [DiscoveredTrack] in
            let started = Date()
            func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
            let context = ModelContext(container)
            let key = ClusterSeedPicks.fingerprint(context: context)
            let keyed = ms(started)
            // The same history and the same style caches: the same picks.
            if let kept = await ClusterSeedStore.shared.picks(for: key) {
                Trace.note("foryou.clusterSeeds kept: \(kept.count) picks, fingerprint \(keyed)ms")
                return kept
            }
            var t = Date()
            guard let inputs = ClusterSeedPicks.inputs(context: context, vectors: vectors) else { return [] }
            let read = ms(t)
            t = Date()
            let picks = await ClusterSeedPicks.live.picks(inputs, excluding: offered)
            let found = ms(t)
            await ClusterSeedStore.shared.keep(picks: picks, for: key)
            Trace.note("foryou.clusterSeeds \(inputs.seeds.count) seeds over \(inputs.profile.clusters.count) clusters, \(picks.count) picks in \(ms(started))ms (fingerprint \(keyed), history + profile \(read), credits + ranking + recordings \(found))")
            return picks
        }.value
        clusterSeedPicks = picks
    }

    /// Counts alone miss a replacement list with the same number of items.
    var forYouMixInputIDs: [[String]] {
        [mixOffers.next.map(\.id), mixOffers.artists.map(\.id), mixOffers.shows.map(\.id),
         exploreOffers.next.map(\.id), exploreOffers.artists.map(\.id), exploreOffers.shows.map(\.id),
         discover.tracks.map(\.id), similarRecords.records.map { String($0.id) }, clusterSeedPicks.map(\.id)]
    }

    /// The mix and its compass from what is on hand now: pure, apart from
    /// reading the listener's rows and the artists' tags off the main thread.
    func composeForYouMix() async {
        guard ForYouMixFeature.isEnabled else { return }
        forYouMixComposition &+= 1
        let composition = forYouMixComposition
        let offers = mixOffers.isEmpty ? exploreOffers : mixOffers, tracks = discover.tracks
        let records = similarRecords.records, vectors = similarRecords.styleVectors
        let seeded = ForYouClusterSeedsFeature.isEnabled ? clusterSeedPicks : []
        let container = context.container
        let (items, compass) = await Task.detached(priority: .utility) {
            Trace.step("foryou.mix") { () -> ([ForYouItem], MusicalCompass?) in
                let context = ModelContext(container)
                let now = Date()
                let personal = PersonalInputs.read(context: context, asOf: now)
                let offered = Set(tracks.map { RecordingKey.normalizeArtist($0.artist) }
                    + (offers.next + offers.artists).filter { $0.node.kind == .artist }.map { RecordingKey.normalizeArtist($0.node.title) })
                let tags = LocalKnowledgeAdapter.artistTags(for: offered.union(personal.tasteArtistKeys), in: context)
                var items = ForYouMix.mix(offers: offers, tracks: tracks, records: records, artistTags: tags, turn: RecommendationRotation.period(at: now))
                // For You's list first; the cluster seeds after it, nobody twice.
                var claimed = Set(items.flatMap(\.artistKeys))
                for track in seeded {
                    let key = RecordingKey.normalizeArtist(track.artist)
                    guard claimed.insert(key).inserted else { continue }
                    items.append(ForYouItem(kind: .track, payload: .track(track), artistKeys: [key], title: track.title,
                                            subtitle: track.artist, reason: track.reason, via: track.via,
                                            viaID: ListeningSurface.discogsArtist(track.viaDiscogsID), tags: track.tags ?? [],
                                            route: track.reason.hasPrefix("Chosen by") ? "cluster-selection" : "cluster-seed"))
                }
                let longTerm = TasteProfile.collected(personal: personal, artistTags: tags, now: now).weights
                let recent = MusicalCompass.recentTaste(personal, artistTags: tags, asOf: now)
                let compass = MusicalCompass.draw(longTerm: longTerm, recent: recent,
                                                  items: items.map { (id: $0.id, tags: $0.tags) }, vectors: vectors)
                return (items, compass)
            }
        }.value
        guard !Task.isCancelled, composition == forYouMixComposition else { return }
        forYouMix = ForYouMixState(items: items, compass: compass, at: Date())
    }
}

struct ForYouMixSection: View {
    @Environment(DigStore.self) private var dig
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var player
    @Environment(NTSBrowseStore.self) private var ntsBrowse
    @Environment(LotBrowseStore.self) private var lotBrowse
    @Environment(DublabBrowseStore.self) private var dublabBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(N10ASBrowseStore.self) private var n10asBrowse
    @Environment(\.isPhoneLayout) private var isPhone
    var shown = 12

    var body: some View {
        let state = dig.forYouMix
        // The cluster seeds come after For You's own list: shown beside it,
        // not cut off by it.
        let own = state.items.filter { $0.route?.hasPrefix("cluster") != true }
        let seeded = state.items.filter { $0.route?.hasPrefix("cluster") == true }
        let items = Array(own.prefix(shown)) + seeded
        let points = Dictionary((state.compass?.points ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Group {
            if !items.isEmpty {
                DigSection(title: "For you", trailing: isPhone ? nil : "\(items.count) to hear, follow and look at") {
                    let layout = isPhone ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                                         : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                    layout {
                        if let compass = state.compass {
                            CompassView(compass: compass, numbers: Dictionary(items.enumerated().map { ($0.element.id, $0.offset + 1) },
                                                                              uniquingKeysWith: { first, _ in first }))
                                .frame(width: isPhone ? nil : 300)
                                .frame(maxWidth: isPhone ? .infinity : 300)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(index + 1, item, point: points[item.id])
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .foregroundStyle(Palette.ink)
                .background(Color.white.opacity(0.94))
                // A light panel in either appearance: Ink turns light in dark mode.
                .environment(\.colorScheme, .light)
                .padding(.horizontal, isPhone ? 0 : 28).padding(.top, 18)
            }
        }
        .task { await dig.refreshForYouMix() }
        .task(id: dig.forYouMixInputIDs) {
            await dig.composeForYouMix()
        }
    }

    private func row(_ number: Int, _ item: ForYouItem, point: MusicalCompass.Point?) -> some View {
        Button { act(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)").font(Typeface.mono(11, weight: .medium)).frame(width: 18, alignment: .trailing).opacity(0.6)
                Text(Self.chip(item.kind)).font(Typeface.mono(9.5, weight: .medium))
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(Self.color(item.kind).opacity(0.25))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Typeface.body(13.5, weight: .medium)).lineLimit(1)
                    Text(item.subtitle).font(Typeface.mono(11)).lineLimit(1)
                    Text(item.reason).font(Typeface.mono(10.5)).opacity(0.65).lineLimit(2)
                    if let point {
                        Text(point.heading == "Close to home" ? point.heading : "\(point.heading) · \(Self.closeness(point.distance))")
                            .font(Typeface.mono(10)).opacity(0.5)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.chip(item.kind)): \(item.title), \(item.subtitle). \(item.reason)")
    }

    static func chip(_ kind: ForYouItem.Kind) -> String {
        switch kind {
        case .track: "▶ TRACK"
        case .artist: "ARTIST"
        case .record: "RECORD"
        case .show: "((•)) SHOW"
        }
    }

    static func color(_ kind: ForYouItem.Kind) -> Color {
        switch kind {
        case .track: Color.green
        case .artist: Color.blue
        case .record: Color.orange
        case .show: Color.purple
        }
    }

    static func closeness(_ distance: Double) -> String {
        distance < 0.25 ? "near" : distance < 0.6 ? "a step out" : "far out"
    }

    private func act(_ item: ForYouItem) {
        switch item.payload {
        case .track(let track):
            let (media, start) = track.mediaItem
            if !player.isCurrent(media.id) { player.play([media], from: ListeningSurface(screen: "foryou.mix", via: item.via, viaID: item.viaID, route: item.route ?? item.kind.rawValue)) }
            if let start { player.seekWhenReady(to: TimeInterval(start), in: media.id) }
        case .record(let found):
            appState.open(.digRelease(id: found.record.id, title: found.record.title), from: ListeningSurface(screen: "foryou.mix", via: item.via, viaID: item.viaID, route: item.route ?? item.kind.rawValue).asOrigin)
        case .suggestion(let suggestion):
            Task {
                let stations = KeptShow.Stations(nts: ntsBrowse, lot: lotBrowse, dublab: dublabBrowse,
                                                 radio80000: radio80000Browse, n10as: n10asBrowse)
                switch await KeptShow.destination(for: suggestion.node, stations: stations) {
                case .page(let page): appState.open(page, from: ListeningSurface(screen: "foryou.mix", via: item.via, viaID: item.viaID, route: item.route ?? item.kind.rawValue).asOrigin)
                case .section(let route): appState.select(route)
                case nil: break
                }
            }
        }
    }
}

/// The compass: two axes named by their ends, "You" at the centre, "Now"
/// with an arrow from it, and each offer as its number.
struct CompassView: View {
    let compass: MusicalCompass
    let numbers: [String: Int]
    static let inset: CGFloat = 12

    /// A point's place in a frame: "You" at the centre, the edge one.
    static func position(_ point: MusicalCompass.Point, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(point.x) * (size.width / 2 - inset),
                y: size.height / 2 - CGFloat(point.y) * (size.height / 2 - inset))
    }

    var body: some View {
        // The axes' names outside the plot, so no point ever sits on one.
        VStack(spacing: 4) {
            Text("↑ \(compass.vertical.1)")
            plot
            Text("↓ \(compass.vertical.0)")
            HStack {
                Text("← \(compass.horizontal.0)")
                Spacer(minLength: 8)
                Text("\(compass.horizontal.1) →")
            }
        }
        .font(Typeface.mono(9.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Musical compass: \(compass.horizontal.0) to \(compass.horizontal.1) across, \(compass.vertical.0) to \(compass.vertical.1) up")
    }

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let inset = Self.inset
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let at = { (point: MusicalCompass.Point) in Self.position(point, in: size) }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: inset, y: centre.y)); path.addLine(to: CGPoint(x: size.width - inset, y: centre.y))
                    path.move(to: CGPoint(x: centre.x, y: inset)); path.addLine(to: CGPoint(x: centre.x, y: size.height - inset))
                }
                .stroke(Color.black.opacity(0.2), lineWidth: 1)
                if let now = compass.now {
                    Path { path in path.move(to: centre); path.addLine(to: at(now)) }
                        .stroke(Color.black.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                ForEach(compass.points, id: \.id) { point in
                    if let number = numbers[point.id] {
                        Text("\(number)").font(Typeface.mono(9, weight: .medium))
                            .frame(width: 16, height: 16).background(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.5)))
                            .position(at(point))
                    }
                }
                if let now = compass.now {
                    Circle().stroke(Color.black, lineWidth: 1.5).frame(width: 12, height: 12).position(at(now))
                    Text("Now").font(Typeface.mono(9.5, weight: .medium)).padding(.horizontal, 2).background(Color.white)
                        .position(x: at(now).x, y: at(now).y - 13)
                }
                Circle().fill(Color.black).frame(width: 10, height: 10).position(centre)
                Text("You").font(Typeface.mono(9.5, weight: .medium)).padding(.horizontal, 2).background(Color.white)
                    .position(x: centre.x + 18, y: centre.y - 11)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
