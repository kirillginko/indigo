//
//  LiveShowReader.swift
//  Indigo
//
//  What a station is broadcasting right now, for any station: each provider
//  publishes it its own way, so this asks whichever one owns the stream.
//
//  `PlayerBarView` and `MiniPlayerView` each still carry their own copy of
//  this switch; the phone's views read this one.
//

import SwiftUI

struct LiveShowReader<Content: View>: View {
    let providerID: String
    let stationID: String
    private let content: (_ now: RadioShow?, _ next: RadioShow?) -> Content

    init(providerID: String, stationID: String, @ViewBuilder content: @escaping (RadioShow?) -> Content) {
        self.providerID = providerID
        self.stationID = stationID
        self.content = { now, _ in content(now) }
    }

    /// The same, with what comes on after as well.
    init(providerID: String, stationID: String, @ViewBuilder nowAndNext: @escaping (RadioShow?, RadioShow?) -> Content) {
        self.providerID = providerID
        self.stationID = stationID
        self.content = nowAndNext
    }

    @Environment(NTSProvider.self) private var nts
    @Environment(KioskProvider.self) private var kiosk
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

    var body: some View { content(show, next) }

    /// What comes on after, where the station publishes it as a show.
    private var next: RadioShow? {
        switch providerID {
        case NTSProvider.providerID: nts.state(for: stationID)?.next
        case KioskProvider.providerID: kiosk.next
        case LotProvider.providerID: lot.next
        default: nil
        }
    }

    private var show: RadioShow? {
        switch providerID {
        case NTSProvider.providerID: nts.state(for: stationID)?.now
        case KioskProvider.providerID: kiosk.now
        case LotProvider.providerID: lot.now
        case DublabProvider.providerID: dublab.now
        case AlharaProvider.providerID: alhara.now(for: stationID)
        case CashmereProvider.providerID: cashmere.now
        case LYLProvider.providerID: lyl.now
        case IdaProvider.providerID: ida.channel(for: stationID).flatMap { ida.now(for: $0) }
        case Radio80000Provider.providerID: radio80000.now
        case PanikProvider.providerID: panik.now
        case RovrProvider.providerID: rovr.now
        case N10ASProvider.providerID: n10as.now
        default: nil
        }
    }
}
