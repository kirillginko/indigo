//
//  LYLModels.swift
//  Indigo
//
//  Wire format for lyl.live plus the shapes the LYL pages render.
//
//  LYL runs on Strapi behind a GraphQL endpoint. Introspection is off, so the
//  queries are written against the shape LYL's own front end asks for. It is
//  the most complete thing Indigo reads: episodes carry a direct audio file as
//  well as Mixcloud and SoundCloud mirrors, a tracklist, styles and the studio
//  they came out of.
//

import Foundation

// MARK: - GraphQL envelope

nonisolated struct LYLResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
    let errors: [GraphQLError]?

    nonisolated struct GraphQLError: Decodable, Sendable {
        let message: String?
    }
}

// MARK: - Wire types

nonisolated struct LYLAssetDTO: Decodable, Sendable {
    let url: String?
    let mime: String?
    let name: String?
    let alternativeText: String?
}

nonisolated struct LYLStyleDTO: Decodable, Sendable {
    let id: String?
    let name: String?
}

nonisolated struct LYLStudioDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let city: String?
}

nonisolated struct LYLLinkDTO: Decodable, Sendable {
    let type: String?
    let url: String?
}

nonisolated struct LYLShowDTO: Decodable, Sendable {
    let id: String?
    let slug: String?
    let title: String?
    /// "Monthly", "Bimestrial", "OneOff", "Terminated" — how often it returns.
    let recursion: String?
    let nextBroadcast: String?
    let description: String?
    /// A single string rather than a list, however many names are in it.
    let artists: String?
    let styles: [LYLStyleDTO]?
    let links: [LYLLinkDTO]?
    let image: LYLAssetDTO?
}

nonisolated struct LYLEpisodeDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let slug: String?
    let artists: String?
    let startAt: String?
    /// "01:00:00.000" — a clock, not a count of seconds.
    let duration: String?
    let mixcloud: String?
    let soundcloud: String?
    let audio: LYLAssetDTO?
    let show: LYLShowDTO?
    let description: String?
    /// One track a line, most of them written "- Artist - Title".
    let tracks: String?
    let styles: [LYLStyleDTO]?
    let image: LYLAssetDTO?
}

nonisolated struct LYLCalendarEntryDTO: Decodable, Sendable {
    let startAt: String?
    let end: String?
    let title: String?
    let slug: String?
    let artists: String?
    /// "EPISODE" for something that will be archived.
    let type: String?
}

nonisolated struct LYLOnAirDTO: Decodable, Sendable {
    let title: String?
    let hls: String?
}

// MARK: - Domain types

nonisolated struct LYLStyle: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated struct LYLStudio: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let city: String

    /// "Unité Centrale, Lyon"
    var label: String { city.isEmpty || city == name ? name : "\(name), \(city)" }
}

nonisolated struct LYLShow: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let recursion: String?
    let nextBroadcast: Date?
    let summary: String?
    let artists: String?
    let styles: [String]
    let links: [MediaLink]
    let imageURL: URL?

    var id: String { slug }

    /// LYL marks a show that has ended rather than deleting it.
    var hasEnded: Bool { recursion?.caseInsensitiveCompare("Terminated") == .orderedSame }

    /// "Monthly", "One off" — written as one word in the data.
    var recursionLabel: String? {
        guard let recursion, !recursion.isEmpty else { return nil }
        if recursion.caseInsensitiveCompare("OneOff") == .orderedSame { return "One off" }
        return recursion
    }

    var subtitle: String {
        [recursionLabel, artists].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

nonisolated struct LYLEpisode: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let artists: String?
    let broadcastAt: Date?
    let duration: TimeInterval?
    /// LYL hosts the recording itself, which is why an episode seeks properly
    /// instead of going through somebody's widget.
    let audioURL: URL?
    let mixcloudURL: URL?
    let soundcloudURL: URL?
    let imageURL: URL?
    let summary: String?
    /// One entry a line, as written. Splitting "Artist - Title" reliably is
    /// not possible when half of them use a different separator.
    let tracks: [String]
    let styles: [String]
    let showSlug: String?
    let showTitle: String?

    var id: String { slug }
    var mediaID: String { "lyl.episode.\(slug)" }
    var isPlayable: Bool { audioURL != nil || soundcloudURL != nil || mixcloudURL != nil }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }

    var subtitle: String {
        [broadcastLabel, artists ?? showTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        // The station's own file first: it seeks, reports a real duration and
        // costs nobody an embed. But LYL's older uploads are not all still
        // there — some answer 403 — so whichever mirror it also published
        // rides along as the fallback rather than the episode simply failing.
        let mirror: (url: URL, embed: EmbedProvider)? = {
            if let soundcloudURL { return (soundcloudURL, .soundcloud) }
            if let mixcloudURL { return (mixcloudURL, .mixcloud) }
            return nil
        }()

        if let audioURL {
            return item(url: audioURL, embed: nil, alternate: mirror)
        }
        if let soundcloudURL {
            return item(
                url: soundcloudURL,
                embed: .soundcloud,
                alternate: mixcloudURL.map { ($0, .mixcloud) }
            )
        }
        if let mixcloudURL {
            return item(url: mixcloudURL, embed: .mixcloud, alternate: nil)
        }
        return nil
    }

    private func item(
        url: URL,
        embed: EmbedProvider?,
        alternate: (url: URL, embed: EmbedProvider)?
    ) -> MediaItem {
        MediaItem(
            id: mediaID,
            sourceID: LYLProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: artists ?? showTitle ?? broadcastLabel,
            detail: "LYL Radio",
            genres: styles,
            remoteArtworkURL: imageURL,
            playbackURL: url,
            duration: duration,
            embedProvider: embed,
            alternatePlaybackURL: alternate?.url,
            alternateEmbedProvider: alternate?.embed
        )
    }
}

