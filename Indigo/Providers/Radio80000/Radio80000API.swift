//
//  Radio80000API.swift
//  Indigo
//
//  Transport for Radio 80000. Three doors, all of them the station's own or
//  open to anyone:
//
//  · Airtime, at radio80k.airtime.pro — `live-info-v2` for what is on the air
//    this second, and `week-info` for the fortnight ahead. The station has no
//    calendar of its own outside Airtime, so this is the schedule.
//  · WordPress, at radio80k.de/wp-json — the shows, their genres and their
//    pictures. Its `/r8/v1/soundcloud/` namespace is the station's own proxy
//    in front of the SoundCloud API, which is why nothing here needs a key.
//  · Mixcloud's public API, for the shows that keep their playlist there
//    instead — a hundred and forty-six of them do.
//

import Foundation

nonisolated enum Radio80000Error: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case notFound
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "Radio 80000 returned an unexpected response (\(code))."
        case .malformedResponse:
            "Radio 80000 sent something Indigo couldn't read."
        case .notFound:
            "Radio 80000 no longer publishes this."
        case .transport(let message):
            message
        }
    }
}

/// A page of broadcasts plus the cursor for the next, when there is one.
nonisolated struct Radio80000EpisodePage: Sendable {
    var episodes: [Radio80000Episode]
    var nextCursor: String?
}

