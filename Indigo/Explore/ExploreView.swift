import SwiftData
import SwiftUI

struct ExploreView: View {
    @Environment(AppState.self) private var appState
    @Environment(CrateService.self) private var crate
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

    private let stations = [
        ExploreStation("Kiosk Radio", "Brussels", .kioskStation, ["ambient", "jazz"]),
        ExploreStation("Noods Radio", "Bristol", .noodsStation, ["dub", "ambient"]),
        ExploreStation("Cashmere Radio", "Berlin", .cashmereStation, ["experimental", "jazz"]),
        ExploreStation("LYL Radio", "Lyon", .lylStation, ["dub", "electronic"]),
        ExploreStation("Radio alHara", "Bethlehem", .alharaStation("alhara.ra"), ["world", "ambient"]),
        ExploreStation("The Lot Radio", "Brooklyn", .lotStation, ["house", "jazz"]),
        ExploreStation("ROVR", "Your local time", .rovrStation("rovr.live"), ["electronic", "ambient"])
    ]

    var body: some View {
        let kept = crateItems
        ScrollView {
            VStack(spacing: 0) {
                header(kept)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ExploreShaderField(seed: kept.prefix(8).reduce(193) { $0 &* 31 &+ stableSeed($1.displayTitle) })
                        objects(kept, in: proxy.size)
                    }
                    .overlayPreferenceValue(ExploreGraphKey.self) { nodes in
                        GeometryReader { geometry in
                            ExploreGraphLines(nodes: nodes, geometry: geometry)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: max(760, CGFloat(visibleCount(kept)) * 70))
            }
        }
        .foregroundStyle(Color.black)
        .background(MapColor.cobalt)
        .task { crate.backfillLocalGenres() }
    }

