//
//  AirtimeLiveInfo.swift
//  Indigo
//
//  Airtime is the station software a good share of community radio runs on,
//  and it publishes the same `live-info-v2` document wherever it is installed:
//  what show is on the air, what file is playing inside it, and what is next.
//
//  dublab, Cashmere and Radio 80000 all broadcast through it, so the shapes
//  live here rather than in whichever provider happened to need them first.
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

/// Airtime's published calendar: this week and the next, as one object keyed
/// by weekday name — "monday" … "sunday", then "nextmonday" … "nextsunday".
///
/// It is the same document on every Airtime install, and it is a good deal
/// more than `live-info`'s "what is on next": a fortnight of slots, which is
/// what makes a schedule a listener can plan around. Stations that publish a
/// calendar of their own on their own site are better read there — dublab
/// does — but for a station whose schedule only exists inside Airtime, this
/// is it.
nonisolated struct AirtimeWeekInfoDTO: Decodable, Sendable {
    /// Weekday key → that day's slots, in the order Airtime lists them.
    let days: [String: [Slot]]

    nonisolated struct Slot: Decodable, Sendable {
        let name: String?
        let description: String?
        /// Some stations point this at the show's page on their own site.
        let url: String?
        let image_path: String?
        let start_timestamp: String?
        let end_timestamp: String?
        /// Airtime's own id for the show, stable across its instances.
        let id: Int?
        let instance_id: Int?
    }

    /// The payload mixes the fourteen day arrays with scalars like
    /// `AIRTIME_API_VERSION`, so it is decoded key by key and anything that is
    /// not a list of slots is skipped rather than throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var found: [String: [Slot]] = [:]
        for key in container.allKeys {
            guard let slots = try? container.decode([Slot].self, forKey: key) else { continue }
            found[key.stringValue.lowercased()] = slots
        }
        days = found
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Every slot in the fortnight, in time order. The day keys carry no date
    /// themselves — the timestamps inside them do — so ordering is done on
    /// those rather than on the order the days arrived in.
    func slots(zone: TimeZone) -> [(slot: Slot, starts: Date, ends: Date)] {
        days.values
            .flatMap { $0 }
            .compactMap { slot in
                guard let starts = AirtimeTimestamp.parse(slot.start_timestamp, zone: zone),
                      let ends = AirtimeTimestamp.parse(slot.end_timestamp, zone: zone),
                      ends > starts
                else { return nil }
                return (slot, starts, ends)
            }
            .sorted { $0.starts < $1.starts }
    }
}
