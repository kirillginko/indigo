//
//  AlharaModels.swift
//  Indigo
//
//  Wire format for radioalhara.net.
//
//  alHara's own site publishes only three live channels and what is on each
//  this minute — no archive, no schedule, no roster. The archive it does have
//  lives on Mixcloud, so the browse types below are Mixcloud's shapes rather
//  than the station's.
//

import Foundation

// MARK: - Wire types

/// The main channel. It carries the most, because it is the one with a studio
/// behind it.
nonisolated struct AlharaNowPlayingDTO: Decodable, Sendable {
    let title: String?
    let artist: String?
    let episodeTitle: String?
    let episodeId: String?
    /// Present only on a rerun, and then it is the date of the original.
    let airDate: String?
    let originalAirDate: String?
    let isRerun: Bool?
    let scheduledTitle: String?
    /// "harbor" — a DJ is connected; "relay" — another stream is being
    /// carried; "fallback" — the automated playlist.
    let mode: String?
    let trackStart: String?
    let duration: Double?
    let ch2City: String?
    let ch2Timezone: String?
    let ch2Label: String?
    /// The station's own signal that a channel is not worth showing.
    let ch2HideRa2: Bool?
    let ch2HideRa3: Bool?
}

/// The two secondary channels, which are relays and events rather than a
/// studio, and say correspondingly less.
nonisolated struct AlharaRelayDTO: Decodable, Sendable {
    let isHarborActive: Bool?
    let isRelayActive: Bool?
    let relayTitle: String?
    let relayTrackTitle: String?
    let displayTitle: String?
    let forcedTitle: String?
    let mode: String?
    let city: String?
    let timezone: String?
    /// RA3 sometimes carries a video feed alongside the audio.
    let videoActive: Bool?
    let videoUrl: String?
    let meta: Meta?

    nonisolated struct Meta: Decodable, Sendable {
        let title: String?
        let artist: String?
    }
}

// MARK: - Domain types

/// How a channel is filling its air right now.
nonisolated enum AlharaMode: String, Sendable {
    /// A DJ is connected and playing.
    case live
    /// Another station's stream is being carried.
    case relay
    /// The automated playlist, between shows.
    case automated

    init(_ raw: String?) {
        switch raw?.lowercased() {
        case "harbor", "live": self = .live
        case "relay": self = .relay
        default: self = .automated
        }
    }

    var label: String {
        switch self {
        case .live: "On air now"
        case .relay: "Relaying"
        case .automated: "Between shows"
        }
    }

    /// Only a connected DJ counts as live; the automated playlist is the
    /// station keeping the lights on, and saying otherwise would be a lie.
    var isLive: Bool { self != .automated }
}

/// What one channel is doing this minute.
nonisolated struct AlharaChannelState: Sendable, Equatable {
    let mode: AlharaMode
    /// What is on — the show, the relayed station, or nothing.
    let title: String?
    let artist: String?
    let city: String?
    let startedAt: Date?
    let duration: TimeInterval?
    /// Set when this is a repeat of something first broadcast earlier.
    let originalAirDate: Date?
    let isRerun: Bool
    /// RA3 occasionally puts a picture behind the sound.
    let videoURL: URL?

    var isOnAir: Bool { mode.isLive }

    /// 0…1 through the set, for the on-air progress hairline.
    func elapsedFraction(at date: Date = .now) -> Double? {
        guard let startedAt, let duration, duration > 0 else { return nil }
        return min(1, max(0, date.timeIntervalSince(startedAt) / duration))
    }

    var startedLabel: String? {
        guard let startedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: startedAt)
    }

    var originalAirLabel: String? {
        guard let originalAirDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: originalAirDate)
    }

    static let idle = AlharaChannelState(
        mode: .automated,
        title: nil,
        artist: nil,
        city: nil,
        startedAt: nil,
        duration: nil,
        originalAirDate: nil,
        isRerun: false,
        videoURL: nil
    )

    func asRadioShow() -> RadioShow? {
        guard let title, !title.isEmpty else { return nil }
        return RadioShow(
            title: title,
            host: artist,
            summary: nil,
            location: city ?? "Bethlehem",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: startedAt,
            endsAt: duration.flatMap { seconds in startedAt.map { $0.addingTimeInterval(seconds) } },
            detailID: nil
        )
    }
}

// MARK: - Mapping

