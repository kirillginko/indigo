//
//  Radio80000Models.swift
//  Indigo
//
//  Wire format for radio80k.de plus the shapes the Radio 80000 pages render.
//
//  Radio 80000 is a community station in Munich, and it is assembled from three
//  places rather than one: Airtime carries the live channel and the calendar,
//  WordPress carries the shows, and the recordings live on SoundCloud and
//  Mixcloud — a good many shows keep a playlist on both. So the single idea
//  running through this file is that a broadcast has a source, and everything
//  downstream has to hold both kinds without caring which it got.
//

import Foundation

// MARK: - WordPress wire types

/// WordPress hands back every prose field pre-rendered.
nonisolated struct WPRendered: Decodable, Sendable {
    let rendered: String?
}

/// Advanced Custom Fields writes an empty repeater as `false` rather than as
/// an empty array, and an unset number the same way — so anything optional
/// coming out of ACF has to tolerate a bool where its type should be.
nonisolated struct Radio80000ShowDTO: Decodable, Sendable {
    let id: Int?
    let slug: String?
    let link: String?
    let title: WPRendered?
    let content: WPRendered?
    let featured_media: Int?
    /// The station's own convenience field: "Munich", already flattened out
    /// of the `city` taxonomy.
    let cities: String?
    let acf: ACF?
    let soundcloud_playlist_id: FlexibleInt?
    let _embedded: Embedded?

    nonisolated struct ACF: Decodable, Sendable {
        /// "weekly", "bi-monthly", "monthly" — as typed, spacing and all.
        let cycle: String?
        let weekday: String?
        /// "15:00 - 16:00"
        let time: String?
        let links: FlexibleLinks?
        let mixcloud_playlist_url: String?
        let soundcloud_playlist_url: String?
    }

    nonisolated struct Embedded: Decodable, Sendable {
        let featuredmedia: [Media]?
        /// One array per taxonomy attached to the post, in no stated order —
        /// so which is `genre` and which is `city` is read off each term.
        let term: [[Term]]?

        private enum CodingKeys: String, CodingKey {
            case featuredmedia = "wp:featuredmedia"
            case term = "wp:term"
        }
    }

    nonisolated struct Media: Decodable, Sendable {
        let source_url: String?
        let media_details: Details?

        nonisolated struct Details: Decodable, Sendable {
            let sizes: [String: Size]?
            nonisolated struct Size: Decodable, Sendable {
                let source_url: String?
                let width: Int?
            }
        }

        var fullURL: URL? { source_url.flatMap { URL(string: $0) } }

        /// The smallest cut at least `width` across. The station uploads show
        /// logos at full size, and a grid has no use for a 2048px one.
        func url(atLeast width: Int) -> URL? {
            let candidates = (media_details?.sizes ?? [:]).values
                .compactMap { size -> (Int, URL)? in
                    guard let address = size.source_url, let url = URL(string: address) else { return nil }
                    return (size.width ?? .max, url)
                }
                .sorted { $0.0 < $1.0 }
            return candidates.first { $0.0 >= width }?.1 ?? fullURL
        }
    }

    nonisolated struct Term: Decodable, Sendable {
        let name: String?
        let slug: String?
        let taxonomy: String?
    }
}

/// A number that ACF may also write as `false`.
nonisolated struct FlexibleInt: Decodable, Sendable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { value = number; return }
        if let text = try? container.decode(String.self) { value = Int(text); return }
        value = nil
    }
}

/// A repeater that ACF may also write as `false`.
nonisolated struct FlexibleLinks: Decodable, Sendable {
    let links: [Link]

    nonisolated struct Link: Decodable, Sendable {
        let url: String?
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        links = (try? container.decode([Link].self)) ?? []
    }
}

nonisolated struct Radio80000TermDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let slug: String?
    let count: Int?
}

// MARK: - SoundCloud wire types

/// A track as the station's own proxy hands it back. Radio 80000 fronts the
/// SoundCloud API from WordPress, which is why none of this needs a key.
nonisolated struct Radio80000TrackDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let description: String?
    /// Milliseconds.
    let duration: Int?
    /// "2026/08/07 14:18:05 +0000" — when it was uploaded, which for this
    /// station is the day of the broadcast or the day after.
    let created_at: String?
    let permalink_url: String?
    let artwork_url: String?
    let genre: String?
    /// Space-separated, with multi-word tags in quotes.
    let tag_list: String?
}

