//
//  IdaAPI.swift
//  Indigo
//
//  Transport for IDA Radio. One door: the Strapi REST API at
//  strapi.idaidaida.net, which is what IDA's own front end reads and which the
//  station leaves open — no key, and the records come back flattened.
//
//  Strapi takes its filters, sorting and relations as nested query parameters
//  in the `qs` style ("filters[start][$lte]=…"), so the awkward part of this
//  file is building those honestly rather than by string concatenation. The
//  `populate` selections are deliberately narrow: asking for everything drags
//  seven derived sizes of a 3000px JPEG through every listing, which measured
//  three times the bytes of asking for the fields actually rendered.
//

import Foundation

nonisolated enum IdaError: LocalizedError, Equatable {
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
            "IDA Radio returned an unexpected response (\(code))."
        case .malformedResponse:
            "IDA Radio sent something Indigo couldn't read."
        case .notFound:
            "IDA Radio no longer publishes this."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct IdaAPI: Sendable {
    private static let base = URL(string: "https://strapi.idaidaida.net/api/")!

    /// What IDA's own archive page asks for at a time.
    static let pageSize = 24
    static let showPageSize = 48

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Selections

    /// The episode fields Indigo renders, and nothing else.
    private static let episodeFields = [
        "title", "slug", "subtitle", "start", "end", "mixcloud", "soundcloud", "isRepeat"
    ]

    private static let showFields = [
        "title", "slug", "artist", "alternativeArtistName",
        "contentEng", "contentEst", "contentFin", "archived"
    ]

    /// Relations shared by every episode listing. The show's own picture comes
    /// along because most episodes have none of their own and inherit it.
    private static func episodeRelations(includeTracklist: Bool = false) -> [URLQueryItem] {
        var items = fields(Self.episodeFields + (includeTracklist ? ["tracklist"] : []))
        items += populate("show", fields: ["slug", "title", "artist", "alternativeArtistName"])
        items += populateMedia("show", relation: "featuredImage")
        items += populate("genres", fields: ["title", "slug"])
        items += populate("channel", fields: ["slug", "title"])
        items += populateMedia(nil, relation: "featuredImage")
        return items
    }

    // MARK: - Live

    /// What is on both channels right now, what follows, and the two stream
    /// addresses. This is the only place IDA publishes the streams.
    func fetchLive() async throws -> IdaLive {
        let response: IdaSingleResponse<IdaLiveDTO> = try await get("live")
        guard let payload = response.data else { throw IdaError.malformedResponse }
        return payload.asLive()
    }

    // MARK: - Schedule

    /// The calendar between two moments, across both channels. IDA's schedule
    /// is simply its episodes with their broadcast times — there is no
    /// separate schedule resource.
    func fetchSchedule(from: Date, to: Date) async throws -> [IdaScheduleEntry] {
        var query = [
            URLQueryItem(name: "filters[start][$gte]", value: IdaTimestamp.format(from)),
            URLQueryItem(name: "filters[start][$lte]", value: IdaTimestamp.format(to)),
            URLQueryItem(name: "sort", value: "start:asc"),
            URLQueryItem(name: "pagination[limit]", value: "200")
        ]
        query += Self.episodeRelations()
        let response: IdaListResponse<IdaEpisodeDTO> = try await get("episodes", query: query)
        return response.data
            .compactMap { $0.asScheduleEntry() }
            .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: - Archive

    /// The archive, newest first — only episodes with a recording behind them.
    /// IDA schedules further ahead than it broadcasts, so an unfiltered listing
    /// opens on next week's empty slots.
    func fetchEpisodes(
        limit: Int = IdaAPI.pageSize,
        skip: Int = 0,
        genres: Set<String> = []
    ) async throws -> [IdaEpisode] {
        var query = [
            URLQueryItem(name: "sort", value: "start:desc"),
            URLQueryItem(name: "pagination[limit]", value: String(max(1, limit))),
            URLQueryItem(name: "pagination[start]", value: String(max(0, skip))),
            URLQueryItem(name: "filters[$or][0][mixcloud][$notNull]", value: "true"),
            URLQueryItem(name: "filters[$or][1][soundcloud][$notNull]", value: "true")
        ]
        query += Self.genreFilter(genres)
        query += Self.episodeRelations()
        let response: IdaListResponse<IdaEpisodeDTO> = try await get("episodes", query: query)
        return response.data.compactMap { $0.asEpisode() }
    }

    /// Every episode of one show, newest first.
    func fetchEpisodes(showSlug: String, limit: Int = 100) async throws -> [IdaEpisode] {
        var query = [
            URLQueryItem(name: "filters[show][slug][$eq]", value: showSlug),
            URLQueryItem(name: "sort", value: "start:desc"),
            URLQueryItem(name: "pagination[limit]", value: String(max(1, limit)))
        ]
        query += Self.episodeRelations()
        let response: IdaListResponse<IdaEpisodeDTO> = try await get("episodes", query: query)
        return response.data.compactMap { $0.asEpisode() }
    }

    /// One episode, with the tracklist — which the listings deliberately skip,
    /// because a page of them is a great deal of prose nobody is reading yet.
    func fetchEpisode(slug: String) async throws -> IdaEpisode {
        var query = [
            URLQueryItem(name: "filters[slug][$eq]", value: slug),
            URLQueryItem(name: "pagination[limit]", value: "1")
        ]
        query += Self.episodeRelations(includeTracklist: true)
        let response: IdaListResponse<IdaEpisodeDTO> = try await get("episodes", query: query)
        guard let episode = response.data.first?.asEpisode() else { throw IdaError.notFound }
        return episode
    }

    // MARK: - Shows

    func fetchShows(
        limit: Int = IdaAPI.showPageSize,
        skip: Int = 0,
        genres: Set<String> = []
    ) async throws -> [IdaShow] {
        var query = [
            URLQueryItem(name: "sort", value: "title:asc"),
            URLQueryItem(name: "pagination[limit]", value: String(max(1, limit))),
            URLQueryItem(name: "pagination[start]", value: String(max(0, skip)))
        ]
        query += Self.genreFilter(genres)
        query += Self.showRelations()
        let response: IdaListResponse<IdaShowDTO> = try await get("shows", query: query)
        return response.data.compactMap { $0.asShow() }
    }

    func fetchShow(slug: String) async throws -> IdaShow {
        var query = [
            URLQueryItem(name: "filters[slug][$eq]", value: slug),
            URLQueryItem(name: "pagination[limit]", value: "1")
        ]
        query += Self.showRelations()
        let response: IdaListResponse<IdaShowDTO> = try await get("shows", query: query)
        guard let show = response.data.first?.asShow() else { throw IdaError.notFound }
        return show
    }

    private static func showRelations() -> [URLQueryItem] {
        var items = fields(Self.showFields)
        items += populate("genres", fields: ["title", "slug"])
        items += populate("channel", fields: ["slug", "title"])
        items += populateMedia(nil, relation: "featuredImage")
        return items
    }

    // MARK: - Genres

    /// IDA's whole tag vocabulary — 560 of them, asked once and kept.
    ///
    /// The limit has to clear that comfortably: Strapi truncates silently, and
    /// at 500 the menu simply stopped partway through the T's with no sign
    /// anything was missing. The station also files the same tag twice under
    /// different capitalisation, and sorts capitals before lowercase, which
    /// would strand a run of genres at the bottom of the menu — so the list is
    /// folded and ordered here rather than as it arrives.
    func fetchGenres() async throws -> [IdaGenre] {
        let query = [
            URLQueryItem(name: "sort", value: "title:asc"),
            URLQueryItem(name: "pagination[limit]", value: "1000"),
            URLQueryItem(name: "fields[0]", value: "title"),
            URLQueryItem(name: "fields[1]", value: "slug")
        ]
        let response: IdaListResponse<IdaGenreDTO> = try await get("genres", query: query)
        var seen = Set<String>()
        return response.data
            .compactMap { $0.asGenre() }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Query building

    /// Narrowing by tag, inclusively: picking Ambient and Techno asks for
    /// either, which is what the shared genre bar means by a multi-select.
    /// `$in` is what makes that one request rather than one per tag.
    ///
    /// Sorted so the same selection always builds the same URL, which is what
    /// lets a cache — ours or anyone's in between — recognise it.
    private static func genreFilter(_ genres: Set<String>) -> [URLQueryItem] {
        genres
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
            .enumerated()
            .map { URLQueryItem(name: "filters[genres][title][$in][\($0.offset)]", value: $0.element) }
    }

    /// `fields[0]=title&fields[1]=slug` — Strapi wants them indexed.
    private static func fields(_ names: [String]) -> [URLQueryItem] {
        names.enumerated().map { URLQueryItem(name: "fields[\($0.offset)]", value: $0.element) }
    }

    /// `populate[show][fields][0]=slug`, and the nested form for a relation of
    /// a relation.
    private static func populate(
        _ relation: String,
        of parent: String? = nil,
        fields names: [String]
    ) -> [URLQueryItem] {
        let prefix = parent.map { "populate[\($0)][populate][\(relation)]" } ?? "populate[\(relation)]"
        return names.enumerated().map {
            URLQueryItem(name: "\(prefix)[fields][\($0.offset)]", value: $0.element)
        }
    }

    /// A media relation, asked for as its address plus the derived sizes —
    /// so a grid can pull a 400px thumbnail instead of the original upload.
    private static func populateMedia(_ parent: String?, relation: String) -> [URLQueryItem] {
        populate(relation, of: parent, fields: ["url", "formats"])
    }

    // MARK: - Transport

    private func get<T: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw IdaError.malformedResponse }

        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw IdaError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw IdaError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw IdaError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404 ? IdaError.notFound : IdaError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IdaError.malformedResponse
        }
    }
}
