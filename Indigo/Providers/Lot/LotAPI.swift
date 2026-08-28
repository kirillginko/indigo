//
//  LotAPI.swift
//  Indigo
//
//  Transport for thelotradio.com. The Lot publishes no documented API, so
//  these are the same two doors its own site uses:
//
//  · Server actions — `getEpisodes`, `getShows` — which is how the site's own
//    archive pages and their infinite scroll fetch data. They answer with
//    clean JSON and, crucially, they page.
//  · The server-rendered pages themselves, read out of the Flight stream by
//    `LotFlight`. Everything a page shows is in there; nothing else is.
//
//  Actions are the fast path and the pages are the fallback, because an action
//  id is a build artefact of the site and a URL is not. If The Lot redeploys
//  with new ids, the archive stops paging and keeps working.
//

import Foundation

nonisolated enum LotError: LocalizedError, Equatable {
    case offline
    case badStatus(Int)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            "No internet connection."
        case .badStatus(let code):
            "The Lot Radio returned an unexpected response (\(code))."
        case .malformedResponse:
            "The Lot Radio sent something Indigo couldn't read."
        case .transport(let message):
            message
        }
    }
}

/// Facets the archive can be narrowed by. The Lot filters on display names
/// rather than slugs — that is what its own facet controls send.
nonisolated struct LotEpisodeFilters: Hashable, Sendable {
    var shows: [String] = []
    var artists: [String] = []
    var genres: [String] = []

    var isEmpty: Bool { shows.isEmpty && artists.isEmpty && genres.isEmpty }

    var payload: [String: Any] {
        var body: [String: Any] = [:]
        if !shows.isEmpty { body["shows"] = shows }
        if !artists.isEmpty { body["artists"] = artists }
        if !genres.isEmpty { body["genres"] = genres }
        return body
    }
}

nonisolated struct LotEpisodeFeed: Sendable {
    var episodes: [LotEpisode]
    /// Opaque; carries the sort and filters that produced it, so it goes back
    /// verbatim or not at all.
    var cursor: String?
    var total: Int
}

nonisolated struct LotShowIndex: Sendable {
    var shows: [LotShow]
    var total: Int
}

nonisolated struct LotShowPage: Sendable {
    var show: LotShow?
    var summary: String?
    var episodes: [LotEpisode]
    var cursor: String?
    var total: Int
}

nonisolated struct LotEpisodePage: Sendable {
    var summary: String?
    /// The rest of the residency, as the page lists it underneath.
    var related: [LotEpisode]
}

