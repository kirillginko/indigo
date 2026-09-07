//
//  BroadcastSource.swift
//  Indigo
//
//  Music heard inside a broadcast. Often the recording has no address of its
//  own — it exists, for you, as forty seconds inside somebody's set — so the
//  honest source is that show, opened at the right moment.
//
//  Named for the concept rather than for NTS: Kiosk shows resolve through the
//  identical path, and a provider-named type would have needed a twin the day
//  the second station landed.
//

import Foundation
import SwiftData

nonisolated struct BroadcastSource {
    let context: ModelContext

    func sources(for recording: Recording) -> [AudioSource] {
        var found: [AudioSource] = []
        var seen = Set<String>()

        // A linked source can carry a direct playback URL (Kiosk shows do,
        // because the crate captured one). Those can play without navigating.
        for link in recording.sources where link.kind == .broadcastAppearance {
            guard let provider = link.providerID else { continue }
            guard let page = Self.destination(showID: link.identifier, providerID: provider) else { continue }
            let source = AudioSource(
                kind: .broadcastAppearance,
                action: .openBroadcast(page, offsetSeconds: link.offsetSeconds),
                label: Self.label(for: provider),
                detail: Self.offsetDetail(link.offsetSeconds),
                rank: 10
            )
            if seen.insert(source.id).inserted { found.append(source) }
        }

        // Anything the recording was heard in is also a way to hear it again.
        for appearance in recording.appearances.sorted(by: { $0.heardAt > $1.heardAt }) {
            guard let showID = appearance.showID,
                  let page = Self.destination(showID: showID, providerID: appearance.providerID)
            else { continue }
            let source = AudioSource(
                kind: .broadcastAppearance,
                action: .openBroadcast(page, offsetSeconds: appearance.offsetSeconds),
                label: Self.label(for: appearance.providerID),
                detail: appearance.showTitle.map { title in
                    appearance.offsetLabel.map { "\(title) @ \($0)" } ?? title
                } ?? Self.offsetDetail(appearance.offsetSeconds),
                rank: 11
            )
            if seen.insert(source.id).inserted { found.append(source) }
        }
        return found
    }

    // MARK: - Mapping

    /// Turns a provider-defined broadcast handle back into somewhere the app
    /// can navigate. NTS files episodes under "show/episode"; Kiosk uses a
    /// single slug.
    static func destination(showID: String, providerID: String) -> DetailPage? {
        // A show is not one of its broadcasts. Panik and Cashmere name the
        // show that is on air rather than the episode, and the crate files
        // those under a noun of their own.
        if let slug = strip(showID, providerID: providerID, noun: "show"),
           let page = showDestination(slug: slug, providerID: providerID) {
            return page
        }
        // Anything else wearing this provider's prefix is not a broadcast id.
        //
        // The branches below fall back to the whole `showID` when it carries
        // no prefix, because a bare slug is what `MediaAppearance` files. That
        // is right for a slug and wrong for an id that names something else:
        // a row kept while a station was on air holds `radio80000.live`, and
        // handing that to the episode branch built `.radio80000Episode(id:
        // "radio80000.live")` — a page that could only ever say the broadcast
        // was unavailable, because no such broadcast was ever named.
        if showID.hasPrefix("\(providerID)."),
           strip(showID, providerID: providerID, noun: "episode") == nil,
           strip(showID, providerID: providerID, noun: "broadcast") == nil {
            return nil
        }
        switch providerID {
        case NTSProvider.providerID:
            guard let ref = NTSEpisodeRef.decode(showID) else {
                return showID.isEmpty ? nil : .ntsShow(alias: showID)
            }
            return .ntsEpisode(show: ref.show, episode: ref.episode)
        case KioskProvider.providerID:
            // Kiosk publishes no per-show page; its shows live in the archive
            // grid, so there is nothing to navigate to yet.
            return nil
        case LYLProvider.providerID:
            let slug = showID.hasPrefix("lyl.episode.")
                ? String(showID.dropFirst("lyl.episode.".count))
                : showID
            return slug.isEmpty ? nil : .lylEpisode(slug: slug)
        case CashmereProvider.providerID:
            let slug = showID.hasPrefix("cashmere.episode.")
                ? String(showID.dropFirst("cashmere.episode.".count))
                : showID
            return slug.isEmpty ? nil : .cashmereEpisode(slug: slug)
        case AlharaProvider.providerID:
            let slug = showID.hasPrefix("alhara.show.")
                ? String(showID.dropFirst("alhara.show.".count))
                : showID
            return slug.isEmpty ? nil : .alharaShow(slug: slug)
        case DublabProvider.providerID:
            let slug = showID.hasPrefix("dublab.broadcast.")
                ? String(showID.dropFirst("dublab.broadcast.".count))
                : showID
            return slug.isEmpty ? nil : .dublabBroadcast(slug: slug)
        case IdaProvider.providerID:
            let slug = showID.hasPrefix("ida.episode.")
                ? String(showID.dropFirst("ida.episode.".count))
                : showID
            return slug.isEmpty ? nil : .idaEpisode(slug: slug)
        case Radio80000Provider.providerID:
            let id = showID.hasPrefix("radio80000.episode.")
                ? String(showID.dropFirst("radio80000.episode.".count))
                : showID
            return id.isEmpty ? nil : .radio80000Episode(id: id)
        case PanikProvider.providerID:
            let id = showID.hasPrefix("panik.episode.")
                ? String(showID.dropFirst("panik.episode.".count))
                : showID
            return id.isEmpty ? nil : .panikEpisode(id: id)
        case RovrProvider.providerID:
            let id = showID.hasPrefix("rovr.broadcast.")
                ? String(showID.dropFirst("rovr.broadcast.".count))
                : showID
            return id.isEmpty ? nil : .rovrBroadcast(id: id)
        case LotProvider.providerID:
            let identity = showID.hasPrefix("lot.episode.")
                ? String(showID.dropFirst("lot.episode.".count))
                : showID
            guard let ref = LotEpisodeRef.decode(identity) else { return nil }
            return .lotEpisode(show: ref.show, episode: ref.episode)
        default:
            return nil
        }
    }

    /// The `<provider>.<noun>.` prefix removed, or nil when it is not there.
    private static func strip(_ showID: String, providerID: String, noun: String) -> String? {
        let prefix = "\(providerID).\(noun)."
        guard showID.hasPrefix(prefix) else { return nil }
        let bare = String(showID.dropFirst(prefix.count))
        return bare.isEmpty ? nil : bare
    }

    /// A show's own page, for the stations that publish one.
    private static func showDestination(slug: String, providerID: String) -> DetailPage? {
        switch providerID {
        case NTSProvider.providerID: .ntsShow(alias: slug)
        case NoodsProvider.providerID: .noodsShow(path: "shows/\(slug)")
        case LotProvider.providerID: .lotShow(slug: slug)
        case AlharaProvider.providerID: .alharaShow(slug: slug)
        case CashmereProvider.providerID: .cashmereShow(slug: slug)
        case LYLProvider.providerID: .lylShow(slug: slug)
        case IdaProvider.providerID: .idaShow(slug: slug)
        case Radio80000Provider.providerID: .radio80000Show(slug: slug)
        case PanikProvider.providerID: .panikShow(slug: slug)
        case RovrProvider.providerID: .rovrShow(id: slug)
        // Kiosk and dublab publish no per-show page.
        default: nil
        }
    }

    /// Where a station keeps what it has broadcast.
    ///
    /// The fallback for a show that is known by name and nothing else — a
    /// row kept while a station was on air, or one kept before its station's
    /// live feed was read for what was playing. Not the broadcast, but the
    /// right neighbourhood, and often the only honest answer: a show taken
    /// off the air is frequently not posted for days.
    static func showsRoute(for providerID: String?) -> Route? {
        switch providerID {
        case NTSProvider.providerID: .ntsShows
        case KioskProvider.providerID: .kioskShows
        case NoodsProvider.providerID: .noodsShows
        case LotProvider.providerID: .lotShows
        case DublabProvider.providerID: .dublabArchive
        case AlharaProvider.providerID: .alharaArchive
        case CashmereProvider.providerID: .cashmereShows
        case LYLProvider.providerID: .lylShows
        case IdaProvider.providerID: .idaShows
        case Radio80000Provider.providerID: .radio80000Shows
        case PanikProvider.providerID: .panikShows
        case RovrProvider.providerID: .rovrShows
        default: nil
        }
    }

    /// One spelling for a broadcast, whoever is doing the spelling.    /// One spelling for a broadcast, whoever is doing the spelling.
    ///
    /// The same LYL show arrives as `lyl.episode.glass-2026-07-16` from the
    /// crate, which files a broadcast under the id its player used, and as
    /// `glass-2026-07-16` from `MediaAppearance`, which files it under the id
    /// the tracklist used. Two spellings mean two nodes, and the consequence
    /// showed up as EXPLORE offering somebody a show already sitting in their
    /// crate — the exact failure that block exists to avoid.
    ///
    /// Stripped rather than added, because the bare form is what every
    /// `destination` branch below already reduces to.
    static func canonicalShowID(_ showID: String, providerID: String) -> String {
        for noun in ["episode", "show", "broadcast"] {
            let prefix = "\(providerID).\(noun)."
            guard showID.hasPrefix(prefix) else { continue }
            let bare = String(showID.dropFirst(prefix.count))
            return bare.isEmpty ? showID : bare
        }
        return showID
    }

    /// The section of the app a station lives in.
    ///
    /// The same table `NowPlayingLink` uses to send the player bar back to
    /// whatever is streaming, reached here from a provider id rather than
    /// from a `MediaItem` — a remembered encounter has the id and not the
    /// item. `stationID` names the channel for the stations that run more
    /// than one, and is ignored by the rest.
    static func route(providerID: String, stationID: String? = nil) -> Route? {
        switch providerID {
        // NTS files each channel under its own id. Without one there is no
        // honest default, so the listener lands on the shows instead of on a
        // channel nobody chose.
        case NTSProvider.providerID: stationID.map { .station($0) } ?? .ntsShows
        case KioskProvider.providerID: .kioskStation
        case NoodsProvider.providerID: .noodsStation
        case LotProvider.providerID: .lotStation
        case DublabProvider.providerID: .dublabStation
        case AlharaProvider.providerID: stationID.map { .alharaStation($0) } ?? .alharaArchive
        case CashmereProvider.providerID: .cashmereStation
        case LYLProvider.providerID: .lylStation
        case IdaProvider.providerID: stationID.map { .idaStation($0) } ?? .idaShows
        case Radio80000Provider.providerID: .radio80000Station
        case PanikProvider.providerID: .panikStation
        case RovrProvider.providerID: stationID.map { .rovrStation($0) } ?? .rovrShows
        case Track.sourceID: .tracks
        default: nil
        }
    }

    static func label(for providerID: String) -> String {
        switch providerID {
        case NTSProvider.providerID: "NTS"
        case KioskProvider.providerID: "Kiosk"
        case NoodsProvider.providerID: "Noods"
        case LotProvider.providerID: "The Lot"
        case DublabProvider.providerID: "dublab"
        case AlharaProvider.providerID: "alHara"
        case CashmereProvider.providerID: "Cashmere"
        case LYLProvider.providerID: "LYL"
        case IdaProvider.providerID: "IDA"
        case Radio80000Provider.providerID: "Radio 80000"
        case PanikProvider.providerID: "Radio Panik"
        case RovrProvider.providerID: "ROVR"
        case Track.sourceID: "Local"
        default: providerID.capitalized
        }
    }

    private static func offsetDetail(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "@ %02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// A station's own logo, for when there is no picture of what is actually on.
///
/// Kept in one place next to `BroadcastSource.label(for:)` because the same
/// question — "which station is this?" — is asked by the player bar, the
/// browse grids and the now-playing summary, and three copies of the answer
/// is how one of them ends up out of date.
nonisolated enum StationMark {
    static func logoURL(for providerID: String?) -> URL? {
        switch providerID {
        case AlharaProvider.providerID: AlharaProvider.logoURL
        case DublabProvider.providerID: DublabProvider.logoURL
        case LYLProvider.providerID: LYLProvider.logoURL
        case CashmereProvider.providerID: CashmereProvider.logoURL
        case IdaProvider.providerID: IdaProvider.logoURL
        case Radio80000Provider.providerID: Radio80000Provider.logoURL
        case PanikProvider.providerID: PanikProvider.logoURL
        case RovrProvider.providerID: RovrProvider.logoURL
        default: nil
        }
    }

    /// The station's name, for the last-resort text mark.
    static func name(for providerID: String?) -> String? {
        guard let providerID, logoURL(for: providerID) != nil else { return nil }
        return BroadcastSource.label(for: providerID)
    }
}
