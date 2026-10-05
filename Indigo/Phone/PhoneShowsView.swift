//
//  PhoneShowsView.swift
//  Indigo
//
//  The phone's Shows tab, in two steps: first every station as a row -- its
//  mark, its name, how many shows it has -- and, picking one, that station's
//  shows as a grid of square cards, as IDA's app sets out its own. A card
//  opens the show's page; back from it is the grid, and back from the grid
//  the list. The station picked is kept, so the tab comes back to it.
//
//  Each station keeps its own list of shows; this only reads them, and asks
//  for a station's when it is picked (counts fill in as lists arrive). NTS
//  pages its 1,700 shows, so its grid asks for more as its end comes into
//  view.
//

import SwiftUI

/// One show, as the grid draws it.
struct PhoneShowCard: Identifiable {
    let id: String
    let title: String
    let station: String
    let imageURL: URL?
    let markURL: URL?
    let page: DetailPage
}

struct PhoneShowsView: View {
    @Environment(AppState.self) private var appState
    @Environment(YouTubeChannelStore.self) private var archives
    @Environment(NTSBrowseStore.self) private var nts
    @Environment(LotBrowseStore.self) private var lot
    @Environment(IdaBrowseStore.self) private var ida
    @Environment(LYLBrowseStore.self) private var lyl
    @Environment(Radio80000BrowseStore.self) private var radio80000
    @Environment(PanikBrowseStore.self) private var panik
    @Environment(RovrBrowseStore.self) private var rovr
    @Environment(N10ASBrowseStore.self) private var n10as
    @Environment(DublabBrowseStore.self) private var dublab
    @Environment(CashmereBrowseStore.self) private var cashmere
    @State private var feeds = PhoneFeeds.shared

    struct Station: Identifiable {
        /// The key the grid is chosen by.
        let id: String
        let name: String
        let providerID: String?
    }