/// The proxy answers the first page as an object with a cursor and later pages
/// as a bare array, so both are accepted here rather than at every call site.
nonisolated struct Radio80000TrackPageDTO: Decodable, Sendable {
    let collection: [Radio80000TrackDTO]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey { case collection, next_href }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Radio80000TrackDTO].self) {
            collection = list
            nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collection = (try? container.decode([Radio80000TrackDTO].self, forKey: .collection)) ?? []
        nextCursor = (try? container.decodeIfPresent(String.self, forKey: .next_href))
            .flatMap { $0 }
            .flatMap(Radio80000Cursor.extract)
    }
}

nonisolated struct Radio80000PlaylistDTO: Decodable, Sendable {
    let title: String?
    let permalink_url: String?
    let track_count: Int?
    let tracks: [Radio80000TrackDTO]?
}

/// `next_href` is a relative SoundCloud path carrying an opaque cursor. Only
/// the cursor is ours to keep — the path is rebuilt against the proxy.
nonisolated enum Radio80000Cursor {
    static func extract(_ href: String) -> String? {
        guard let components = URLComponents(string: href) else { return nil }
        return components.queryItems?.first { $0.name == "cursor" }?.value
    }
}

// MARK: - Domain types

nonisolated struct Radio80000Genre: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated struct Radio80000Show: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let summary: String?
    let genres: [String]
    let city: String?
    let imageURL: URL?
    let thumbnailURL: URL?
    /// "Wednesday", "15:00 - 16:00", "bi-monthly" — how often it returns.
    let weekday: String?
    let time: String?
    let cycle: String?
    let links: [MediaLink]
    /// Where this show's recordings are. Most shows have one; a good many have
    /// both, and twenty-nine have neither.
    let soundcloudPlaylistID: Int?
    let mixcloudPlaylist: String?

    var id: String { slug }

    var hasArchive: Bool { soundcloudPlaylistID != nil || mixcloudPlaylist != nil }

    /// "Wednesday 15:00 - 16:00 · bi-monthly"
    var scheduleLabel: String? {
        let slot = [weekday, time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let parts = [slot.isEmpty ? nil : slot, cycle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var subtitle: String {
        [scheduleLabel, genres.first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Where a recording actually lives. Both play through a widget rather than a
/// stream, because both platforms' terms require it.
nonisolated enum Radio80000Source: String, Hashable, Sendable {
    case soundcloud
    case mixcloud

    var embed: EmbedProvider {
        switch self {
        case .soundcloud: .soundcloud
        case .mixcloud: .mixcloud
        }
    }

    var label: String {
        switch self {
        case .soundcloud: "SoundCloud"
        case .mixcloud: "Mixcloud"
        }
    }
}

nonisolated struct Radio80000Track: Identifiable, Hashable, Sendable {
    let index: Int
    let title: String
    let artist: String?
    /// Seconds into the broadcast, when Mixcloud knows it.
    let offset: TimeInterval?

    var id: Int { index }

    var offsetLabel: String? {
        guard let offset, offset >= 0 else { return nil }
        let total = Int(offset.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "Artist — Title", or just the title when Mixcloud logged no artist.
    var display: String {
        guard let artist, !artist.isEmpty else { return title }
        return "\(artist) — \(title)"
    }
}

nonisolated struct Radio80000Episode: Identifiable, Hashable, Sendable {
    /// Self-describing, because the crate stores it and a cold open has to be
    /// able to fetch the thing back from nothing but this string. See
    /// `Radio80000EpisodeID`.
    let id: String
    let title: String
    let broadcastAt: Date?
    let duration: TimeInterval?
    let artworkURL: URL?
    /// The page on SoundCloud or Mixcloud, which is also what the widget loads.
    let permalink: URL
    let summary: String?
    let genres: [String]
    let tracks: [Radio80000Track]
    let showSlug: String?
    let showTitle: String?
    let source: Radio80000Source

    var mediaID: String { "radio80000.episode.\(id)" }
    /// Every episode here is a published recording, so all of them play.
    var isPlayable: Bool { true }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }

    /// The title already ends in its own date — "Room Service (26/08/26)" —
    /// so the line under it says who and where instead of repeating that.
    var listSubtitle: String {
        [showTitle, genres.first]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem {
        MediaItem(
            id: mediaID,
            sourceID: Radio80000Provider.providerID,
            kind: .episode,
            title: title,
            subtitle: showTitle ?? broadcastLabel,
            detail: "Radio 80000",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: permalink,
            duration: duration,
            embedProvider: source.embed
        )
    }
}

/// A slot on Airtime's calendar.
nonisolated struct Radio80000ScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String?
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
            host: nil,
            summary: summary,
            location: "Munich",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: nil
        )
    }
}

/// What Airtime says is on the air this moment.
nonisolated struct Radio80000OnAir: Hashable, Sendable {
    var showName: String?
    var showSummary: String?
    var showStartsAt: Date?
    var showEndsAt: Date?
    /// Airtime names the file playing inside the show, which is often the
    /// pre-recorded broadcast rather than a track — so it is shown as a
    /// secondary line and never as the title.
    var trackTitle: String?
    var trackArtist: String?

    static let idle = Radio80000OnAir()

    var isOnAir: Bool { showName != nil }

    func asRadioShow() -> RadioShow? {
        guard let showName else { return nil }
        return RadioShow(
            title: showName,
            host: nil,
            summary: showSummary,
            location: "Munich",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: showStartsAt,
            endsAt: showEndsAt,
            detailID: nil
        )
    }
}

nonisolated struct Radio80000Live: Sendable {
    var onAir: Radio80000OnAir
    var timeZone: TimeZone
}

// MARK: - Episode identity

/// An episode id that can be turned back into a request.
///
/// The crate keeps only this string, and a listener can open a crated
/// broadcast months later from a cold start — so it has to say where the
/// recording lives and how to ask for it again. Mixcloud keys are a path and
/// refetch directly; SoundCloud has no per-track route on the station's proxy,
/// so the show slug rides along and the track is found in that show's playlist.
nonisolated enum Radio80000EpisodeID {
    static func soundcloud(trackID: Int, showSlug: String?) -> String {
        guard let showSlug, !showSlug.isEmpty else { return "sc:\(trackID)" }
        return "sc:\(trackID)@\(showSlug)"
    }

    /// Mixcloud keys arrive as "/Radio80K/all-exhales-010323/".
    static func mixcloud(key: String) -> String {
        "mc:\(key.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    enum Parsed: Equatable {
        case soundcloud(trackID: Int, showSlug: String?)
        case mixcloud(key: String)
    }

    static func parse(_ id: String) -> Parsed? {
        if id.hasPrefix("mc:") {
            let key = String(id.dropFirst(3))
            return key.isEmpty ? nil : .mixcloud(key: key)
        }
        guard id.hasPrefix("sc:") else { return nil }
        let body = String(id.dropFirst(3))
        let parts = body.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let track = Int(parts[0]) else { return nil }
        let slug = parts.count > 1 ? String(parts[1]) : nil
        return .soundcloud(trackID: track, showSlug: slug?.isEmpty == true ? nil : slug)
    }
}

// MARK: - Mapping

extension Radio80000TermDTO {
    func asGenre() -> Radio80000Genre? {
        let label = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Radio80000Genre(id: slug ?? "\(id ?? 0)", name: label)
    }
}

extension Radio80000ShowDTO {
    func asShow() -> Radio80000Show? {
        guard let identity = slug, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(title?.rendered ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let terms = (_embedded?.term ?? []).flatMap { $0 }
        let genres = terms
            .filter { $0.taxonomy == "genre" }
            .compactMap { $0.name.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let city = terms
            .first { $0.taxonomy == "city" }?
            .name.map(HTMLText.decode)?
            .trimmingCharacters(in: .whitespaces)

        let media = _embedded?.featuredmedia?.first

        return Radio80000Show(
            slug: identity,
            title: name,
            summary: content?.rendered.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            genres: genres,
            city: (city?.nilIfEmpty) ?? cities?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            imageURL: media?.fullURL,
            thumbnailURL: media?.url(atLeast: 400),
            weekday: acf?.weekday?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            time: acf?.time?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            cycle: acf?.cycle?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            links: (acf?.links?.links ?? []).compactMap { link in
                guard let address = link.url, let url = URL(string: address), url.host != nil
                else { return nil }
                let label = HTMLText.decode(link.text ?? "").trimmingCharacters(in: .whitespaces)
                return MediaLink(label: label.isEmpty ? MediaLink.label(for: url) : label, url: url)
            },
            soundcloudPlaylistID: soundcloud_playlist_id?.value,
            mixcloudPlaylist: Radio80000Link.mixcloudPlaylistSlug(acf?.mixcloud_playlist_url)
        )
    }
}

extension Radio80000TrackDTO {
    func asEpisode(showSlug: String? = nil, showTitle: String? = nil) -> Radio80000Episode? {
        guard let identity = id else { return nil }
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        guard let address = permalink_url, let link = Radio80000Link.permalink(address) else {
            return nil
        }

        var tags = Radio80000Tags.parse(tag_list)
        if let genre = genre.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces),
           !genre.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
            tags.insert(genre, at: 0)
        }

        return Radio80000Episode(
            id: Radio80000EpisodeID.soundcloud(trackID: identity, showSlug: showSlug),
            title: name,
            broadcastAt: Radio80000Timestamp.parseSoundCloud(created_at),
            duration: duration.map { TimeInterval($0) / 1000 },
            // SoundCloud's "-large" cut is 100px. The original is what a hero
            // needs, and it is the same address with the size swapped out.
            artworkURL: Radio80000Link.upscaleArtwork(artwork_url),
            permalink: link,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            genres: tags,
            tracks: [],
            showSlug: showSlug,
            showTitle: showTitle ?? Radio80000Title.showName(from: name),
            source: .soundcloud
        )
    }
}

extension MixcloudCloudcastDTO {
    func asRadio80000Episode(showSlug: String? = nil, showTitle: String? = nil) -> Radio80000Episode? {
        guard let identity = key, !identity.isEmpty else { return nil }
        let name = HTMLText.decode(self.name ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let address = url, let link = URL(string: address) else { return nil }

        let tracks = (sections ?? []).enumerated().compactMap { index, section -> Radio80000Track? in
            let title = HTMLText.decode(section.track?.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return Radio80000Track(
                index: index,
                title: title,
                artist: section.track?.artist?.name.map(HTMLText.decode)?
                    .trimmingCharacters(in: .whitespaces).nilIfEmpty,
                offset: section.start_time.map(TimeInterval.init)
            )
        }

        return Radio80000Episode(
            id: Radio80000EpisodeID.mixcloud(key: identity),
            title: name,
            broadcastAt: Radio80000Timestamp.parseISO(created_time),
            duration: audio_length.map(TimeInterval.init),
            artworkURL: artworkURL,
            permalink: link,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            genres: (tags ?? []).compactMap {
                $0.name.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            },
            tracks: tracks,
            showSlug: showSlug,
            showTitle: showTitle ?? Radio80000Title.showName(from: name),
            source: .mixcloud
        )
    }
}

// MARK: - Helpers

nonisolated enum Radio80000Timestamp {
    /// SoundCloud writes "2026/08/07 14:18:05 +0000".
    static func parseSoundCloud(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter.date(from: value)
    }

    /// Mixcloud writes ISO 8601.
    static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

nonisolated enum Radio80000Tags {
    /// SoundCloud writes tags space-separated, quoting the ones with spaces
    /// in them: `ndw "fake reggae" library`.
    static func parse(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        var found: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                if !quoted { found.append(current); current = "" }
                continue
            }
            if character == " ", !quoted {
                if !current.isEmpty { found.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { found.append(current) }
        return found
            .map { HTMLText.decode($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

nonisolated enum Radio80000Title {
    /// Broadcasts are titled "SONIC VACATION w/ heronymus (07/08/26)" — the
    /// show, sometimes a guest, then the date. Only the show is wanted, and
    /// only as a label: it is matched against the real directory rather than
    /// trusted, because a title is not an identifier and this one is typed by
    /// hand every week.
    static func showName(from title: String) -> String? {
        var text = title
        if let range = text.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        for separator in [" w/ ", " W/ ", " with ", " feat. ", " ft. "] {
            if let range = text.range(of: separator) {
                text = String(text[text.startIndex..<range.lowerBound])
                break
            }
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

nonisolated enum Radio80000Link {
    /// SoundCloud appends share tracking to every permalink it hands back; the
    /// widget wants the bare address.
    static func permalink(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              var components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              components.host != nil
        else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// "https://www.mixcloud.com/Radio80K/playlists/all-exhales/" → the path
    /// the API wants, "Radio80K/playlists/all-exhales".
    static func mixcloudPlaylistSlug(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              let components = URLComponents(string: value.trimmingCharacters(in: .whitespaces)),
              let host = components.host, host.contains("mixcloud.com")
        else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    /// SoundCloud names its artwork sizes in the filename, and the one it
    /// hands back — "-large" — is 100 pixels. "-t500x500" is the same image at
    /// a size a page can actually use.
    static func upscaleArtwork(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let upscaled = value.replacingOccurrences(of: "-large.", with: "-t500x500.")
        return URL(string: upscaled) ?? URL(string: value)
    }
}
