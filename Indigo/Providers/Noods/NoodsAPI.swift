//
//  NoodsAPI.swift
//  Indigo
//
//  Noods runs a Kirby CMS that serves a JSON representation of every page:
//  append `.json` to any route on panel.noodsradio.com. Public, unauthenticated
//  and stable, which makes it the cleanest of the three stations to read.
//
//  Their client bundle also ships a RadioCult secret key. It is deliberately
//  not used here — it is Noods' credential, not ours, and nothing in the app
//  needs it.
//

import Foundation

nonisolated enum NoodsError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline: "No internet connection."
        case .badStatus(404): "Noods has nothing at that address."
        case .badStatus(let code): "Noods Radio returned an unexpected response (\(code))."
        case .malformedResponse: "Noods Radio sent something Indigo couldn't read."
        case .transport(let message): message
        }
    }
}

nonisolated struct NoodsAPI: Sendable {
    private static let base = URL(string: "https://panel.noodsradio.com/")!

    /// The feeds page at 18 a time; the filter at 24.
    static let feedPageSize = 18
    static let filterPageSize = 24

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: Shows

    /// The Discover landing page: two curated lists rather than a feed.
    func fetchDiscover() async throws -> NoodsDiscoverDTO {
        try await get("shows")
    }

    /// Featured / Latest / Guests all share one shape.
    func fetchFeed(_ feed: NoodsFeed, page: Int) async throws -> NoodsFeedDTO {
        try await get("shows/\(feed.rawValue)", query: pageQuery(page))
    }

    func fetchShow(slug: String) async throws -> NoodsShowDetailDTO {
        try await get("shows/\(escape(slug))")
    }

    // MARK: Filter

    func fetchGenres() async throws -> [NoodsGenreDTO] {
        try await get("genres")
    }

    /// Repeated `genres[]` values are ORed by the server. With none selected
    /// the endpoint answers in a different shape entirely, so callers should
    /// pass at least one.
    func filter(genres: [String], page: Int) async throws -> NoodsFilterDTO {
        var items = genres.map { URLQueryItem(name: "genres[]", value: $0) }
        items.append(contentsOf: pageQuery(page))
        return try await get("shows/filter", query: items)
    }

    // MARK: Residents

    func fetchResidents() async throws -> NoodsResidentsDTO {
        try await get("residents")
    }

    func fetchResident(slug: String, page: Int) async throws -> NoodsResidentDTO {
        try await get("residents/\(escape(slug))", query: pageQuery(page))
    }

    // MARK: Collections

    func fetchCollections() async throws -> NoodsCollectionsDTO {
        try await get("collections")
    }

    func fetchCollection(slug: String) async throws -> NoodsCollectionDTO {
        try await get("collections/\(escape(slug))")
    }

    // MARK: Transport

    private func pageQuery(_ page: Int) -> [URLQueryItem] {
        page > 1 ? [URLQueryItem(name: "page", value: String(page))] : []
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent("\(path).json", isDirectory: false),
            resolvingAgainstBaseURL: false
        ) else { throw NoodsError.malformedResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NoodsError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw NoodsError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw NoodsError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NoodsError.badStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NoodsError.malformedResponse
        }
    }
}

/// The three paged feeds under /shows.
nonisolated enum NoodsFeed: String, CaseIterable, Hashable, Sendable {
    case featured
    case latest
    case guests

    var title: String {
        switch self {
        case .featured: "Featured"
        case .latest: "Latest"
        case .guests: "Guests"
        }
    }
}