    private func header(_ kept: [CrateItem]) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Explore").font(Typeface.display(40)).tracking(-0.7)
                    Text(kept.first.map { "Because you crated \($0.displayTitle)" }
                         ?? "Recommendations and your local library")
                        .microLabel(1.05, size: 9)
                }
                Spacer()
                Button("Crate · \(kept.count)") { appState.select(.crate) }
                    .buttonStyle(MapHeaderButtonStyle(ink: .white))
            }
            HStack(spacing: 7) {
                ForEach(ExploreFilter.allCases) { choice in
                    Button { filter = choice } label: {
                        HStack(spacing: 7) {
                            Rectangle().fill(choice.color).frame(width: 8, height: 8)
                            Text(choice.label).font(Typeface.body(11.5, weight: filter == choice ? .bold : .regular))
                        }
                        .padding(.horizontal, 10).frame(height: 27)
                        .foregroundStyle(filter == choice ? Color.black : Color.white)
                        .background(filter == choice ? Color.white : Color.clear)
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.top, Metrics.titleBarInset + 18).padding(.horizontal, 28).padding(.bottom, 16)
        .foregroundStyle(Color.white)
        .background(Color.black)
    }

    @ViewBuilder private func objects(_ kept: [CrateItem], in size: CGSize) -> some View {
        // Every card is numbered once, across all three kinds, and the three
        // blocks below simply take their slice of that numbering. Each kind
        // used to count from zero, so the first crated record, the first
        // station and the first local track were all placed as item nought and
        // landed on top of one another.
        let showCrate = filter == .all || filter == .crate
        let showStations = filter == .all || filter == .stations
        let showLibrary = filter == .all || filter == .library
        let local = Array(tracks.prefix(8))
        let recommendations = stationRecommendations(from: kept)
        let stationsFirst = showCrate ? kept.count : 0
        let libraryFirst = stationsFirst + (showStations ? recommendations.count : 0)
        let total = libraryFirst + (showLibrary ? local.count : 0)

        if kept.isEmpty && tracks.isEmpty {
            Button("Crate something to start your map") { appState.select(.dig) }
                .buttonStyle(MapHeaderButtonStyle()).position(x: size.width * 0.58, y: 170)
        }
        if showCrate {
            ForEach(Array(kept.enumerated()), id: \.element.id) { i, item in
                Button { play(item) } label: {
                    MapLabel(item.displayTitle, item.displaySubtitle ?? item.sourceLine,
                             MapColor.green, item.artworkURL, stableSeed(item.displayTitle),
                             cardWidth(in: size))
                }.buttonStyle(ExploreCardButtonStyle())
                    .contextMenu { Button("Open details") { open(item) } }
                    .graphNode("crate.\(item.id)")
                    .position(place(i, of: total, in: size)).zIndex(4)
            }
        }
        if showStations {
            ForEach(Array(recommendations.enumerated()), id: \.element.station.id) { i, recommendation in
                let station = recommendation.station
                Button { play(station) } label: {
                    MapLabel(station.name, station.city, MapColor.paleGreen, nil,
                             stableSeed(station.name), cardWidth(in: size),
                             connection: recommendation.connection)
                }.buttonStyle(ExploreCardButtonStyle())
                    .contextMenu { Button("Open station") { appState.select(station.route) } }
                    .graphNode("station.\(station.id)", legend: true)
                    .position(place(stationsFirst + i, of: total, in: size)).zIndex(3)
            }
        }
        if showLibrary {
            ForEach(Array(local.enumerated()), id: \.element.persistentModelID) { i, track in
                Button { play(i) } label: {
                    MapLabel(track.title, track.artist, MapColor.blue, nil,
                             stableSeed(track.path), cardWidth(in: size))
                }.buttonStyle(ExploreCardButtonStyle())
                    .graphNode("local.\(track.path)")
                    .position(place(libraryFirst + i, of: total, in: size)).zIndex(2)
            }
        }
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
    private func place(_ ordinal: Int, of total: Int, in size: CGSize) -> CGPoint {
        let columns = columnCount(in: size)
        let rows = max(1, Int((Double(max(total, 1)) / Double(columns)).rounded(.up)))
        let column = ordinal % columns, row = ordinal / columns

        let left = max(150, size.width * 0.12)
        let cell = cellWidth(in: size)
        // Alternate rows are nudged over, so two long titles in the same
        // column never sit squarely one above the other.
        let x = left + cell * (CGFloat(column) + 0.5) + (row.isMultiple(of: 2) ? 0 : cell * 0.34)

        let top: CGFloat = 96, foot: CGFloat = 84
        let pitch = max(96, (size.height - top - foot) / CGFloat(rows))
        // Bounded to a third of the pitch: enough to break up the grid, never
        // enough to reach the row above or below it.
        let drift = CGFloat((ordinal &* 37) % 100) / 100 - 0.5
        let y = top + pitch * (CGFloat(row) + 0.5) + drift * pitch * 0.34

        return CGPoint(x: min(size.width - 110, x),
                       y: min(size.height - foot, max(top, y)))
    }

    private var crateItems: [CrateItem] { let _ = crate.revision; return crate.items() }
    private func stationRecommendations(from kept: [CrateItem])
        -> [(station: ExploreStation, connection: String)] {
        // Build the taste index once, rather than fetching and sorting the crate
        // inside every comparison and again for every explanation.
        var weights: [String: Double] = [:]
        var sources: [String: String] = [:]
        for (index, item) in kept.prefix(40).enumerated() {
            for tag in item.genreTags {
                let key = LibraryKey.normalize(tag)
                guard !key.isEmpty else { continue }
                weights[key, default: 0] += max(0.2, 1 - Double(index) * 0.025)
                if sources[key] == nil {
                    sources[key] = item.displayTitle
                }
            }
        }
        let tastes = weights.keys.sorted {
            let left = weights[$0, default: 0], right = weights[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }
        var ranked: [(station: ExploreStation, connection: String, score: Int)] = []
        for station in stations {
            let matches = tastes.enumerated().filter { _, taste in
                station.tags.contains { taste.contains($0) }
            }
            let score = matches.reduce(0) { $0 + max(1, 10 - $1.offset) }
            let connection: String
            if let match = matches.first, let title = sources[match.element] {
                let genres = matches.prefix(2).map(\.element).joined(separator: " / ")
                connection = "\(genres) ↔ \(title)"
            } else {
                connection = "\(station.city) · \(station.tags.joined(separator: " / "))"
            }
            ranked.append((station: station, connection: connection, score: score))
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.station.name < rhs.station.name }
            return lhs.score > rhs.score
        }
        return ranked.map { (station: $0.station, connection: $0.connection) }
    }

    private func visibleCount(_ kept: [CrateItem]) -> Int {
        filter == .crate ? kept.count : filter == .stations ? stations.count : filter == .library ? min(8, tracks.count) : kept.count + stations.count + min(8, tracks.count)
    }
    private func play(_ index: Int) {
        let queue = Array(tracks.prefix(8)); guard queue.indices.contains(index) else { return }
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

    private func play(_ station: ExploreStation) {
        let media: MediaItem?
        switch station.route {
        case .kioskStation: media = kiosk.mediaItem()
        case .noodsStation: media = noods.mediaItem()
        case .cashmereStation: media = cashmere.mediaItem()
        case .lylStation: media = lyl.mediaItem()
        case .alharaStation(let id): media = alhara.mediaItem(for: id)
        case .lotStation: media = lot.mediaItem()
        case .rovrStation(let id): media = rovr.mediaItem(for: id)
        default: media = nil
        }
        if let media { play(media) }
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
        if item.kind == .artist { appState.open(.digArtist(mbid: item.showID, name: item.displayTitle)); return }
        appState.select(.crate)
    }
}

private enum ExploreFilter: String, CaseIterable, Identifiable {
    case all, crate, stations, library
    var id: String { rawValue }
    var label: String { self == .all ? "All signals" : self == .crate ? "Crated" : self == .stations ? "Stations" : "Local library" }
    var color: Color { self == .all ? .black : self == .crate ? MapColor.green : self == .stations ? MapColor.paleGreen : MapColor.blue }
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

private struct ExploreStation: Identifiable {
    let name: String; let city: String; let route: Route; let tags: [String]
    var id: String { name }
    init(_ n: String, _ c: String, _ r: Route, _ t: [String]) { name=n; city=c; route=r; tags=t }
}

private struct MapLabel: View {
    let title: String; let subtitle: String?; let color: Color; let imageURL: URL?; let seed: Int
    /// What the card is allowed to grow to. Sized to its text instead, a long
    /// album title runs straight through whatever is placed beside it — which
    /// no amount of spacing in the layout can avoid, because the layout is
    /// working from a width the card has already exceeded.
    let maxWidth: CGFloat
    let connection: String?
    init(_ t: String, _ s: String?, _ c: Color, _ u: URL?, _ seed: Int, _ maxWidth: CGFloat, connection: String? = nil) {
        title=t; subtitle=s; color=c; imageURL=u; self.seed=seed; self.maxWidth=maxWidth
        self.connection = connection
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let imageURL { ArtworkView(remoteURL: imageURL, side: 42, mark: String(title.prefix(1))).overlay(Rectangle().stroke(.black, lineWidth: 5)) }
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
    let bounds: Anchor<CGRect>
    let legend: Bool
}

private struct ExploreGraphKey: PreferenceKey {
    static var defaultValue: [ExploreGraphNode] { [] }
    static func reduce(value: inout [ExploreGraphNode], nextValue: () -> [ExploreGraphNode]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func graphNode(_ id: String, legend: Bool = false) -> some View {
        anchorPreference(key: ExploreGraphKey.self, value: .bounds) {
            [ExploreGraphNode(id: id, bounds: $0, legend: legend)]
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
            let frames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, geometry[$0.bounds]) })
            // Find the middle gap in the first row rather than using the
            // window midpoint: the map itself has asymmetric outer margins.
            let columns = max(2, min(4, Int(geometry.size.width / 430)))
            let firstRow = frames.values.sorted { $0.midY < $1.midY }
                .prefix(columns).sorted { $0.midX < $1.midX }
            let middle = max(0, (firstRow.count - 1) / 2)
            let centerX: CGFloat
            if firstRow.count > 1 {
                centerX = (firstRow[middle].maxX + firstRow[middle + 1].minX) * 0.5
            } else {
                centerX = firstRow.first?.midX ?? geometry.size.width * 0.5
            }
            let root = CGPoint(x: centerX, y: 44)
            var segments = ExploreGraphSegments()
            var lastJunction = root.y
            var connected = Set<String>()
            for node in nodes {
                guard connected.insert(node.id).inserted,
                      let frame = frames[node.id] else { continue }
                let destination = CGPoint(x: frame.midX,
                                          y: frame.minY - (node.legend ? 26 : 5))
                let entryY = destination.y - 18
                lastJunction = max(lastJunction, entryY)
                // Exactly one top connection per card. No return line from
                // its bottom back into the trunk, which created visual loops.
                segments.add(from: CGPoint(x: centerX, y: entryY),
                             to: CGPoint(x: destination.x, y: entryY))
                segments.add(from: CGPoint(x: destination.x, y: entryY), to: destination)
            }
            segments.add(from: root, to: CGPoint(x: centerX, y: lastJunction))
            // Clip every card and its legend out of the connector layer, so a
            // long branch never draws through artwork, titles, or map labels.
            var visible = Path(CGRect(origin: .zero, size: geometry.size))
            for node in nodes {
                guard var frame = frames[node.id] else { continue }
                if node.legend { frame.origin.y -= 22; frame.size.height += 22 }
                visible.addRect(frame.insetBy(dx: -3, dy: -3))
            }
            context.clip(to: visible, style: FillStyle(eoFill: true))
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
