//
//  AirtimeLiveInfo.swift
//  Indigo
//
//  Airtime is the station software a good share of community radio runs on,
//  and it publishes the same `live-info-v2` document wherever it is installed:
//  what show is on the air, what file is playing inside it, and what is next.
//
//  dublab and Cashmere both broadcast through it, so the shape lives here
//  rather than in whichever provider happened to need it first.
//

import Foundation

nonisolated struct AirtimeLiveInfoDTO: Decodable, Sendable {
    let station: Station?
    let tracks: Slot<Track>?
    let shows: Slot<Show>?

    nonisolated struct Station: Decodable, Sendable {
        /// "Europe/Berlin". Every time in this payload is local to it and
        /// carries no offset of its own.
        let timezone: String?
        let schedulerTime: String?
    }

    /// `previous` and `next` are an object when there is one and an array when
    /// there are several — or none.
    nonisolated struct Slot<Item: Decodable & Sendable>: Decodable, Sendable {
        let current: Item?
        let next: [Item]
        let previous: [Item]

        private enum CodingKeys: String, CodingKey { case current, next, previous }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            current = try? container.decodeIfPresent(Item.self, forKey: .current)
            next = Self.list(container, .next)
            previous = Self.list(container, .previous)
        }

        private static func list(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> [Item] {
            if let many = try? container.decodeIfPresent([Item].self, forKey: key) { return many }
            if let one = try? container.decodeIfPresent(Item.self, forKey: key) { return [one] }
            return []
        }
    }

    nonisolated struct Show: Decodable, Sendable {
        let name: String?
        let description: String?
        let genre: String?
        /// Some stations point this at the show's page on their own site.
        let url: String?
        let image_path: String?
        let starts: String?
        let ends: String?
    }

    nonisolated struct Track: Decodable, Sendable {
        let name: String?
        let starts: String?
        let ends: String?
        let metadata: Metadata?

        nonisolated struct Metadata: Decodable, Sendable {
            let track_title: String?
            let artist_name: String?
            let length: String?
        }
    }

    /// The station's own wall clock, which everything in the payload is local
    /// to. Without it the times are simply the wrong times.
    func timeZone(default fallback: String) -> TimeZone {
        station?.timezone.flatMap { TimeZone(identifier: $0) }
            ?? TimeZone(identifier: fallback)
            ?? .current
    }
}

nonisolated enum AirtimeTimestamp {
    /// Airtime writes "2026-08-29 12:00:00" in the station's own zone, with no
    /// offset attached — and sometimes with microseconds.
    static func parse(_ value: String?, zone: TimeZone) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