    /// In the list's order: the archives first, as on For You.
    static let stations = [
        Station(id: "Archives", name: "Archives", providerID: nil),
        Station(id: "NTS", name: "NTS", providerID: NTSProvider.providerID),
        Station(id: "IDA", name: "IDA Radio", providerID: IdaProvider.providerID),
        Station(id: "The Lot", name: "The Lot Radio", providerID: LotProvider.providerID),
        Station(id: "LYL", name: "LYL Radio", providerID: LYLProvider.providerID),
        Station(id: "80000", name: "Radio 80000", providerID: Radio80000Provider.providerID),
        Station(id: "Panik", name: "Radio Panik", providerID: PanikProvider.providerID),
        Station(id: "ROVR", name: "ROVR", providerID: RovrProvider.providerID),
        Station(id: "n10.as", name: "n10.as", providerID: N10ASProvider.providerID),
        Station(id: "dublab", name: "dublab", providerID: DublabProvider.providerID),
        Station(id: "Cashmere", name: "Cashmere Radio", providerID: CashmereProvider.providerID)
    ]

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        if let station = Self.stations.first(where: { $0.id == feeds.showsStation }) {
            grid(station)
        } else {
            list
        }
    }

    // MARK: The stations

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                PhonePageTitle("Shows")
                ForEach(Self.stations) { station in
                    stationRow(station)
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// The station's mark; its name and how many shows, in boxes, touching.
    private func stationRow(_ station: Station) -> some View {
        Button { feeds.showsStation = station.id } label: {
            HStack(spacing: 12) {
                Group {
                    if let providerID = station.providerID {
                        ArtworkView(side: 64, glyphScale: 0.3, markURL: StationMark.logoURL(for: providerID))
                    } else {
                        MineralSheenSurface()
                    }
                }
                .frame(width: 64, height: 64)
                .clipped()
                VStack(alignment: .leading, spacing: 0) {
                    Chip(text: station.name, size: 14)
                    let count = cards(of: station.id).count
                    if count > 0 {
                        Chip(text: "\(count)\(hasMore(station.id) ? "+" : "") \(station.id == "dublab" ? "DJs" : "shows")",
                             tone: .lead, size: 11, uppercase: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.trailing, 16)
            }
            .background(PhoneShowPage.rowGround)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.name) shows")
        .task { await load(station.id) }
    }

    // MARK: A station's shows

    private func grid(_ station: Station) -> some View {
        let shown = cards(of: station.id)
        return ScrollView {
            VStack(spacing: 0) {
                gridHeader(station)
                if shown.isEmpty {
                    Text(isLoading(station.id) ? "Loading shows…" : "No shows yet.")
                        .font(Typeface.mono(12))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(shown) { card($0) }
                    }
                    if station.id == "NTS", nts.shows.hasMore {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .task(id: nts.shows.items.count) { await nts.loadMoreShows() }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: station.id) { await load(station.id) }
    }

    /// Back to the stations, and the station's name.
    private func gridHeader(_ station: Station) -> some View {
        HStack(spacing: 12) {
            Button { feeds.showsStation = nil } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All stations")
            Text(station.name)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: 46, height: 46)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: The cards

    /// A square picture, the show's name in a box along the bottom.
    private func card(_ card: PhoneShowCard) -> some View {
        Button { appState.open(card.page) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ArtworkView(remoteURL: card.imageURL, side: proxy.size.width, glyphScale: 0.3,
                                    markURL: card.markURL)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Chip(text: card.title, size: 12)
                        .lineLimit(2)
                        .padding(8)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title), \(card.station)")
    }

    // MARK: The shows

    private func cards(of station: String) -> [PhoneShowCard] {
        switch station {
        case "Archives":
            return archives.channels.map {
                PhoneShowCard(id: "yt.\($0.id)", title: $0.title ?? "Archive", station: "Archive",
                              imageURL: $0.imageURL.flatMap(URL.init(string:)), markURL: nil,
                              page: .youtubeChannel(id: $0.id))
            }
        case "NTS":
            return nts.shows.items.map {
                PhoneShowCard(id: "nts.\($0.alias)", title: $0.name, station: "NTS", imageURL: $0.artworkURL,
                              markURL: mark(NTSProvider.providerID), page: .ntsShow(alias: $0.alias))
            }
        case "IDA":
            return ida.shows.map {
                PhoneShowCard(id: "ida.\($0.slug)", title: $0.title, station: "IDA", imageURL: $0.imageURL,
                              markURL: mark(IdaProvider.providerID), page: .idaShow(slug: $0.slug))
            }
        case "The Lot":
            return lot.shows.map {
                PhoneShowCard(id: "lot.\($0.slug)", title: $0.name, station: "The Lot", imageURL: $0.photoURL,
                              markURL: mark(LotProvider.providerID), page: .lotShow(slug: $0.slug))
            }
        case "LYL":
            return lyl.shows.map {
                PhoneShowCard(id: "lyl.\($0.slug)", title: $0.title, station: "LYL", imageURL: $0.imageURL,
                              markURL: mark(LYLProvider.providerID), page: .lylShow(slug: $0.slug))
            }
        case "80000":
            return radio80000.shows.map {
                PhoneShowCard(id: "80000.\($0.slug)", title: $0.title, station: "80000",
                              imageURL: $0.thumbnailURL ?? $0.imageURL,
                              markURL: mark(Radio80000Provider.providerID), page: .radio80000Show(slug: $0.slug))
            }
        case "Panik":
            return panik.shows.map {
                PhoneShowCard(id: "panik.\($0.slug)", title: $0.title, station: "Panik", imageURL: $0.imageURL,
                              markURL: mark(PanikProvider.providerID), page: .panikShow(slug: $0.slug))
            }
        case "ROVR":
            return rovr.shows.map {
                PhoneShowCard(id: "rovr.\($0.documentID)", title: $0.title, station: "ROVR",
                              imageURL: $0.thumbnailURL ?? $0.imageURL,
                              markURL: mark(RovrProvider.providerID), page: .rovrShow(id: $0.documentID))
            }
        case "n10.as":
            return n10as.shows.map {
                PhoneShowCard(id: "n10as.\($0.slug)", title: $0.title, station: "n10.as", imageURL: $0.imageURL,
                              markURL: mark(N10ASProvider.providerID), page: .n10asShow(slug: $0.slug))
            }
        case "dublab":
            return dublab.djs.map {
                PhoneShowCard(id: "dublab.\($0.slug)", title: $0.name, station: "dublab", imageURL: $0.artworkURL,
                              markURL: mark(DublabProvider.providerID), page: .dublabDJ(slug: $0.slug))
            }
        case "Cashmere":
            // Cashmere publishes no picture for a show: its mark stands in.
            return cashmere.shows.map {
                PhoneShowCard(id: "cashmere.\($0.slug)", title: $0.name, station: "Cashmere", imageURL: nil,
                              markURL: mark(CashmereProvider.providerID), page: .cashmereShow(slug: $0.slug))
            }
        default:
            return []
        }
    }

    private func mark(_ providerID: String) -> URL? { StationMark.logoURL(for: providerID) }

    private func isLoading(_ station: String?) -> Bool {
        switch station {
        case "Archives": archives.channelsPhase.isLoading
        case "NTS": nts.shows.isLoading
        case "IDA": ida.showsPhase.isLoading
        case "The Lot": lot.showsPhase.isLoading
        case "LYL": lyl.showsPhase.isLoading
        case "80000": radio80000.showsPhase.isLoading
        case "Panik": panik.showsPhase.isLoading
        case "ROVR": rovr.showsPhase.isLoading
        case "n10.as": n10as.showsPhase.isLoading
        case "Cashmere": cashmere.showsPhase.isLoading
        default: true
        }
    }

    /// Whether the station has more shows than it has sent so far.
    private func hasMore(_ station: String) -> Bool {
        station == "NTS" && nts.shows.hasMore
    }

    /// The station's list, once.
    private func load(_ station: String) async {
        switch station {
        case "Archives": await archives.loadChannelsIfNeeded()
        case "NTS": await nts.loadShowsIfNeeded()
        case "IDA": await ida.loadShowsIfNeeded()
        case "The Lot": await lot.loadShowsIfNeeded()
        case "LYL": await lyl.loadShowsIfNeeded()
        case "80000": await radio80000.loadShowsIfNeeded()
        case "Panik": await panik.loadShowsIfNeeded()
        case "ROVR": await rovr.loadShowsIfNeeded()
        case "n10.as": await n10as.loadShowsIfNeeded()
        case "dublab": await dublab.loadDJsIfNeeded()
        case "Cashmere": await cashmere.loadShowsIfNeeded()
        default: break
        }
    }
}
