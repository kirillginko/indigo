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
    @ViewBuilder let content: (RadioShow?) -> Content

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

    var body: some View { content(show) }

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
