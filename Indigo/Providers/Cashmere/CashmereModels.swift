//
//  CashmereModels.swift
//  Indigo
//
//  Wire format for cashmereradio.com plus the shapes the Cashmere pages
//  render.
//
//  Cashmere is a WordPress site read through WPGraphQL, so everything arrives
//  as edges and nodes, and the fields the station actually cares about — the
//  genres, the moods, the Mixcloud link — hang off `acf`, WordPress's custom
//  field bag. Introspection is switched off on their endpoint, so the queries
//  are written against the shape their own front end asks for.
//

import Foundation

// MARK: - GraphQL envelope

nonisolated struct CashmereResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
    let errors: [GraphQLError]?

    nonisolated struct GraphQLError: Decodable, Sendable {
        let message: String?
    }
}

nonisolated struct CashmereConnection<Node: Decodable & Sendable>: Decodable, Sendable {
    let pageInfo: PageInfo?
    let edges: [Edge]

    nonisolated struct Edge: Decodable, Sendable {
        let node: Node
    }

    nonisolated struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool?
        let endCursor: String?
    }

    var nodes: [Node] { edges.map(\.node) }
}

// MARK: - Wire types

nonisolated struct CashmereEpisodeDTO: Decodable, Sendable {
    let databaseId: Int?
    let slug: String?
    let title: String?
    let uri: String?
    let dateGmt: String?
    let content: String?
    let acf: ACF?
    let categories: CashmereConnection<CategoryDTO>?
    let featuredImage: FeaturedImage?

    nonisolated struct ACF: Decodable, Sendable {
        /// "20260611" — the date it went out, which is not the date it was
        /// published to the site.
        let episodeDate: String?
        let episodeMixcloudLink: String?
        let episodeFilterGenre: [String]?
        let episodeFilterMood: [String]?
        let episodeFilterFocuseddiverse: String?
    }

    nonisolated struct FeaturedImage: Decodable, Sendable {
        let node: Node?
        nonisolated struct Node: Decodable, Sendable {
            let sourceUrl: String?
            let altText: String?
            /// WordPress's "url 600w, url 1024w, …" list of the same picture
            /// at every size it made.
            let srcSet: String?

            /// The smallest cut that still covers `width`. `sourceUrl` is the
            /// untouched original — often a megabyte — and a grid of two dozen
            /// tiles has no business downloading two dozen of those.
            func url(atLeast width: Int) -> URL? {
                let candidates = (srcSet ?? "")
                    .components(separatedBy: ",")
                    .compactMap { entry -> (url: String, width: Int)? in
                        let parts = entry.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: " ")
                            .filter { !$0.isEmpty }
                        guard parts.count >= 2,
                              let measure = Int(parts[1].replacingOccurrences(of: "w", with: ""))
                        else { return nil }
                        return (parts[0], measure)
                    }
                    .sorted { $0.width < $1.width }

                let pick = candidates.first { $0.width >= width } ?? candidates.last
                if let pick, let url = URL(string: pick.url) { return url }
                return sourceUrl.flatMap { URL(string: $0) }
            }
        }
    }
}

/// A WordPress category, which is how Cashmere files its recurring shows.
nonisolated struct CategoryDTO: Decodable, Sendable {
    let databaseId: Int?
    let name: String?
    let slug: String?
    let count: Int?
}

nonisolated struct CashmereStreamDTO: Decodable, Sendable {
    let databaseId: Int?
    let title: String?
    let slug: String?
    let acf: ACF?

    nonisolated struct ACF: Decodable, Sendable {
        let mp3Stream: String?
    }
}

// MARK: - Domain types

nonisolated struct CashmereShow: Identifiable, Hashable, Sendable {
    let slug: String
    let name: String
    /// How many episodes the station has filed under it.
    let episodeCount: Int

    var id: String { slug }
}