nonisolated struct LYLScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: String?
    /// Present when the slot will end up in the archive.
    let episodeSlug: String?
    let startsAt: Date
    let endsAt: Date

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's local time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    func asRadioShow() -> RadioShow {
        RadioShow(
            title: title,
            host: artists,
            summary: nil,
            location: "Lyon / Paris",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: episodeSlug
        )
    }
}

// MARK: - Mapping

extension LYLStyleDTO {
    func asStyle() -> LYLStyle? {
        let label = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return LYLStyle(id: id ?? label.lowercased(), name: label)
    }
}

extension LYLStudioDTO {
    func asStudio() -> LYLStudio? {
        let label = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return LYLStudio(
            id: id ?? label.lowercased(),
            name: label,
            city: HTMLText.decode(city ?? "").trimmingCharacters(in: .whitespaces)
        )
    }
}

extension LYLShowDTO {
    func asShow() -> LYLShow? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return LYLShow(
            slug: identity,
            title: name,
            recursion: recursion,
            nextBroadcast: LYLTimestamp.parse(nextBroadcast),
            summary: description.flatMap(HTMLText.plainText),
            artists: artists.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            styles: (styles ?? []).compactMap { $0.asStyle()?.name },
            links: (links ?? []).compactMap { link in
                guard let address = link.url, let url = URL(string: address), url.host != nil
                else { return nil }
                let label = HTMLText.decode(link.type ?? "").trimmingCharacters(in: .whitespaces)
                return MediaLink(label: label.isEmpty ? MediaLink.label(for: url) : label, url: url)
            },
            imageURL: image?.url.flatMap { URL(string: $0) }
        )
    }
}

extension LYLEpisodeDTO {
    func asEpisode() -> LYLEpisode? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return LYLEpisode(
            slug: identity,
            title: name,
            artists: artists.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            broadcastAt: LYLTimestamp.parse(startAt),
            duration: LYLTimestamp.parseDuration(duration),
            audioURL: audio?.url.flatMap { URL(string: $0) },
            mixcloudURL: LYLLink.permalink(mixcloud),
            soundcloudURL: LYLLink.permalink(soundcloud),
            imageURL: image?.url.flatMap { URL(string: $0) },
            summary: description.flatMap(HTMLText.plainText),
            tracks: LYLTracklist.parse(tracks),
            styles: (styles ?? []).compactMap { $0.asStyle()?.name },
            showSlug: show?.slug,
            showTitle: show?.title.map(HTMLText.decode)
        )
    }
}

extension LYLCalendarEntryDTO {
    func asScheduleEntry() -> LYLScheduleEntry? {
        guard let start = LYLTimestamp.parse(startAt),
              let finish = LYLTimestamp.parse(end),
              finish > start
        else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return LYLScheduleEntry(
            id: slug ?? "\(name)|\(start.timeIntervalSince1970)",
            title: name,
            artists: artists.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            // Only a slot that becomes an episode has somewhere to point.
            episodeSlug: type?.caseInsensitiveCompare("EPISODE") == .orderedSame ? slug : nil,
            startsAt: start,
            endsAt: finish
        )
    }
}

// MARK: - Helpers

nonisolated enum LYLTimestamp {
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

    /// "01:00:00.000" — hours, minutes, seconds, rather than a number.
    static func parseDuration(_ value: String?) -> TimeInterval? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }
}

nonisolated enum LYLTracklist {
    /// One track a line, most written "- Artist - Title". The separator is not
    /// consistent enough to split on, so each line is kept as it was written.
    static func parse(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .components(separatedBy: .newlines)
            .map { line -> String in
                var text = HTMLText.decode(line).trimmingCharacters(in: .whitespaces)
                while text.hasPrefix("-") || text.hasPrefix("•") || text.hasPrefix("–") {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
    }
}

nonisolated enum LYLLink {
    /// LYL's SoundCloud links carry share tracking; the widget wants the bare
    /// permalink.
    static func permalink(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              var components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              components.host != nil
        else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
