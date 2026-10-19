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

    @Environment(CashmereBrowseStore.self) private var cashmereBrowse
    @Environment(Radio80000BrowseStore.self) private var radio80000Browse
    @Environment(N10ASBrowseStore.self) private var n10asBrowse
    @Environment(LYLBrowseStore.self) private var lylBrowse
    @Environment(PanikBrowseStore.self) private var panikBrowse

    var body: some View {
        content(illustratedShow, next)
            .task(id: show) { await loadArtwork() }
    }

    /// Live metadata often carries only text. Use the same programme's
    /// directory picture, keeping any artwork supplied by the live feed.
    private var illustratedShow: RadioShow? {
        guard let show else { return nil }
        return show.withArtwork(archiveArtwork(for: show))
    }

    private func archiveArtwork(for show: RadioShow) -> URL? {
        switch providerID {
        case CashmereProvider.providerID:
            let match = cashmereBrowse.shows.first {
                $0.slug == show.detailID || RadioShowArtwork.matches($0.name, show.title)
            }
            return match.flatMap { cashmereBrowse.preview(forShow: $0.slug)?.artworkURL }
        case Radio80000Provider.providerID:
            let match = radio80000Browse.shows.first { RadioShowArtwork.matches($0.title, show.title) }
            return match?.imageURL ?? match?.thumbnailURL
        case N10ASProvider.providerID:
            return n10asBrowse.shows.first { N10ASTitle.matchKey($0.title) == N10ASTitle.matchKey(show.title) }?.imageURL
        case LYLProvider.providerID:
            if let slug = show.detailID, let image = lylBrowse.episode(slug: slug)?.imageURL { return image }
            return lylBrowse.shows.first { RadioShowArtwork.matches($0.title, show.title) }?.imageURL
        case PanikProvider.providerID:
            if let slug = show.detailID, let image = panikBrowse.show(slug: slug)?.imageURL { return image }
            return panikBrowse.shows.first { RadioShowArtwork.matches($0.title, show.title) }?.imageURL
        default:
            return nil
        }
    }

    private func loadArtwork() async {
        guard let show, show.artworkURL == nil else { return }
        switch providerID {
        case CashmereProvider.providerID:
            await cashmereBrowse.loadShowsIfNeeded()
            if let match = cashmereBrowse.shows.first(where: {
                $0.slug == show.detailID || RadioShowArtwork.matches($0.name, show.title)
            }) {
                await cashmereBrowse.loadShowPreviewIfNeeded(slug: match.slug)
            }
        case Radio80000Provider.providerID:
            await radio80000Browse.loadShowsIfNeeded()
        case N10ASProvider.providerID:
            await n10asBrowse.loadShowsIfNeeded()
        case LYLProvider.providerID:
            if let slug = show.detailID { await lylBrowse.loadDetailIfNeeded(slug: slug) }
            if archiveArtwork(for: show) == nil { await lylBrowse.loadShowsIfNeeded() }
        case PanikProvider.providerID:
            await panikBrowse.loadShowsIfNeeded()
        default:
            break
        }
    }

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

/// Exact programme names only: a loosely related archive hit is not evidence
/// that its photograph belongs to what is on air.
nonisolated enum RadioShowArtwork {
    static func matches(_ candidate: String, _ title: String) -> Bool {
        let key = RecordingKey.normalize(title)
        return !key.isEmpty && RecordingKey.normalize(candidate) == key
    }
}

extension RadioShow {
    func withArtwork(_ fallback: URL?) -> RadioShow {
        RadioShow(title: title, host: host, summary: summary, location: location,
                  genres: genres, moods: moods, artworkURL: artworkURL ?? fallback,
                  startsAt: startsAt, endsAt: endsAt, detailID: detailID)
    }
}
