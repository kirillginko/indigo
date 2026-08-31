//
//  LYLAPI.swift
//  Indigo
//
//  Transport for LYL Radio. One door: the Strapi GraphQL endpoint at
//  strapi.lyl.live, which is what LYL's own front end reads. Introspection is
//  switched off there, so these queries are written against the selections the
//  site itself asks for.
//

import Foundation

nonisolated enum LYLError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case graphQL(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "LYL Radio returned an unexpected response (\(code))."
        case .malformedResponse:
            "LYL Radio sent something Indigo couldn't read."
        case .graphQL(let message):
            message
        case .transport(let message):
            message
        }
    }
}

nonisolated struct LYLOnAir: Sendable {
    var title: String?
    var streamURL: URL?
}

nonisolated struct LYLShowIndex: Sendable {
    var shows: [LYLShow]
    var studios: [LYLStudio]
    var styles: [LYLStyle]
}

nonisolated struct LYLAPI: Sendable {
    private static let endpoint = URL(string: "https://strapi.lyl.live/graphql")!

    /// LYL's own archive page asks for this many at a time.
    static let pageSize = 24

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Selections

    private static let episodeFields = """
      id: documentId
      title slug artists startAt duration mixcloud soundcloud
      audio { url mime name }
      show { id: documentId slug title }
      description tracks
      styles { id: documentId name }
      image { url alternativeText }
    """

    private static let showFields = """
      id: documentId
      slug title recursion nextBroadcast description artists
      styles { id: documentId name }
      links { type url }
      image { url alternativeText }
    """

    // MARK: - Live

    func fetchOnAir() async throws -> LYLOnAir {
        struct Payload: Decodable, Sendable { let onair: LYLOnAirDTO? }
        let payload: Payload = try await run("{ onair { title hls } }")
        let title = payload.onair?.title.map(HTMLText.decode)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return LYLOnAir(
            title: title,
            streamURL: payload.onair?.hls.flatMap { URL(string: $0) }
        )
    }

    /// The published calendar between two moments. LYL answers with roughly a
    /// slot an hour, so a week is a couple of hundred entries.
    func fetchSchedule(from: Date, to: Date) async throws -> [LYLScheduleEntry] {
        struct Payload: Decodable, Sendable { let calendar: [LYLCalendarEntryDTO]? }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: Payload = try await run(
            """
            query Schedule($after: DateTime!, $before: DateTime!) {
              calendar(from: $after, to: $before) {
                startAt: start
                end
                title
                slug
                artists
                type
              }
            }
            """,
            variables: [
                "after": formatter.string(from: from),
                "before": formatter.string(from: to)
            ]
        )
        return (payload.calendar ?? [])
            .compactMap { $0.asScheduleEntry() }
            .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: - Archive

    func fetchEpisodes(limit: Int = LYLAPI.pageSize, skip: Int = 0) async throws -> [LYLEpisode] {
        struct Payload: Decodable, Sendable { let episodes: [LYLEpisodeDTO]? }
        let payload: Payload = try await run(
            """
            query Episodes($limit: Int!, $skip: Int) {
              episodes(pagination: { limit: $limit, start: $skip }, sort: ["startAt:desc"]) {
            \(Self.episodeFields)
              }
            }
            """,
            variables: ["limit": max(1, limit), "skip": max(0, skip)]
        )
        return (payload.episodes ?? []).compactMap { $0.asEpisode() }
    }

    /// Every episode of one show, newest first.
    func fetchEpisodes(showSlug: String, limit: Int = 100) async throws -> [LYLEpisode] {
        struct Payload: Decodable, Sendable { let episodesByShow: [LYLEpisodeDTO]? }
        let payload: Payload = try await run(
            """
            query EpisodesByShow($show: String!, $limit: Int!) {
              episodesByShow(show: $show, limit: $limit, sort: "startAt:desc") {
            \(Self.episodeFields)
              }
            }
            """,
            variables: ["show": showSlug, "limit": max(1, limit)]
        )
        return (payload.episodesByShow ?? []).compactMap { $0.asEpisode() }
    }

    func fetchEpisode(slug: String) async throws -> LYLEpisode {
        struct Payload: Decodable, Sendable { let episode: LYLEpisodeDTO? }
        let payload: Payload = try await run(
            """
            query Episode($slug: String!) {
              episode: episodeBySlug(slug: $slug) {
            \(Self.episodeFields)
              }
            }
            """,
            variables: ["slug": slug]
        )
        guard let episode = payload.episode?.asEpisode() else { throw LYLError.malformedResponse }
        return episode
    }

    // MARK: - Shows

    /// The shows directory, along with the two lists LYL files them under:
    /// its studios and its two hundred styles.
    func fetchShows(
        limit: Int = 60,
        skip: Int = 0,
        styles: [String] = [],
        studios: [String] = []
    ) async throws -> LYLShowIndex {
        struct Payload: Decodable, Sendable {
            let showsByStyles: [LYLShowDTO]?
            let studios: [LYLStudioDTO]?
            let styles: [LYLStyleDTO]?
        }
        let payload: Payload = try await run(
            """
            query Shows($limit: Int!, $skip: Int, $styles: [String!], $studios: [String!]) {
              showsByStyles(limit: $limit, start: $skip, sort: "title:asc", styles: $styles, studios: $studios) {
            \(Self.showFields)
              }
              studios { id: documentId name city }
              styles(pagination: { limit: 200 }) { id: documentId name }
            }
            """,
            variables: [
                "limit": max(1, limit),
                "skip": max(0, skip),
                "styles": styles,
                "studios": studios
            ]
        )
        return LYLShowIndex(
            shows: (payload.showsByStyles ?? []).compactMap { $0.asShow() },
            studios: (payload.studios ?? []).compactMap { $0.asStudio() },
            styles: (payload.styles ?? []).compactMap { $0.asStyle() }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    func fetchShow(slug: String) async throws -> LYLShow {
        struct Payload: Decodable, Sendable { let show: LYLShowDTO? }
        let payload: Payload = try await run(
            """
            query Show($slug: String!) {
              show: showBySlug(slug: $slug) {
            \(Self.showFields)
              }
            }
            """,
            variables: ["slug": slug]
        )
        guard let show = payload.show?.asShow() else { throw LYLError.malformedResponse }
        return show
    }

    // MARK: - Transport

    private func run<T: Decodable & Sendable>(
        _ query: String,
        variables: [String: Any] = [:]
    ) async throws -> T {
        let body: [String: Any] = ["query": query, "variables": variables]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw LYLError.malformedResponse
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: LYLResponse<T> = try await send(request)
        if let message = payload.errors?.compactMap(\.message).first, payload.data == nil {
            throw LYLError.graphQL(message)
        }
        guard let value = payload.data else { throw LYLError.malformedResponse }
        return value
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw LYLError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw LYLError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LYLError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LYLError.malformedResponse
        }
    }
}
