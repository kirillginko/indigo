//
//  StationDirectory.swift
//  Indigo
//
//  Every station, in the order the phone shows them, with where it is and
//  which page it opens. The order is curated, not most-played: a deliberate
//  sequence reads as designed. Each provider's channels come in its own order.
//

import SwiftUI

struct StationEntry: Identifiable, Hashable {
    let station: RadioStation
    let location: String
    let route: Route
    var id: String { station.id }
}

/// Builds the directory from the providers in the environment.
struct StationDirectory<Content: View>: View {
    @ViewBuilder let content: ([StationEntry]) -> Content

    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
    @Environment(NoodsProvider.self) private var noods
    @Environment(LotProvider.self) private var lot
    @Environment(DublabProvider.self) private var dublab
    @Environment(AlharaProvider.self) private var alhara
    @Environment(CashmereProvider.self) private var cashmere
    @Environment(LYLProvider.self) private var lyl
    @Environment(IdaProvider.self) private var ida
    @Environment(Radio80000Provider.self) private var radio80000
    @Environment(PanikProvider.self) private var panik
    @Environment(RovrProvider.self) private var rovr
    @Environment(N10ASProvider.self) private var n10as

    var body: some View { content(entries) }

    private var entries: [StationEntry] {
        func each(_ stations: [RadioStation], _ location: String, _ route: (RadioStation) -> Route) -> [StationEntry] {
            stations.map { StationEntry(station: $0, location: location, route: route($0)) }
        }
        return each(nts.stations, "London, UK") { .station($0.id) }
            + each(kiosk.stations, "Brussels, Belgium") { _ in .kioskStation }
            + each(noods.stations, "Bristol, UK") { _ in .noodsStation }
            + each(lot.stations, "Brooklyn, New York") { _ in .lotStation }
            + each(dublab.stations, "Los Angeles, USA") { _ in .dublabStation }
            + each(alhara.visibleStations, "Bethlehem, Palestine") { .alharaStation($0.id) }
            + each(cashmere.stations, "Berlin, Germany") { _ in .cashmereStation }
            + each(lyl.stations, "Lyon, France") { _ in .lylStation }
            + each(ida.stations, "Tallinn, Estonia") { .idaStation($0.id) }
            + each(radio80000.stations, "Munich, Germany") { _ in .radio80000Station }
            + each(panik.stations, "Brussels, Belgium") { _ in .panikStation }
            + each(rovr.stations, rovr.offsetLabel) { .rovrStation($0.id) }
            + each(n10as.stations, "Montréal, Canada") { _ in .n10asStation }
    }
}

/// Where each station's shows live, and the archives, for the phone's Shows tab.
enum ShowsDirectory {
    struct Entry: Identifiable, Hashable {
        let station: String
        let label: String
        let route: Route
        var id: Route { route }
    }

    static let entries: [Entry] = [
        Entry(station: "NTS", label: "Shows", route: .ntsShows),
        Entry(station: "NTS", label: "Mixtapes", route: .ntsMixtapes),
        Entry(station: "Kiosk Radio", label: "Shows", route: .kioskShows),
        Entry(station: "Noods Radio", label: "Residents", route: .noodsResidents),
        Entry(station: "The Lot Radio", label: "Shows", route: .lotShows),
        Entry(station: "dublab", label: "DJs", route: .dublabDJs),
        Entry(station: "Radio alHara", label: "Archive", route: .alharaArchive),
        Entry(station: "Cashmere Radio", label: "Shows", route: .cashmereShows),
        Entry(station: "LYL Radio", label: "Shows", route: .lylShows),
        Entry(station: "IDA Radio", label: "Shows", route: .idaShows),
        Entry(station: "Radio 80000", label: "Shows", route: .radio80000Shows),
        Entry(station: "Radio Panik", label: "Shows", route: .panikShows),
        Entry(station: "ROVR", label: "Shows", route: .rovrShows),
        Entry(station: "n10.as", label: "Shows", route: .n10asShows),
        Entry(station: "Archives", label: "YouTube channels", route: .youtubeChannels)
    ]
}
