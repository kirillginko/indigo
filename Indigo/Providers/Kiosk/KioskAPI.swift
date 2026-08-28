//
//  KioskAPI.swift
//  Indigo
//
//  Thin transport layer for kioskradio.com. Kiosk publishes no documented API,
//  so these are the same public endpoints its own site calls, plus one page
//  scrape for the Moods playlists, which have no JSON endpoint at all.
//

import Foundation

nonisolated enum KioskError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "Kiosk Radio returned an unexpected response (\(code))."
        case .malformedResponse:
            "Kiosk Radio sent something Indigo couldn't read."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct KioskAPI: Sendable {
    private static let base = URL(string: "https://www.kioskradio.com/")!

    /// `/api/search` caps every collection; the episode list comes back at 100.
    static let libraryPageSize = 100

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: Endpoints

    /// Roughly the next ten days of programming, oldest first.
    func fetchSchedule() async throws -> [KioskCalendarEntryDTO] {
        try await get("api/calendar")
    }

    /// An empty query is what the site itself sends for an unfiltered browse:
    /// the 100 most recently published shows, newest first.
    func fetchLibrary() async throws -> [KioskEpisodeDTO] {
        let response: KioskSearchResponse = try await get(
            "api/search",
            query: [URLQueryItem(name: "query", value: "")]
        )
        return response.episodeCollection?.items ?? []
    }

    func search(_ query: String) async throws -> KioskSearchResponse {
        try await get("api/search", query: [URLQueryItem(name: "query", value: query)])
    }

    func fetchEpisodePage(slug: String) async throws -> KioskEpisodePageData {
        try await nextData(slug.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func fetchShowPage(slug: String) async throws -> KioskShowPageData {
        try await nextData(slug.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// The Moods playlists are baked into the page at build time. There is no
    /// endpoint for them, so this reads the `__NEXT_DATA__` island the page
    /// already ships for its own hydration rather than parsing any markup.
    func fetchMoods() async throws -> [KioskPlaylistDTO] {
        let html = try await getText("moods")
        guard let json = Self.nextDataPayload(in: html) else { throw KioskError.malformedResponse }
        do {
            return try JSONDecoder().decode(KioskNextData.self, from: Data(json.utf8)).playlists
        } catch {
            throw KioskError.malformedResponse
        }
    }

    /// The JSON between `<script id="__NEXT_DATA__" …>` and its closing tag.
    static func nextDataPayload(in html: String) -> String? {
        guard let idRange = html.range(of: "id=\"__NEXT_DATA__\""),
              let open = html.range(of: ">", range: idRange.upperBound..<html.endIndex),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex)
        else { return nil }
        let payload = html[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await load(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KioskError.malformedResponse
        }
    }

    private func getText(_ path: String, query: [URLQueryItem] = []) async throws -> String {
        let data = try await load(path, query: query, accept: "text/html")
        guard let text = String(data: data, encoding: .utf8) else {
            throw KioskError.malformedResponse
        }
        return text
    }

    private func nextData<T: Decodable>(_ path: String) async throws -> T {
        let html = try await getText(path)
        guard let json = Self.nextDataPayload(in: html) else { throw KioskError.malformedResponse }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw KioskError.malformedResponse
        }
    }

    private func load(
        _ path: String,
        query: [URLQueryItem],
        accept: String = "application/json"
    ) async throws -> Data {
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(path, isDirectory: false),
            resolvingAgainstBaseURL: false
        ) else {
            throw KioskError.malformedResponse
        }
        // An empty `query=` is meaningful here, so the items go on whenever
        // they were asked for — not only when they carry a value.
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw KioskError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw KioskError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw KioskError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KioskError.badStatus(http.statusCode)
        }
        return data
    }
}
