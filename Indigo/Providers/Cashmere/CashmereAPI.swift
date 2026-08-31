//
//  CashmereAPI.swift
//  Indigo
//
//  Transport for Cashmere Radio. Two doors, both the station's own:
//
//  · backstage.cashmereradio.com/graphql — the WPGraphQL endpoint Cashmere's
//    own front end reads. It pages by cursor, filters by category and searches
//    the whole archive. Introspection is off, so these queries are written
//    against the shape the site itself asks for.
//  · cashmereradio.airtime.pro — Airtime's live-info, for what is on the air
//    this second and what follows it.
//
//  The recordings themselves live on Mixcloud and play through its widget.
//

import Foundation

nonisolated enum CashmereError: LocalizedError, Equatable {
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
            "Cashmere Radio returned an unexpected response (\(code))."
        case .malformedResponse:
            "Cashmere Radio sent something Indigo couldn't read."
        case .graphQL(let message):
            message
        case .transport(let message):
            message
        }
    }
}

nonisolated struct CashmereEpisodePage: Sendable {
    var episodes: [CashmereEpisode]
    var cursor: String?
    var hasMore: Bool
}

nonisolated struct CashmereLive: Sendable {
    var onAir: CashmereOnAir
    var timeZone: TimeZone
}

nonisolated struct CashmereAPI: Sendable {
    private static let graphQL = URL(string: "https://backstage.cashmereradio.com/graphql")!
    private static let airtime = URL(string: "https://cashmereradio.airtime.pro/api/live-info-v2")!

    /// Cashmere's own archive page asks for this many at a time.
    static let pageSize = 24

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    func fetchLive() async throws -> CashmereLive {
        let info: AirtimeLiveInfoDTO = try await decode(url: Self.airtime)
        let zone = info.timeZone(default: "Europe/Berlin")

        let show = info.shows?.current
        let track = info.tracks?.current
        let upcoming = (info.shows?.next ?? []).compactMap { next -> CashmereSlot? in
            guard let start = AirtimeTimestamp.parse(next.starts, zone: zone),
                  let end = AirtimeTimestamp.parse(next.ends, zone: zone),
                  end > start
            else { return nil }
            let name = HTMLText.decode(next.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return CashmereSlot(
                id: "\(name)|\(start.timeIntervalSince1970)",
                title: name,
                showSlug: Self.showSlug(from: next.url),
                startsAt: start,
                endsAt: end
            )
        }

        let onAir = CashmereOnAir(
            showName: show?.name.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            showStartsAt: AirtimeTimestamp.parse(show?.starts, zone: zone),
            showEndsAt: AirtimeTimestamp.parse(show?.ends, zone: zone),
            showSlug: Self.showSlug(from: show?.url),
            trackTitle: track?.metadata?.track_title.map(HTMLText.decode)
                .flatMap { $0.isEmpty ? nil : $0 },
            trackArtist: track?.metadata?.artist_name.map(HTMLText.decode)
                .flatMap { $0.isEmpty ? nil : $0 },
            upNext: upcoming
        )
        return CashmereLive(onAir: onAir, timeZone: zone)
    }

    /// Airtime carries a link to the show's page on Cashmere's own site, which
    /// is the only thing tying what is on the air to what is in the archive.
    private static func showSlug(from url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "shows"), index + 1 < parts.count else { return nil }
        return parts[index + 1]
    }

    // MARK: - Archive

    private static let episodeFields = """
    databaseId slug title uri dateGmt
    acf { episodeDate episodeMixcloudLink episodeFilterGenre episodeFilterMood episodeFilterFocuseddiverse }
    categories { edges { node { databaseId name slug count } } }
    featuredImage { node { sourceUrl altText srcSet } }
    """

    func fetchEpisodes(
        first: Int = CashmereAPI.pageSize,
        after: String? = nil,
        search: String? = nil,
        showSlug: String? = nil
    ) async throws -> CashmereEpisodePage {
        // GraphQL rejects an operation that declares a variable it never
        // uses, so the signature and the filter have to be built together.
        var declarations = ["$first: Int!", "$after: String"]
        var conditions: [String] = []
        var variables: [String: Any] = ["first": min(max(1, first), 100)]
        if let after, !after.isEmpty { variables["after"] = after }
        if let search, !search.isEmpty {
            declarations.append("$search: String")
            conditions.append("search: $search")
            variables["search"] = search
        }
        if let showSlug, !showSlug.isEmpty {
            declarations.append("$categoryName: String")
            conditions.append("categoryName: $categoryName")
            variables["categoryName"] = showSlug
        }
        let filter = conditions.isEmpty ? "" : ", where: { \(conditions.joined(separator: ", ")) }"

        let query = """
        query Episodes(\(declarations.joined(separator: ", "))) {
          episodes(first: $first, after: $after\(filter)) {
            pageInfo { hasNextPage endCursor }
            edges { node { \(Self.episodeFields) } }
          }
        }
        """

        struct Payload: Decodable, Sendable {
            let episodes: CashmereConnection<CashmereEpisodeDTO>?
        }
        let payload: Payload = try await run(query, variables: variables)
        guard let connection = payload.episodes else { throw CashmereError.malformedResponse }

        return CashmereEpisodePage(
            episodes: connection.nodes.compactMap { $0.asEpisode() },
            cursor: connection.pageInfo?.endCursor,
            hasMore: connection.pageInfo?.hasNextPage ?? false
        )
    }

    /// One episode, with the prose the listing leaves out.
    func fetchEpisode(slug: String) async throws -> CashmereEpisode {
        let query = """
        query Episode($slug: String!) {
          episodeBy(slug: $slug) { \(Self.episodeFields) content }
        }
        """
        struct Payload: Decodable, Sendable {
            let episodeBy: CashmereEpisodeDTO?
        }
        let payload: Payload = try await run(query, variables: ["slug": slug])
        guard let episode = payload.episodeBy?.asEpisode() else { throw CashmereError.malformedResponse }
        return episode
    }

    // MARK: - Shows

    /// Cashmere files its recurring shows as WordPress categories, so the
    /// directory is the category list with its episode counts.
    func fetchShows(first: Int = 100, after: String? = nil) async throws -> (shows: [CashmereShow], cursor: String?, hasMore: Bool) {
        let query = """
        query Shows($first: Int!, $after: String) {
          categories(first: $first, after: $after, where: { hideEmpty: true, orderby: NAME }) {
            pageInfo { hasNextPage endCursor }
            edges { node { databaseId name slug count } }
          }
        }
        """
        struct Payload: Decodable, Sendable {
            let categories: CashmereConnection<CategoryDTO>?
        }
        var variables: [String: Any] = ["first": min(max(1, first), 100)]
        if let after, !after.isEmpty { variables["after"] = after }
        let payload: Payload = try await run(query, variables: variables)
        guard let connection = payload.categories else { throw CashmereError.malformedResponse }
        return (
            connection.nodes.compactMap { $0.asShow() },
            connection.pageInfo?.endCursor,
            connection.pageInfo?.hasNextPage ?? false
        )
    }

    // MARK: - Streams

    /// The station manages its channels as entries too, so the stream
    /// addresses come from Cashmere rather than being pinned here.
    func fetchStreams() async throws -> [CashmereStream] {
        let query = """
        { streams(first: 20) { edges { node { databaseId title slug acf { mp3Stream } } } } }
        """
        struct Payload: Decodable, Sendable {
            let streams: CashmereConnection<CashmereStreamDTO>?
        }
        let payload: Payload = try await run(query)
        return payload.streams?.nodes.compactMap { $0.asStream() } ?? []
    }

    // MARK: - Transport

    private func run<T: Decodable & Sendable>(
        _ query: String,
        variables: [String: Any] = [:]
    ) async throws -> T {
        // A nil variable and an absent one mean the same thing to GraphQL, and
        // JSONSerialization will not encode `Any` holding nil.
        let cleaned = variables.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            if case Optional<Any>.none = value { return nil }
            return value
        }
        let body: [String: Any] = ["query": query, "variables": cleaned]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw CashmereError.malformedResponse
        }

        var request = URLRequest(url: Self.graphQL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: CashmereResponse<T> = try await decode(request: request)
        if let message = response.errors?.compactMap(\.message).first, response.data == nil {
            throw CashmereError.graphQL(message)
        }
        guard let payload = response.data else { throw CashmereError.malformedResponse }
        return payload
    }

    private func decode<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await decode(request: request)
    }

    private func decode<T: Decodable>(request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw CashmereError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw CashmereError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CashmereError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CashmereError.malformedResponse
        }
    }
}
