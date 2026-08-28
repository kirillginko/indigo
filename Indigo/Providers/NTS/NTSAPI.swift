//
//  NTSAPI.swift
//  Indigo
//
//  Thin transport layer. Knows about endpoints and status codes, nothing else.
//

import Foundation

nonisolated enum NTSError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "NTS returned an unexpected response (\(code))."
        case .malformedResponse:
            "NTS sent something Indigo couldn't read."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct NTSAPI: Sendable {
    private static let base = URL(string: "https://www.nts.live/api/v2/")!

    /// Every list endpoint pages at 12 regardless of the limit you ask for.
    static let pageSize = 12
    /// Search, unlike the list endpoints, honours `limit`.
    static let searchPageSize = 36

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: Endpoints

    func fetchLive() async throws -> NTSLiveResponse {
        try await get("live")
    }

    func fetchShows(offset: Int) async throws -> NTSPage<NTSShowDTO> {
        try await get("shows", query: pageQuery(offset: offset))
    }

    func fetchEpisodes(showAlias: String, offset: Int) async throws -> NTSPage<NTSEpisodeDTO> {
        try await get("shows/\(escape(showAlias))/episodes", query: pageQuery(offset: offset))
    }

    func fetchEpisode(showAlias: String, episodeAlias: String) async throws -> NTSEpisodeDTO {
        try await get("shows/\(escape(showAlias))/episodes/\(escape(episodeAlias))")
    }

    func fetchCollection(_ slug: String, offset: Int) async throws -> NTSPage<NTSEpisodeDTO> {
        try await get("collections/\(slug)", query: pageQuery(offset: offset))
    }

    func fetchMixtapes() async throws -> NTSPage<NTSMixtapeDTO> {
        try await get("mixtapes")
    }

    /// `version=2` is required — the default (v1) answers every query with an
    /// empty result set.
    func search(
        query: String,
        scope: NTSSearchScope,
        offset: Int
    ) async throws -> NTSSearchResponse {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "limit", value: String(Self.searchPageSize))
        ]
        if let types = scope.queryValue {
            items.append(URLQueryItem(name: "types", value: types))
        }
        return try await get("search", query: items)
    }

    // MARK: Transport

    private func pageQuery(offset: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "offset", value: String(max(0, offset))),
            URLQueryItem(name: "limit", value: String(Self.pageSize))
        ]
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(path, isDirectory: false),
            resolvingAgainstBaseURL: false
        ) else {
            throw NTSError.malformedResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NTSError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw NTSError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw NTSError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NTSError.badStatus(http.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw NTSError.malformedResponse
        }
    }
}