nonisolated struct LotAPI: Sendable {
    private static let base = URL(string: "https://www.thelotradio.com/")!
    private static let origin = "https://www.thelotradio.com"

    /// Server action ids, read out of the site's own client bundle. They are
    /// content hashes of the module that exports each action, so they survive
    /// ordinary redeploys and change when that module does — which is why
    /// every call that uses one has a page-scraped fallback behind it.
    private enum Action {
        static let episodes = "40cc4f8d8e9b2710f1cbc160fd08603dab64742898"
        static let shows = "4065fa077e3fba62939a802f259ab6da3aa3019c5a"
    }

    /// The archive answers with at most a hundred entries per call.
    static let maxPageSize = 100

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    /// Every channel The Lot is currently running, main stream first. The
    /// programming calendar rides along with it — roughly a fortnight either
    /// side of now — which is the only schedule the station publishes.
    func fetchLive() async throws -> [LotLiveChannel] {
        let flight = LotFlight.page(html: try await getText(""))
        let channels = flight.objects(containing: "playbackInfo").compactMap { data -> LotLiveChannel? in
            guard let dto = try? JSONDecoder().decode(LotLiveDTO.self, from: data) else { return nil }
            return dto.asChannel(resolvedBy: flight)
        }
        guard !channels.isEmpty else { throw LotError.malformedResponse }
        // A pop-up channel can outrank the main one in document order; the
        // house stream is the one the app is about.
        return channels.sorted { left, right in
            let leftIsHouse = left.title.localizedCaseInsensitiveContains("lot")
            let rightIsHouse = right.title.localizedCaseInsensitiveContains("lot")
            if leftIsHouse != rightIsHouse { return leftIsHouse }
            return left.schedule.count > right.schedule.count
        }
    }

    // MARK: - Archive

    func fetchEpisodes(
        limit: Int = 48,
        cursor: String? = nil,
        order: String = "date:desc",
        filters: LotEpisodeFilters = LotEpisodeFilters()
    ) async throws -> LotEpisodeFeed {
        var argument: [String: Any] = [
            "limit": min(limit, Self.maxPageSize),
            "order": order,
            "filters": filters.payload,
            "staffChoice": false
        ]
        if let cursor { argument["cursor"] = cursor }

        do {
            let data = try await action(Action.episodes, path: "the-index", arguments: [argument])
            let page = try decode(LotEpisodePageDTO.self, from: data)
            return LotEpisodeFeed(
                episodes: page.items.compactMap { $0.asEpisode() },
                cursor: page.pages?.next,
                total: page.total ?? page.items.count
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Without the action there is no paging and no filtering, so only
            // the first unfiltered page can be recovered. Better than nothing
            // on screen, and honest about having no cursor to go on with.
            guard cursor == nil, filters.isEmpty else { throw error }
            let flight = LotFlight.page(html: try await getText("the-index"))
            let episodes = flight.objects(containing: "transcodedFile")
                .compactMap { try? JSONDecoder().decode(LotEpisodeDTO.self, from: $0) }
                .compactMap { $0.asEpisode() }
            guard !episodes.isEmpty else { throw error }
            return LotEpisodeFeed(episodes: episodes, cursor: nil, total: episodes.count)
        }
    }

    // MARK: - Shows

    func fetchShows(limit: Int = 100, skip: Int = 0) async throws -> LotShowIndex {
        let argument: [String: Any] = ["limit": min(limit, Self.maxPageSize), "skip": skip]
        do {
            let data = try await action(Action.shows, path: "shows", arguments: [argument])
            let page = try decode(LotShowPageDTO.self, from: data)
            return LotShowIndex(
                shows: page.items.compactMap { $0.asShow() },
                total: page.total ?? page.items.count
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard skip == 0 else { throw error }
            let flight = LotFlight.page(html: try await getText("shows"))
            guard let data = flight.object(containing: "initialData"),
                  let wrapper = try? JSONDecoder().decode(ShowDirectoryProps.self, from: data)
            else { throw error }
            let shows = wrapper.initialData.items.compactMap { $0.asShow() }
            guard !shows.isEmpty else { throw error }
            return LotShowIndex(shows: shows, total: wrapper.initialData.total ?? shows.count)
        }
    }

    /// A residency's own page: who it is, what it is, and its broadcasts.
    /// One request, because the page already server-renders all three.
    func fetchShowPage(slug: String) async throws -> LotShowPage {
        let flight = LotFlight.page(html: try await getText("shows/\(slug)"))

        var show: LotShow?
        var episodes: [LotEpisode] = []
        var cursor: String?
        var total = 0

        if let data = flight.object(containing: "initialData"),
           let props = try? JSONDecoder().decode(ShowPageProps.self, from: data) {
            show = props.show?.asShow()
            episodes = props.initialData.items.compactMap { $0.asEpisode() }
            cursor = props.initialData.pages?.next
            total = props.initialData.total ?? episodes.count
        }

        if episodes.isEmpty {
            episodes = flight.objects(containing: "transcodedFile")
                .compactMap { try? JSONDecoder().decode(LotEpisodeDTO.self, from: $0) }
                .compactMap { $0.asEpisode() }
            total = max(total, episodes.count)
        }

        return LotShowPage(
            show: show,
            summary: summary(in: flight),
            episodes: episodes,
            cursor: cursor,
            total: total
        )
    }

    /// The expanded page for one broadcast. The episode itself is not
    /// server-rendered as data — the page draws it straight into markup — so
    /// what this adds is the session note and the rest of the residency.
    func fetchEpisodePage(ref: LotEpisodeRef) async throws -> LotEpisodePage {
        let flight = LotFlight.page(html: try await getText(ref.path))
        let related = flight.objects(containing: "transcodedFile")
            .compactMap { try? JSONDecoder().decode(LotEpisodeDTO.self, from: $0) }
            .compactMap { $0.asEpisode() }
            .filter { $0.slug != ref.episode }
        return LotEpisodePage(summary: summary(in: flight), related: related)
    }

    // MARK: - Page shapes

    private struct ShowDirectoryProps: Decodable {
        let initialData: LotShowPageDTO
    }

    private struct ShowPageProps: Decodable {
        let show: LotShowDTO?
        let initialData: LotEpisodePageDTO
    }

    /// Both detail pages carry exactly one Contentful rich text field — the
    /// blurb — so the first one found is it.
    private func summary(in flight: LotFlight) -> String? {
        guard let data = flight.object(containing: "json"),
              let text = try? JSONDecoder().decode(LotRichTextDTO.self, from: data),
              let plain = text.plainText,
              !plain.isEmpty
        else { return nil }
        return plain
    }

    // MARK: - Transport

    /// Invokes a server action. The response is a Flight stream whose first
    /// row points at the row holding the return value.
    private func action(_ id: String, path: String, arguments: [Any]) async throws -> Data {
        guard let body = try? JSONSerialization.data(withJSONObject: arguments) else {
            throw LotError.malformedResponse
        }
        var request = URLRequest(url: Self.base.appendingPathComponent(path, isDirectory: false))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: "Next-Action")
        // Next refuses a cross-origin action, and a request with no origin at
        // all reads as one.
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin + "/" + path, forHTTPHeaderField: "Referer")

        let data = try await send(request)
        guard let stream = String(data: data, encoding: .utf8),
              let result = LotFlight(stream: stream).actionResult
        else { throw LotError.malformedResponse }
        return result
    }

    private func getText(_ path: String) async throws -> String {
        let url = path.isEmpty ? Self.base : Self.base.appendingPathComponent(path, isDirectory: false)
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        guard let text = String(data: data, encoding: .utf8) else { throw LotError.malformedResponse }
        return text
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LotError.malformedResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw LotError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw LotError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LotError.badStatus(http.statusCode)
        }
        return data
    }
}
