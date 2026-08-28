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

    static func label(for providerID: String) -> String {
        switch providerID {
        case NTSProvider.providerID: "NTS"
        case KioskProvider.providerID: "Kiosk"
        case NoodsProvider.providerID: "Noods"
        case LotProvider.providerID: "The Lot"
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
