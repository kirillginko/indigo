//
//  MusicProvider.swift
//  Indigo
//
//  The seam every future source plugs into — Bandcamp, SoundCloud, archived
//  shows. Views and the player only ever see these shapes, never a provider's
//  own DTOs.
//

import Foundation

/// Providers are UI-facing objects and live on the main actor; the value
/// types they vend are the Sendable part.
protocol MusicProvider {
    static var providerID: String { get }
    var displayName: String { get }
}

nonisolated struct RadioStation: Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    /// "NTS 1"
    let name: String
    /// "1" — used for dense chrome like the sidebar.
    let shortName: String
    let strapline: String
    let streamURL: URL
}

nonisolated struct RadioShow: Hashable, Sendable {
    let title: String
    let host: String?
    let summary: String?
    let location: String?
    let genres: [String]
    let moods: [String]
    let artworkURL: URL?
    let startsAt: Date?
    let endsAt: Date?
    /// Opaque, provider-defined handle for this broadcast's detail page, so a
    /// station view can offer "see the tracklist" without the shared model
    /// knowing what an NTS episode alias is.
    let detailID: String?

    /// "18:00 – 20:00" in the listener's local time.
    var slot: String? {
        guard let startsAt, let endsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    /// 0…1 through the broadcast, for the on-air progress hairline.
    func elapsedFraction(at date: Date = .now) -> Double? {
        guard let startsAt, let endsAt, endsAt > startsAt else { return nil }
        let total = endsAt.timeIntervalSince(startsAt)
        let done = date.timeIntervalSince(startsAt)
        return min(1, max(0, done / total))
    }
}

nonisolated struct RadioStationState: Identifiable, Sendable {
    let station: RadioStation
    var now: RadioShow?
    var next: RadioShow?
    var id: String { station.id }
}

protocol RadioProvider: MusicProvider {
    var stations: [RadioStation] { get }
}
