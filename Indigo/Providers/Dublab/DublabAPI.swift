//
//  DublabAPI.swift
//  Indigo
//
//  Transport for dublab. Two doors, both the station's own:
//
//  · `lazystate` — the WordPress endpoint dublab's front end reads. Ask it for
//    a route and it answers with that page and everything the page links to,
//    as one flat map of path → entry. The archive pages; the DJ directory
//    arrives whole.
//  · Airtime's `live-info-v2` — what is on the air this second, and what is
//    next. dublab streams through Airtime, so this is the station telling the
//    truth about itself rather than a schedule being guessed at.
//

import Foundation

nonisolated enum DublabError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "dublab returned an unexpected response (\(code))."
        case .malformedResponse:
            "dublab sent something Indigo couldn't read."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct DublabArchivePage: Sendable {
    var broadcasts: [DublabBroadcast]
    var page: Int
    var pageCount: Int
    var total: Int
}

nonisolated struct DublabLive: Sendable {
    var onAir: DublabOnAir
    var timeZone: TimeZone
}

nonisolated struct DublabAPI: Sendable {
    private static let state = URL(string: "https://dublab.wpengine.com/wp-json/lazystate/v1/")!
    private static let airtime = URL(string: "https://dublab.airtime.pro/api/live-info-v2")!

    /// The archive answers 24 broadcasts to a page and will not be talked into
    /// more, so paging is the only way through its twenty-seven thousand.
    static let pageSize = 24

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    func fetchLive() async throws -> DublabLive {
        let info: AirtimeLiveInfoDTO = try await decode(Self.airtime)
        let zone = info.timeZone(default: "America/Los_Angeles")

        let show = info.shows?.current
        let track = info.tracks?.current
        let upcoming = (info.shows?.next ?? []).compactMap { next -> DublabScheduleEntry? in
            guard let start = DublabTimestamp.parse(next.starts, zone: zone),
                  let end = DublabTimestamp.parse(next.ends, zone: zone),
                  end > start
            else { return nil }
            let name = HTMLText.decode(next.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return DublabScheduleEntry(
                id: "\(name)|\(start.timeIntervalSince1970)",
                title: name,
                summary: next.description.flatMap(HTMLText.plainText),
                artworkURL: next.image_path.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                startsAt: start,
                endsAt: end
            )
        }

        let onAir = DublabOnAir(
            showName: show?.name.map(HTMLText.decode).flatMap { $0.isEmpty ? nil : $0 },
            showStartsAt: DublabTimestamp.parse(show?.starts, zone: zone),
            showEndsAt: DublabTimestamp.parse(show?.ends, zone: zone),
            trackTitle: track?.metadata?.track_title.map(HTMLText.decode),
            trackArtist: track?.metadata?.artist_name.map(HTMLText.decode),
            upNext: upcoming
        )
        return DublabLive(onAir: onAir, timeZone: zone)
    }

    /// dublab's published programme calendar — a fortnight or so of slots,
    /// which is more than Airtime's "what is next" and reads as a schedule.
    func fetchSchedule(zone: TimeZone) async throws -> [DublabScheduleEntry] {
        let map = try await fetchState("schedule")
        return map.entries(under: "/schedule/")
            .compactMap { $0.asScheduleEntry(zone: zone) }
            .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: - Archive

    func fetchArchive(page: Int = 1, genre: String? = nil, year: String? = nil) async throws -> DublabArchivePage {
        var query = [URLQueryItem(name: "page", value: String(max(1, page)))]
        if let genre, !genre.isEmpty { query.append(URLQueryItem(name: "genre", value: genre)) }
        if let year, !year.isEmpty { query.append(URLQueryItem(name: "show-year", value: year)) }

        let map = try await fetchState("archive", query: query)
        guard let root = map.root else { throw DublabError.malformedResponse }
        // `pages` is the running order; the entries themselves are siblings.
        let broadcasts = map.ordered(root.pages ?? []).compactMap { $0.asBroadcast() }
        return DublabArchivePage(
            broadcasts: broadcasts,
            page: root.page ?? page,
            pageCount: root.numpages ?? 1,
            total: root.total ?? broadcasts.count
        )
    }

    /// A real search of the whole archive rather than of what happens to be
    /// loaded — dublab indexes all twenty-seven thousand broadcasts and pages
    /// the matches the same way the archive itself does.
    func search(_ term: String, page: Int = 1) async throws -> DublabArchivePage {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DublabArchivePage(broadcasts: [], page: 1, pageCount: 0, total: 0) }
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed

        let map = try await fetchState(
            "search/\(escaped)",
            query: [
                URLQueryItem(name: "type", value: "broadcasts"),
                URLQueryItem(name: "page", value: String(max(1, page)))
            ]
        )
        guard let root = map.root else { throw DublabError.malformedResponse }
        let broadcasts = map.ordered(root.pages ?? []).compactMap { $0.asBroadcast() }
        return DublabArchivePage(
            broadcasts: broadcasts,
            page: root.page ?? page,
            pageCount: root.numpages ?? 1,
            total: root.total ?? broadcasts.count
        )
    }

    /// Everything one DJ has broadcast. The archive filters on the artist slug
    /// rather than on the show, which is why a DJ page can list a run and a
    /// show page cannot.
    func fetchBroadcasts(artist slug: String) async throws -> [DublabBroadcast] {
        let map = try await fetchState("archive", query: [URLQueryItem(name: "artist", value: slug)])
        guard let root = map.root else { throw DublabError.malformedResponse }
        return map.ordered(root.pages ?? []).compactMap { $0.asBroadcast() }
    }

    func fetchBroadcast(slug: String) async throws -> DublabBroadcast {
        let map = try await fetchState("archive/\(slug)")
        guard let broadcast = map.root?.asBroadcast() else { throw DublabError.malformedResponse }
        return broadcast
    }

    /// The genres and years the archive can be narrowed by, as dublab lists
    /// them — nine thousand artists come back too, which is why only these two
    /// are kept.
    func fetchArchiveFilters() async throws -> (genres: [DublabGenre], years: [String]) {
        struct FiltersDTO: Decodable {
            let filters: [Filter]?
            struct Filter: Decodable {
                let key: String?
                let values: [Value]?
                struct Value: Decodable {
                    let id: StringOrInt?
                    let title: String?
                }
            }
        }
        let data = try await load(url("archive"))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = object["/archive"],
              let rootData = try? JSONSerialization.data(withJSONObject: root),
              let parsed = try? JSONDecoder().decode(FiltersDTO.self, from: rootData)
        else { throw DublabError.malformedResponse }

        var genres: [DublabGenre] = []
        var years: [String] = []
        for filter in parsed.filters ?? [] {
            for value in filter.values ?? [] {
                guard let identity = value.id?.text, identity != "0",
                      let label = value.title, !label.isEmpty else { continue }
                switch filter.key {
                case "genre": genres.append(DublabGenre(name: HTMLText.decode(label), slug: identity))
                case "show-year": years.append(identity)
                default: continue
                }
            }
        }
        return (genres, years.sorted(by: >))
    }

    // MARK: - DJs

    func fetchDJs() async throws -> [DublabDJ] {
        let map = try await fetchState("djs")
        guard let root = map.root else { throw DublabError.malformedResponse }
        return map.ordered(root.pages ?? []).compactMap { $0.asDJ() }
    }

    func fetchDJ(slug: String) async throws -> DublabDJ {
        let map = try await fetchState("djs/\(slug)")
        guard let dj = map.root?.asDJ() else { throw DublabError.malformedResponse }
        return dj
    }

    // MARK: - The lazystate map

    /// One response: the page asked for, plus every entry it links to.
    nonisolated struct StateMap: Sendable {
        let requested: String
        let entries: [String: DublabEntryDTO]

        var root: DublabEntryDTO? {
            entries[requested] ?? entries.values.first { $0.url == requested }
        }

        /// The linked entries in the order the page listed them.
        func ordered(_ paths: [String]) -> [DublabEntryDTO] {
            paths.compactMap { entries[$0] }
        }

        func entries(under prefix: String) -> [DublabEntryDTO] {
            entries.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        }
    }

    private func fetchState(_ path: String, query: [URLQueryItem] = []) async throws -> StateMap {
        let requested = "/" + path + (query.isEmpty ? "" : "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))
        let data = try await load(url(path, query: query))
        do {
            let entries = try JSONDecoder().decode([String: DublabEntryDTO].self, from: data)
            return StateMap(requested: requested, entries: entries)
        } catch {
            throw DublabError.malformedResponse
        }
    }

    // MARK: - Transport

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: Self.state.appendingPathComponent(path, isDirectory: false),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        return components?.url ?? Self.state
    }

    private func decode<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await load(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DublabError.malformedResponse
        }
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw DublabError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw DublabError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DublabError.badStatus(http.statusCode)
        }
        return data
    }
}

/// The filter lists mix `0` with `"dance"` in the same `id` field.
nonisolated struct StringOrInt: Decodable, Sendable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { text = value }
        else if let value = try? container.decode(Int.self) { text = String(value) }
        else { text = "" }
    }
}