nonisolated struct Radio80000API: Sendable {
    private static let wordpress = URL(string: "https://www.radio80k.de/wp-json/")!
    private static let airtime = URL(string: "https://radio80k.airtime.pro/api/")!
    private static let mixcloud = URL(string: "https://api.mixcloud.com/")!

    /// The station's own SoundCloud account, which its proxy pages by cursor.
    private static let soundcloudUserID = 141_829_514

    static let showPageSize = 100

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    func fetchLive() async throws -> Radio80000Live {
        let info: AirtimeLiveInfoDTO = try await get(
            Self.airtime.appendingPathComponent("live-info-v2")
        )
        let zone = info.timeZone(default: "Europe/Berlin")
        let show = info.shows?.current
        let track = info.tracks?.current

        let onAir = Radio80000OnAir(
            showName: show?.name.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            showSummary: show?.description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            showStartsAt: AirtimeTimestamp.parse(show?.starts, zone: zone),
            showEndsAt: AirtimeTimestamp.parse(show?.ends, zone: zone),
            trackTitle: track?.metadata?.track_title.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty,
            trackArtist: track?.metadata?.artist_name.map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
        return Radio80000Live(onAir: onAir, timeZone: zone)
    }

    /// Airtime's published calendar — this week and the next.
    func fetchSchedule(zone: TimeZone) async throws -> [Radio80000ScheduleEntry] {
        let week: AirtimeWeekInfoDTO = try await get(
            Self.airtime.appendingPathComponent("week-info")
        )
        return week.slots(zone: zone).compactMap { entry in
            let name = HTMLText.decode(entry.slot.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return Radio80000ScheduleEntry(
                id: "\(entry.slot.instance_id ?? entry.slot.id ?? 0)|\(entry.starts.timeIntervalSince1970)",
                title: name,
                summary: entry.slot.description.flatMap(HTMLText.plainText)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                startsAt: entry.starts,
                endsAt: entry.ends
            )
        }
    }

    // MARK: - Latest broadcasts

    /// The station's recent uploads, newest first.
    ///
    /// SoundCloud stops this listing at a hundred however it is asked, so this
    /// is the recent archive rather than the whole of it — the depth is in the
    /// per-show playlists, and the Shows page is the way into those.
    func fetchLatest(cursor: String? = nil) async throws -> Radio80000EpisodePage {
        let url: URL
        if let cursor, !cursor.isEmpty {
            var components = URLComponents(
                url: Self.wordpress.appendingPathComponent(
                    "r8/v1/soundcloud/playlists/users/\(Self.soundcloudUserID)/tracks"
                ),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
            guard let built = components?.url else { throw Radio80000Error.malformedResponse }
            url = built
        } else {
            url = Self.wordpress.appendingPathComponent("r8/v1/soundcloud/me/tracks")
        }

        let page: Radio80000TrackPageDTO = try await get(url)
        return Radio80000EpisodePage(
            episodes: page.collection.compactMap { $0.asEpisode() },
            nextCursor: page.nextCursor
        )
    }

    // MARK: - Shows

    /// The whole directory. A hundred and ninety-three shows is two pages, and
    /// they are asked for with their pictures and terms attached rather than
    /// as a hundred and ninety-three follow-up requests.
    func fetchShows(page: Int = 1) async throws -> [Radio80000Show] {
        var components = URLComponents(
            url: Self.wordpress.appendingPathComponent("wp/v2/show"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: String(Self.showPageSize)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "orderby", value: "title"),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "_embed", value: "1")
        ]
        guard let url = components?.url else { throw Radio80000Error.malformedResponse }
        let shows: [Radio80000ShowDTO] = try await get(url)
        return shows.compactMap { $0.asShow() }
    }

    func fetchShow(slug: String) async throws -> Radio80000Show {
        var components = URLComponents(
            url: Self.wordpress.appendingPathComponent("wp/v2/show"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "_embed", value: "1")
        ]
        guard let url = components?.url else { throw Radio80000Error.malformedResponse }
        let shows: [Radio80000ShowDTO] = try await get(url)
        guard let show = shows.first?.asShow() else { throw Radio80000Error.notFound }
        return show
    }

    /// Every broadcast of one show, newest first.
    ///
    /// A show can have a playlist on either platform or on both. Both are read
    /// and merged, because neither is reliably the complete run: shows that
    /// moved from Mixcloud to SoundCloud have their early years on one and
    /// their recent ones on the other.
    func fetchEpisodes(of show: Radio80000Show) async -> [Radio80000Episode] {
        async let soundcloud = fetchSoundCloudEpisodes(of: show)
        async let mixcloud = fetchMixcloudEpisodes(of: show)
        let (fromSoundCloud, fromMixcloud) = await (soundcloud, mixcloud)
        let merged = fromSoundCloud + fromMixcloud

        var seen = Set<String>()
        return merged
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.broadcastAt ?? .distantPast) > ($1.broadcastAt ?? .distantPast) }
    }

    /// Failures here are absences, not errors: a show with nothing on one
    /// platform is the normal case, and it still has whatever is on the other.
    private func fetchSoundCloudEpisodes(of show: Radio80000Show) async -> [Radio80000Episode] {
        guard let id = await soundcloudPlaylistID(for: show) else { return [] }
        let url = Self.wordpress.appendingPathComponent("r8/v1/soundcloud/playlists/\(id)")
        guard let playlist: Radio80000PlaylistDTO = try? await get(url) else { return [] }
        return (playlist.tracks ?? []).compactMap {
            $0.asEpisode(showSlug: show.slug, showTitle: show.title)
        }
    }

    /// WordPress leaves the playlist id unset on a good many shows that do have
    /// one, so the station's own resolver is asked when the field is empty.
    private func soundcloudPlaylistID(for show: Radio80000Show) async -> Int? {
        if let id = show.soundcloudPlaylistID { return id }
        let url = Self.wordpress.appendingPathComponent("r8/v1/soundcloud/resolve/\(show.slug)")
        guard let resolved: FlexibleInt = try? await get(url) else { return nil }
        return resolved.value
    }

    private func fetchMixcloudEpisodes(of show: Radio80000Show) async -> [Radio80000Episode] {
        guard let playlist = show.mixcloudPlaylist else { return [] }
        var components = URLComponents(
            url: Self.mixcloud.appendingPathComponent("\(playlist)/cloudcasts/"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = components?.url else { return [] }
        guard let page: MixcloudPageDTO = try? await get(url) else { return [] }
        return page.data.compactMap {
            $0.asRadio80000Episode(showSlug: show.slug, showTitle: show.title)
        }
    }

    // MARK: - One broadcast

    /// Fetches a single broadcast from nothing but its id — which is what a
    /// crated episode opened months later has.
    func fetchEpisode(id: String) async throws -> Radio80000Episode {
        switch Radio80000EpisodeID.parse(id) {
        case .mixcloud(let key):
            // Mixcloud keys are a path, so this is a direct read — and the
            // detail response is also the only place the tracklist appears.
            let url = Self.mixcloud.appendingPathComponent(key)
            let dto: MixcloudCloudcastDTO = try await get(url)
            guard let episode = dto.asRadio80000Episode() else {
                throw Radio80000Error.notFound
            }
            return episode

        case .soundcloud(let trackID, let showSlug):
            // The proxy publishes no per-track route, so the track is found in
            // the run it belongs to — or, failing that, in the recent uploads.
            if let showSlug {
                let show = try? await fetchShow(slug: showSlug)
                if let show {
                    let episodes = await fetchSoundCloudEpisodes(of: show)
                    if let match = episodes.first(where: { $0.id.hasPrefix("sc:\(trackID)") }) {
                        return match
                    }
                }
            }
            let latest = try await fetchLatest()
            if let match = latest.episodes.first(where: { $0.id.hasPrefix("sc:\(trackID)") }) {
                return match
            }
            throw Radio80000Error.notFound

        case nil:
            throw Radio80000Error.notFound
        }
    }

    /// Mixcloud carries the tracklist only on a single cloudcast, never in a
    /// listing — so an episode opened from a grid is topped up here.
    func fetchTracklist(id: String) async throws -> [Radio80000Track] {
        guard case .mixcloud(let key) = Radio80000EpisodeID.parse(id) else { return [] }
        let dto: MixcloudCloudcastDTO = try await get(Self.mixcloud.appendingPathComponent(key))
        return dto.asRadio80000Episode()?.tracks ?? []
    }

    // MARK: - Genres

    /// The station's genre vocabulary — a hundred and seventy-five terms,
    /// asked once and kept.
    func fetchGenres() async throws -> [Radio80000Genre] {
        var components = URLComponents(
            url: Self.wordpress.appendingPathComponent("wp/v2/genre"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "orderby", value: "name"),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "hide_empty", value: "true")
        ]
        guard let first = components?.url else { throw Radio80000Error.malformedResponse }
        components?.queryItems?.append(URLQueryItem(name: "page", value: "2"))
        guard let second = components?.url else { throw Radio80000Error.malformedResponse }

        let one: [Radio80000TermDTO] = try await get(first)
        // WordPress caps a page at a hundred and answers 400 past the last
        // page rather than an empty list, so the second is allowed to fail.
        let two: [Radio80000TermDTO] = (try? await get(second)) ?? []

        var seen = Set<String>()
        return (one + two)
            .compactMap { $0.asGenre() }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Transport

    private func get<T: Decodable & Sendable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw Radio80000Error.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw Radio80000Error.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404
                ? Radio80000Error.notFound
                : Radio80000Error.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Radio80000Error.malformedResponse
        }
    }
}
