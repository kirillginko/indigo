//
//  DiscogsClient.swift
//  Indigo
//
//  Fast catalogue enrichment for DIG. Credentials belong to Indigo's build
//  configuration (and ultimately its backend), never to the listener.
//

import Foundation

nonisolated enum DiscogsError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case rateLimited
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add a Discogs personal access token in Indigo Settings to enable fast DIG enrichment."
        case .offline: "Discogs is unavailable while offline."
        case .rateLimited: "Discogs is busy. Indigo will use its cached data."
        case .badStatus(let code): "Discogs returned an unexpected response (\(code))."
        case .malformedResponse: "Discogs sent something Indigo couldn't read."
        case .transport(let detail): detail
        }
    }
}

protocol DiscogsTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DiscogsTransport {}

nonisolated enum DiscogsConfiguration {
    static var token: String? {
        if let value = ProcessInfo.processInfo.environment["DISCOGS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty { return value }
        // Unit tests opt into Discogs with an injected client. Never let a
        // developer's packaged credential turn fixture tests into live calls.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        guard let bundled = Bundle.main.object(forInfoDictionaryKey: "IndigoDiscogsToken") as? String else {
            return nil
        }
        let value = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}

nonisolated struct DiscogsClient: Sendable {
    private let transport: DiscogsTransport
    private let suppliedToken: String?

    init() {
        transport = NetworkEnvironment.metadataSession
        suppliedToken = nil
    }

    init(transport: DiscogsTransport, token: String) {
        self.transport = transport
        suppliedToken = token
    }

    var isConfigured: Bool { token != nil }

    func artist(named name: String) async throws -> DiscogsArtistBundle? {
        let search: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        guard let match = Self.bestArtistMatch(name: name, results: search.results ?? []),
              let id = match.id else { return nil }

        async let detail: DiscogsArtistDetail = get("artists/\(id)")
        async let releases: DiscogsArtistReleases = get("artists/\(id)/releases", query: [
            URLQueryItem(name: "sort", value: "year"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "per_page", value: "50")
        ])
        async let catalogue: DiscogsSearchResponse = get("database/search", query: [
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "25")
        ])
        return try await DiscogsArtistBundle(
            detail: detail,
            releases: releases,
            searchImageURL: match.coverImage,
            catalogue: catalogue.results ?? []
        )
    }

    /// Just a picture of an artist, in one request.
    ///
    /// The full `artist(named:)` bundle is four requests and fetches a
    /// discography nobody asked for. When all that is wanted is a thumbnail
    /// for a row, this is a quarter of the cost — which is what makes filling
    /// in a page of forty neighbours possible at all.
    func artistThumbnail(named name: String) async throws -> String? {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "type", value: "artist"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        guard let match = Self.bestArtistMatch(name: name, results: response.results ?? [])
        else { return nil }
        return match.thumbnail ?? match.coverImage
    }

    func release(id: Int) async throws -> DiscogsReleaseDetail {
        try await get("releases/\(id)")
    }

    func releaseID(title: String, artist: String) async throws -> Int? {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "release_title", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        let wanted = Self.normalized(title)
        return response.results?.first(where: {
            let resultTitle = $0.title.split(separator: " - ", maxSplits: 1).last.map(String.init) ?? $0.title
            return Self.normalized(resultTitle) == wanted
        })?.id ?? response.results?.first?.id
    }

    /// The release a *track* appears on.
    ///
    /// The route that actually matters for radio music. A tracklist gives you
    /// a song, and a song is almost never the name of a record — so searching
    /// for a release called "Rev8617" finds nothing, while asking which
    /// release contains a track called "Rev8617" returns Compro, which is the
    /// album the listener heard a piece of.
    ///
    /// Ordered results are left in Discogs' own relevance order and the
    /// earliest pressing wins ties, so a track resolves to the record it came
    /// out on rather than to a later compilation that also carries it.
    func releaseID(track: String, artist: String) async throws -> Int? {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "track", value: track),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "5")
        ])
        guard let results = response.results, !results.isEmpty else { return nil }
        let earliest = results
            .filter { ($0.year.flatMap(Int.init) ?? 0) > 0 }
            .min { ($0.year.flatMap(Int.init) ?? 0) < ($1.year.flatMap(Int.init) ?? 0) }
        return earliest?.id ?? results.first?.id
    }

    func labelCatalogue(named name: String) async throws -> [DiscogsSearchResult] {
        let response: DiscogsSearchResponse = try await get("database/search", query: [
            URLQueryItem(name: "label", value: name),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "50")
        ])
        return response.results ?? []
    }

    /// Two bounded searches expand the graph without issuing one request per
    /// recommendation. Results are cached on the artist by DiscogsEnricher.
    func recommendations(labels: [String], styles: [String]) async throws -> DiscogsRecommendationBundle {
        async let labelResults: DiscogsSearchResponse = recommendationSearch(field: "label", value: labels.first)
        async let styleResults: DiscogsSearchResponse = recommendationSearch(field: "style", value: styles.first)
        let (labelsResponse, stylesResponse) = try await (labelResults, styleResults)
        return DiscogsRecommendationBundle(
            labelArtists: Self.neighbours(from: labelsResponse.results ?? []),
            styleArtists: Self.neighbours(from: stylesResponse.results ?? [])
        )
    }

    private func recommendationSearch(field: String, value: String?) async throws -> DiscogsSearchResponse {
        guard let value, !value.isEmpty else { return DiscogsSearchResponse(results: []) }
        return try await get("database/search", query: [
            URLQueryItem(name: field, value: value),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "20")
        ])
    }

    /// Discogs writes a release result as "Artist - Title" and includes a
    /// thumbnail with it. Both halves are worth keeping: the name is the
    /// connection and the thumbnail is the only picture of these artists that
    /// can be had without a request each.
    static func neighbours(from results: [DiscogsSearchResult]) -> [DiscogsNeighbour] {
        var seen = Set<String>()
        return results.compactMap { result in
            guard let separator = result.title.range(of: " - ") else { return nil }
            let artist = String(result.title[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let key = RecordingKey.normalizeArtist(artist)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            // The small cut. A 38-point row has no use for a 600-pixel sleeve.
            return DiscogsNeighbour(name: artist, thumbnailURL: result.thumbnail ?? result.coverImage)
        }
    }

    static func artistNames(from results: [DiscogsSearchResult]) -> [String] {
        neighbours(from: results).map(\.name)
    }

    static func bestArtistMatch(name: String, results: [DiscogsSearchResult]) -> DiscogsSearchResult? {
        let wanted = RecordingKey.normalizeArtist(name)
        return results.first { RecordingKey.normalizeArtist($0.title) == wanted } ?? results.first
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private var token: String? {
        let value = suppliedToken ?? DiscogsConfiguration.token
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let token else { throw DiscogsError.notConfigured }
        var components = URLComponents(string: "https://api.discogs.com/\(path)")
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw DiscogsError.malformedResponse }
        var request = URLRequest(url: url)
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.discogs.v2.discogs+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            if error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                throw DiscogsError.offline
            }
            throw DiscogsError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DiscogsError.malformedResponse }
        if http.statusCode == 429 { throw DiscogsError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw DiscogsError.badStatus(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DiscogsError.malformedResponse
        }
    }
}