nonisolated struct CashmereEpisode: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let airedAt: Date?
    let artworkURL: URL?
    let genres: [String]
    let moods: [String]
    /// Cashmere archives to Mixcloud, so this is what actually plays.
    let mixcloudURL: URL?
    let showName: String?
    let showSlug: String?
    /// Only present once the episode has been asked for by name.
    let summary: String?

    var id: String { slug }
    var mediaID: String { "cashmere.episode.\(slug)" }
    var isPlayable: Bool { mixcloudURL != nil }

    var airedLabel: String? {
        guard let airedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: airedAt)
    }

    var subtitle: String {
        [airedLabel, showName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem? {
        guard let mixcloudURL else { return nil }
        return MediaItem(
            id: mediaID,
            sourceID: CashmereProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: showName ?? airedLabel,
            detail: "Cashmere Radio",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: mixcloudURL,
            embedProvider: .mixcloud
        )
    }
}

/// What Airtime says is on the air this moment.
nonisolated struct CashmereOnAir: Sendable {
    let showName: String?
    let showStartsAt: Date?
    let showEndsAt: Date?
    /// Where the show lives on Cashmere's own site, when Airtime carries it.
    let showSlug: String?
    let trackTitle: String?
    let trackArtist: String?
    let upNext: [CashmereSlot]

    var elapsedFraction: Double? {
        guard let showStartsAt, let showEndsAt, showEndsAt > showStartsAt else { return nil }
        let total = showEndsAt.timeIntervalSince(showStartsAt)
        let done = Date.now.timeIntervalSince(showStartsAt)
        return min(1, max(0, done / total))
    }

    /// "18:00–20:00" in the listener's local time.
    var slot: String? {
        guard let showStartsAt, let showEndsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: showStartsAt))–\(formatter.string(from: showEndsAt))"
    }

    func asRadioShow() -> RadioShow? {
        guard let showName, !showName.isEmpty else { return nil }
        return RadioShow(
            title: showName,
            host: trackArtist,
            summary: nil,
            location: "Berlin",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: showStartsAt,
            endsAt: showEndsAt,
            detailID: showSlug
        )
    }
}

nonisolated struct CashmereSlot: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let showSlug: String?
    let startsAt: Date
    let endsAt: Date

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }
}

nonisolated struct CashmereStream: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let url: URL

    var id: String { slug }
}

// MARK: - Mapping

extension CashmereEpisodeDTO {
    func asEpisode() -> CashmereEpisode? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let category = categories?.nodes.first
        return CashmereEpisode(
            slug: identity,
            title: name,
            // The broadcast date the station stamps beats the date the page
            // happened to be published.
            airedAt: CashmereTimestamp.parseAirDate(acf?.episodeDate)
                ?? CashmereTimestamp.parsePublished(dateGmt),
            // 600 covers a 300pt hero on a retina display and every tile
            // below it, which is as much as anything here is ever drawn at.
            artworkURL: featuredImage?.node?.url(atLeast: 600),
            genres: clean(acf?.episodeFilterGenre),
            moods: clean(acf?.episodeFilterMood),
            mixcloudURL: acf?.episodeMixcloudLink.flatMap { link in
                let trimmed = link.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                // Some links are written without a scheme.
                return URL(string: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)")
            },
            showName: category?.name.map(HTMLText.decode),
            showSlug: category?.slug,
            summary: content.flatMap(HTMLText.plainText)
        )
    }

    private func clean(_ values: [String]?) -> [String] {
        (values ?? []).compactMap {
            let text = HTMLText.decode($0).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }
}

extension CategoryDTO {
    func asShow() -> CashmereShow? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let label = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return CashmereShow(slug: identity, name: label, episodeCount: count ?? 0)
    }
}

extension CashmereStreamDTO {
    func asStream() -> CashmereStream? {
        guard let identity = slug, !identity.isEmpty,
              let address = acf?.mp3Stream, let url = URL(string: address), url.host != nil
        else { return nil }
        let label = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        return CashmereStream(slug: identity, title: label.isEmpty ? identity : label, url: url)
    }
}

// MARK: - Helpers

nonisolated enum CashmereTimestamp {
    /// "20260611" — a date, no time and no zone.
    static func parseAirDate(_ value: String?) -> Date? {
        guard let value, value.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: value)
    }

    /// WordPress publishes "2026-08-28T19:52:33" in GMT with no marker on it.
    static func parsePublished(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }
}
