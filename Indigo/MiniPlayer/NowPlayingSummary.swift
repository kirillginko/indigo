//
//  NowPlayingSummary.swift
//  Indigo
//
//  Resolves "what is playing" into the lines and chips both the player bar and
//  the mini player render. Written once so the two windows can never disagree
//  about what the listener is hearing.
//

import Foundation
import SwiftData

struct NowPlayingSummary {
    /// "NTS/1", "KIOSK", "LOCAL".
    let source: String
    let status: [StatusItem]
    /// The big line — artist for a track, show for a broadcast.
    let primary: String
    /// The line under it — title for a track, station for a broadcast.
    let secondary: String?
    /// The canonical recording behind this, when one already exists. Not
    /// created here: rendering a bar must never write to the store.
    let recording: Recording?
    let isLive: Bool

    static let empty = NowPlayingSummary(
        source: "Indigo", status: [], primary: "Nothing playing",
        secondary: "Pick a track or a station", recording: nil, isLive: false
    )

    /// `showTitle` is what the station is currently broadcasting, which the
    /// caller knows and the MediaItem doesn't.
    static func make(
        item: MediaItem?,
        showTitle: String?,
        context: ModelContext
    ) -> NowPlayingSummary {
        guard let item else { return .empty }

        let recording = existingRecording(for: item, context: context)

        if item.isLive {
            return NowPlayingSummary(
                source: sourceLabel(for: item),
                status: [StatusItem("Live", .live)],
                primary: showTitle ?? item.title,
                secondary: showTitle == nil ? item.subtitle : item.title,
                recording: recording,
                isLive: true
            )
        }

        if item.isEmbedded {
            var status: [StatusItem] = []
            if let provider = item.embedProvider {
                status.append(StatusItem(provider.displayName))
            }
            status.append(contentsOf: identityChips(recording))
            return NowPlayingSummary(
                source: sourceLabel(for: item),
                status: status,
                primary: item.title,
                secondary: item.subtitle,
                recording: recording,
                isLive: false
            )
        }

        // A local file: the format is the interesting technical fact.
        var status = AudioFormatProbe.shared.chips(forPath: item.id)
        status.append(contentsOf: identityChips(recording))
        return NowPlayingSummary(
            source: "Local",
            status: status,
            primary: item.subtitle ?? item.title,
            secondary: item.subtitle == nil ? nil : item.title,
            recording: recording,
            isLive: false
        )
    }

    /// MATCH / PROBABLE / UNKNOWN — shown only once something has actually
    /// claimed an identity, so an un-run identification reads as silence
    /// rather than as a failure.
    private static func identityChips(_ recording: Recording?) -> [StatusItem] {
        guard let recording else { return [] }
        switch recording.identificationStatus {
        case .identified: return [StatusItem("Match ✓", .affirmed)]
        case .probable: return [StatusItem("Probable", .pending)]
        case .unknown: return [StatusItem("Unknown", .pending)]
        }
    }

    static func sourceLabel(for item: MediaItem) -> String {
        switch item.sourceID {
        case NTSProvider.providerID:
            // "NTS/1" for a station, plain "NTS" for anything archived.
            if item.kind == .radioStation, let channel = item.id.split(separator: ".").last,
               channel.count <= 2 {
                return "NTS/\(channel)"
            }
            return "NTS"
        case KioskProvider.providerID: return "Kiosk"
        case NoodsProvider.providerID: return "Noods"
        case LotProvider.providerID: return "The Lot"
        case DublabProvider.providerID: return "dublab"
        case AlharaProvider.providerID: return "alHara"
        case CashmereProvider.providerID: return "Cashmere"
        case LYLProvider.providerID: return "LYL"
        case Track.sourceID: return "Local"
        default: return item.sourceID.uppercased()
        }
    }

    /// Look-up only. The crate and DIG actions create a recording when the
    /// listener asks for one; a bar redraw must not.
    private static func existingRecording(for item: MediaItem, context: ModelContext) -> Recording? {
        guard item.kind == .track else { return nil }
        let path = item.id
        var descriptor = FetchDescriptor<RecordingSource>(
            predicate: #Predicate { $0.identifier == path }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recording
    }
}