extension AlharaNowPlayingDTO {
    func asChannelState() -> AlharaChannelState {
        let name = HTMLText.decode(episodeTitle ?? title ?? scheduledTitle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AlharaChannelState(
            mode: AlharaMode(mode),
            title: name.isEmpty ? nil : name,
            artist: artist.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            city: ch2City.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: AlharaTimestamp.parse(trackStart),
            duration: (duration ?? 0) > 0 ? duration : nil,
            // The payload carries an `airDate` even when nothing is a repeat,
            // so it only means anything once the station says it is one.
            originalAirDate: (isRerun ?? false)
                ? AlharaTimestamp.parse(originalAirDate ?? airDate)
                : nil,
            isRerun: isRerun ?? false,
            videoURL: nil
        )
    }

    /// Channels the station has asked not to be shown.
    nonisolated var hiddenChannels: Set<String> {
        var hidden: Set<String> = []
        if ch2HideRa2 == true { hidden.insert("alhara.ra2") }
        if ch2HideRa3 == true { hidden.insert("alhara.ra3") }
        return hidden
    }
}

extension AlharaRelayDTO {
    func asChannelState() -> AlharaChannelState {
        let resolved = AlharaMode(mode)
        // The relay endpoints report their own booleans as well as a mode, and
        // the booleans are the more reliable of the two.
        let mode: AlharaMode = {
            if isHarborActive == true { return .live }
            if isRelayActive == true { return .relay }
            return resolved
        }()

        let name = [forcedTitle, displayTitle, relayTitle, relayTrackTitle, meta?.title]
            .compactMap { $0 }
            .map { HTMLText.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return AlharaChannelState(
            mode: mode,
            title: name,
            artist: meta?.artist.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            city: city.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: nil,
            duration: nil,
            originalAirDate: nil,
            isRerun: false,
            videoURL: videoActive == true ? videoUrl.flatMap { URL(string: $0) } : nil
        )
    }
}

// MARK: - Helpers

nonisolated enum AlharaTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}


// MARK: - The archive, which lives on Mixcloud

/// alHara hosts nothing itself, so its recorded shows are read from Mixcloud's
/// public API — open, documented and needing no key — and played through the
/// same widget Kiosk uses.
nonisolated struct MixcloudPageDTO: Decodable, Sendable {
    let data: [MixcloudCloudcastDTO]
    let paging: Paging?

    nonisolated struct Paging: Decodable, Sendable {
        let next: String?
        let previous: String?
    }
}

nonisolated struct MixcloudCloudcastDTO: Decodable, Sendable {
    let key: String?
    let url: String?
    let name: String?
    let slug: String?
    let created_time: String?
    /// Seconds.
    let audio_length: Int?
    let play_count: Int?
    let favorite_count: Int?
    let tags: [Tag]?
    /// Size name → address. Mixcloud offers ten of them.
    let pictures: [String: String]?
    // Detail only.
    let description: String?
    let sections: [Section]?

    nonisolated struct Tag: Decodable, Sendable {
        let name: String?
        let key: String?
    }

    /// Mixcloud's tracklist. Most of alHara's uploads have none, and the ones
    /// that do give a start time per track.
    nonisolated struct Section: Decodable, Sendable {
        let start_time: Int?
        let track: Track?

        nonisolated struct Track: Decodable, Sendable {
            let name: String?
            let artist: Artist?
            nonisolated struct Artist: Decodable, Sendable { let name: String? }
        }
    }

    /// Large enough for a detail hero, small enough not to pull the 1024px
    /// original into a grid tile.
    var artworkURL: URL? {
        let preferred = ["large", "640wx640h", "extra_large", "320wx320h", "medium", "thumbnail"]
        for size in preferred {
            if let address = pictures?[size], let url = URL(string: address) { return url }
        }
        return pictures?.values.first.flatMap { URL(string: $0) }
    }
}

nonisolated struct AlharaTrack: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let artist: String?
    /// Seconds into the show, when Mixcloud knows it.
    let offset: TimeInterval?

    var id: Int { index }

    var offsetLabel: String? {
        guard let offset, offset >= 0 else { return nil }
        let total = Int(offset.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

nonisolated struct AlharaShow: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let publishedAt: Date?
    let artworkURL: URL?
    let duration: TimeInterval?
    let genres: [String]
    let playCount: Int?
    /// The permalink the widget plays.
    let mixcloudURL: URL
    /// Detail only.
    let summary: String?
    let tracklist: [AlharaTrack]

    var id: String { slug }
    var mediaID: String { "alhara.show.\(slug)" }

    var publishedLabel: String? {
        guard let publishedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: publishedAt)
    }

    var subtitle: String {
        [publishedLabel, duration.map { TimeFormat.clock($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem {
        MediaItem(
            id: mediaID,
            sourceID: AlharaProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: publishedLabel,
            detail: "Radio alHara",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: mixcloudURL,
            duration: duration,
            embedProvider: .mixcloud
        )
    }
}

extension MixcloudCloudcastDTO {
    func asShow() -> AlharaShow? {
        let identity = slug ?? key
        guard let identity, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(self.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let address = url, let permalink = URL(string: address) else { return nil }

        let tracks = (sections ?? []).enumerated().compactMap { index, section -> AlharaTrack? in
            let title = HTMLText.decode(section.track?.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let artist = HTMLText.decode(section.track?.artist?.name ?? "").trimmingCharacters(in: .whitespaces)
            return AlharaTrack(
                index: index + 1,
                title: title,
                artist: artist.isEmpty ? nil : artist,
                offset: section.start_time.map(TimeInterval.init)
            )
        }

        return AlharaShow(
            slug: identity,
            title: name,
            publishedAt: AlharaTimestamp.parse(created_time),
            artworkURL: artworkURL,
            duration: (audio_length ?? 0) > 0 ? TimeInterval(audio_length ?? 0) : nil,
            genres: (tags ?? []).compactMap { tag in
                let label = HTMLText.decode(tag.name ?? "").trimmingCharacters(in: .whitespaces)
                return label.isEmpty ? nil : label
            },
            playCount: play_count,
            mixcloudURL: permalink,
            summary: description.flatMap(HTMLText.plainText),
            tracklist: tracks
        )
    }
}
