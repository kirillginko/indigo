//
//  MusicBrainzClient.swift
//  Indigo
//
//  MusicBrainz is a volunteer-run public database with a documented one
//  request per second ceiling and a requirement to identify yourself. Both are
//  honoured here rather than being someone else's problem: the gate is an
//  actor, so concurrent callers queue instead of racing.
//

import Foundation

nonisolated enum MusicBrainzError: LocalizedError, Equatable {
    case offline
    case rateLimited
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline: "No internet connection."
        case .rateLimited: "MusicBrainz is busy. Indigo will try again shortly."
        case .badStatus(let code): "MusicBrainz returned an unexpected response (\(code))."
        case .malformedResponse: "MusicBrainz sent something Indigo couldn't read."
        case .transport(let message): message
        }
    }
}

/// Anything that can answer a MusicBrainz request. Exists so the client can be
/// tested without touching the real service — hammering a volunteer-run
/// database from a test suite would be rude as well as slow.
protocol MusicBrainzTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: MusicBrainzTransport {}

/// Serialises requests and holds them at least `interval` apart.
actor RateGate {
    private var nextAllowed = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func wait() async {
        let now = Date()
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

/// Once the public service rejects a request, fail optional enrichment fast
/// for a short window instead of building a long queue of doomed requests.
actor MusicBrainzCircuitBreaker {
    private var retryAfter = Date.distantPast

    func permitsRequest() -> Bool { Date() >= retryAfter }

    func trip(for interval: TimeInterval = 30) {
        retryAfter = max(retryAfter, Date().addingTimeInterval(interval))
    }
}

nonisolated struct MusicBrainzClient: Sendable {
    private static let base = URL(string: "https://musicbrainz.org/ws/2/")!
    /// Their published ceiling is one per second; the margin keeps a burst of
    /// enrichments from tripping it.
    private static let gate = RateGate(interval: 1.1)
    private static let circuit = MusicBrainzCircuitBreaker()

    /// Observed behaviour, not documentation: when MusicBrainz decides you are
    /// asking too often it stops answering rather than returning 503, so the
    /// request hangs until it times out. A timeout is therefore a throttle
    /// signal, not a failure, and is retried with backoff.
    private static let maxAttempts = 1

    private let transport: MusicBrainzTransport
    private let usesCircuitBreaker: Bool

    init() {
        transport = NetworkEnvironment.metadataSession
        usesCircuitBreaker = true
    }

    init(transport: MusicBrainzTransport) {
        self.transport = transport
        usesCircuitBreaker = false
    }

    // MARK: - Endpoints

    /// Finds the recording this metadata describes. Lucene syntax, so the
    /// terms are quoted and escaped rather than concatenated.
    func searchRecording(artist: String?, title: String) async throws -> MBRecording? {
        var terms = ["recording:\(Self.quote(title))"]
        if let artist, !artist.isEmpty { terms.append("artist:\(Self.quote(artist))") }

        let response: MBRecordingSearch = try await get(
            "recording",
            query: [
                URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
                URLQueryItem(name: "limit", value: "5")
            ]
        )
        // A weak match is worse than none: a wrong canonical identity poisons
        // every relationship hung off it later.
        return (response.recordings ?? []).first { ($0.score ?? 0) >= 90 }
    }

    func recording(id: String) async throws -> MBRecording {
        try await get("recording/\(id)", query: [
            URLQueryItem(name: "inc", value: "artists+releases+isrcs")
        ])
    }

    /// Finds an artist by name. This is the entry point for digging into
    /// someone you only own files by: without it, an artist with no catalogued
    /// recording has nothing to look up and the page stays empty forever.
    func searchArtist(name: String) async throws -> MBArtistSearchResult? {
        let response: MBArtistSearch = try await get("artist", query: [
            URLQueryItem(name: "query", value: "artist:\(Self.quote(name))"),
            URLQueryItem(name: "limit", value: "5")
        ])
        // Artist names are far less unique than track titles, so the bar is
        // high: an exact name match, or a very strong score.
        let candidates = response.artists ?? []
        if let exact = candidates.first(where: {
            RecordingKey.normalize($0.name) == RecordingKey.normalize(name)
        }) {
            return exact
        }
        return candidates.first { ($0.score ?? 0) >= 95 }
    }

    /// An artist's discography in one request, rather than one per recording.
    func releaseGroups(artistID: String, limit: Int = 100) async throws -> MBReleaseGroupBrowse {
        try await get("release-group", query: [
            URLQueryItem(name: "artist", value: artistID),
            URLQueryItem(name: "limit", value: String(limit))
        ])
    }

    func artist(id: String) async throws -> MBArtist {
        try await get("artist/\(id)", query: [
            URLQueryItem(name: "inc", value: "release-groups+aliases+tags")
        ])
    }

    func label(id: String) async throws -> MBLabel {
        try await get("label/\(id)")
    }

    func release(id: String) async throws -> MBRelease {
        try await get("release/\(id)", query: [
            URLQueryItem(name: "inc", value: "labels+artist-credits+release-groups")
        ])
    }

    /// Everything a label has put out, which is how the roster is derived —
    /// MusicBrainz has no "artists on this label" endpoint.
    func releases(labelID: String, limit: Int = 100) async throws -> MBReleaseBrowse {
        try await get("release", query: [
            URLQueryItem(name: "label", value: labelID),
            URLQueryItem(name: "inc", value: "artist-credits"),
            URLQueryItem(name: "limit", value: String(limit))
        ])
    }

    // MARK: - Transport

    /// Lucene treats plenty of punctuation as syntax, and track titles are
    /// full of it.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "+-&|!(){}[]^\"~*?:\\/".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var lastError: Error = MusicBrainzError.rateLimited
        for attempt in 0..<Self.maxAttempts {
            do {
                return try await attemptGet(path, query: query)
            } catch let error as MusicBrainzError where error == .rateLimited {
                lastError = error
                guard attempt < Self.maxAttempts - 1 else { break }
                // One short retry keeps a transient throttle from turning a
                // foreground page into a minute-long wait.
                let backoff = UInt64(1 << attempt) * 1_000_000_000
                try await Task.sleep(nanoseconds: backoff)
            }
        }
        throw lastError
    }

    private func attemptGet<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        if usesCircuitBreaker, !(await Self.circuit.permitsRequest()) {
            throw MusicBrainzError.rateLimited
        }
        guard var components = URLComponents(
            url: Self.base.appendingPathComponent(path, isDirectory: false),
            resolvingAgainstBaseURL: false
        ) else { throw MusicBrainzError.malformedResponse }

        components.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url else { throw MusicBrainzError.malformedResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // MusicBrainz blocks clients that don't say who they are.
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")

        await Self.gate.wait()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw MusicBrainzError.offline
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                // Not a dead connection — a throttled one.
                if usesCircuitBreaker { await Self.circuit.trip() }
                throw MusicBrainzError.rateLimited
            default:
                throw MusicBrainzError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 503 {
                if usesCircuitBreaker { await Self.circuit.trip() }
                throw MusicBrainzError.rateLimited
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MusicBrainzError.badStatus(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MusicBrainzError.malformedResponse
        }
    }
}
