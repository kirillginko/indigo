//
//  RovrAPI.swift
//  Indigo
//
//  Transport for ROVR. One door: the Strapi API at strapi.rovr.live, which the
//  station leaves open to read.
//
//  Two of its endpoints are not shaped like Strapi's own and are the ones that
//  matter most. `/api/schedules/radio/public` takes a wall clock rather than an
//  instant, and `/api/playlists/archives/public` takes flat `page`, `pageSize`,
//  `query` and `tags` instead of Strapi's nested pagination — pass it
//  `pagination[page]` and it silently answers with page one, which is the sort
//  of thing that looks like a working archive that never advances.
//

import Foundation

nonisolated enum RovrError: LocalizedError, Equatable {
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
            "ROVR returned an unexpected response (\(code))."
        case .malformedResponse:
            "ROVR sent something Indigo couldn't read."
        case .notFound:
            "ROVR no longer publishes this."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct RovrArchivePage: Sendable {
    var broadcasts: [RovrBroadcast]
    var page: Int
    var pageCount: Int
    var total: Int
}

nonisolated struct RovrAPI: Sendable {
    private static let base = URL(string: "https://strapi.rovr.live/api/")!

    static let pageSize = 24
    static let directoryPageSize = 100

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    /// The stream for a given hour of UTC offset.
    ///
    /// ROVR runs the same programme on twenty-one of these so that a show
    /// scheduled for the evening is the evening wherever it is heard. The
    /// listener's own offset is the one to ask for; UTC stands in when the
    /// station runs nothing at theirs, which is anywhere past ±12.
    func fetchRadioStream(offset: Int) async throws -> RovrStreamDTO {
        if let stream = try? await stream(atOffset: offset) { return stream }
        return try await stream(atOffset: 0)
    }

    private func stream(atOffset offset: Int) async throws -> RovrStreamDTO {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("streams"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filters[offset][$eq]", value: String(offset))
        ]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        let response: RovrListResponse<RovrStreamDTO> = try await get(url)
        guard let stream = response.data.first(where: { $0.hlsUrl != nil }) else {
            throw RovrError.notFound
        }
        return stream
    }

    /// The mood channels the station publishes — four of them, continuous and
    /// unscheduled. The `streams` collection carries a good many more that are
    /// not on this list, and those are the station's business rather than
    /// something to put in front of a listener.
    func fetchMoodStreams() async throws -> [RovrMoodStreamDTO] {
        let response: RovrListResponse<RovrMoodStreamDTO> = try await get(
            Self.base.appendingPathComponent("streams/moods/public")
        )
        return response.data.filter { $0.hlsUrl != nil }
    }

    /// What is on the scheduled radio at a moment.
    ///
    /// The date goes as a plain wall clock with no zone on it, and that is the
    /// point: every timezone stream runs the same programme against the local
    /// clock, so the listener's own is the right one to ask in.
    func fetchOnAir(at date: Date = .now) async throws -> RovrOnAir {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("schedules/radio/public"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "date", value: RovrTimestamp.wallClock(date))
        ]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        let response: RovrListResponse<RovrScheduleDTO> = try await get(url)
        guard let slot = response.data.first else { return .idle }
        return slot.asOnAir()
    }

    /// The rest of today, read one slot at a time.
    ///
    /// ROVR publishes no range endpoint — the schedule answers for a moment —
    /// so what follows is found by stepping to the end of each slot and asking
    /// again. It is capped tightly because each step is a request.
    func fetchUpcoming(from date: Date = .now, limit: Int = 6) async -> [RovrOnAir] {
        var found: [RovrOnAir] = []
        var cursor = date

        for _ in 0..<max(0, limit) {
            guard let slot = try? await fetchOnAir(at: cursor), slot.isOnAir else { break }
            if let last = found.last, last.startsAt == slot.startsAt { break }
            found.append(slot)
            // A slot with no end cannot be stepped past.
            guard let ends = slot.endsAt, ends > cursor else { break }
            cursor = ends.addingTimeInterval(60)
        }
        return found
    }

    // MARK: - The archive

    /// ROVR's archive, newest first.
    ///
    /// Search, tags and the curator filter all narrow at the station, which is
    /// the only thing that reaches past the first page of ten thousand — and
    /// the station's robots.txt allows all of it.
    func fetchArchive(
        page: Int = 1,
        pageSize: Int = RovrAPI.pageSize,
        query: String? = nil,
        tags: [String] = [],
        curatorID: String? = nil,
        showID: String? = nil
    ) async throws -> RovrArchivePage {
        var items = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "pageSize", value: String(max(1, pageSize)))
        ]
        if let query, !query.isEmpty {
            items.append(URLQueryItem(name: "query", value: query))
        }
        // The archive filters on a tag's `type`, never on the label it is
        // shown under — asking for "FUZZ" instead of "grease" returns nothing
        // at all rather than an error.
        let values = tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
        if !values.isEmpty {
            items.append(URLQueryItem(name: "tags", value: values.joined(separator: ",")))
        }
        if let curatorID, !curatorID.isEmpty {
            items.append(URLQueryItem(
                name: "filters[show][curators][documentId][$eq]", value: curatorID
            ))
        }
        if let showID, !showID.isEmpty {
            items.append(URLQueryItem(name: "filters[show][documentId][$eq]", value: showID))
        }

        var components = URLComponents(
            url: Self.base.appendingPathComponent("playlists/archives/public"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = items
        guard let url = components?.url else { throw RovrError.malformedResponse }

        let response: RovrListResponse<RovrBroadcastDTO> = try await get(url)
        let pagination = response.meta?.pagination
        return RovrArchivePage(
            broadcasts: response.data.compactMap { $0.asBroadcast() },
            page: pagination?.page ?? page,
            pageCount: pagination?.pageCount ?? 1,
            total: pagination?.total ?? response.data.count
        )
    }

    func fetchBroadcast(id: String) async throws -> RovrBroadcast {
        let response: RovrSingleResponse<RovrBroadcastDTO> = try await get(
            Self.base.appendingPathComponent("playlists/archives/public/\(id)")
        )
        guard let broadcast = response.data?.asBroadcast() else { throw RovrError.notFound }
        return broadcast
    }

    // MARK: - Shows

    /// The shows still running. ROVR keeps four hundred on the books and marks
    /// the ones that have stopped.
    func fetchShows(page: Int = 1) async throws -> RovrListResponse<RovrShowDTO> {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("shows"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filters[active][$eq]", value: "true"),
            URLQueryItem(name: "pagination[page]", value: String(max(1, page))),
            URLQueryItem(name: "pagination[pageSize]", value: String(Self.directoryPageSize)),
            URLQueryItem(name: "sort", value: "title:asc"),
            URLQueryItem(name: "populate", value: "*")
        ]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        return try await get(url)
    }

    func fetchShow(id: String) async throws -> RovrShow {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("shows/\(id)"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "populate", value: "*")]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        let response: RovrSingleResponse<RovrShowDTO> = try await get(url)
        guard let show = response.data?.asShow() else { throw RovrError.notFound }
        return show
    }

    // MARK: - Curators

    /// The people behind the shows.
    ///
    /// Filtered to the ones ROVR actually publishes: the collection holds
    /// close to six hundred, but a good half are either hidden or stand in as
    /// a guest on somebody else's show rather than having one of their own.
    func fetchCurators(page: Int = 1) async throws -> RovrListResponse<RovrCuratorDTO> {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("curators"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filters[visible][$eq]", value: "true"),
            URLQueryItem(name: "filters[isSubcurator][$eq]", value: "false"),
            URLQueryItem(name: "pagination[page]", value: String(max(1, page))),
            URLQueryItem(name: "pagination[pageSize]", value: String(Self.directoryPageSize)),
            URLQueryItem(name: "sort", value: "name:asc"),
            URLQueryItem(name: "populate", value: "*")
        ]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        return try await get(url)
    }

    func fetchCurator(id: String) async throws -> RovrCurator {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("curators/\(id)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "populate", value: "*")]
        guard let url = components?.url else { throw RovrError.malformedResponse }
        let response: RovrSingleResponse<RovrCuratorDTO> = try await get(url)
        guard let curator = response.data?.asCurator() else { throw RovrError.notFound }
        return curator
    }

    // MARK: - Tags

    /// The eight words ROVR sorts its archive by, in the station's own order.
    func fetchTags() async throws -> [RovrTag] {
        let response: RovrListResponse<RovrTagDTO> = try await get(
            Self.base.appendingPathComponent("playlist-tags")
        )
        return response.data
            .compactMap { $0.asTag() }
            .sorted { $0.order < $1.order }
    }

    // MARK: - Transport

    private func get<T: Decodable & Sendable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw RovrError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw RovrError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404
                ? RovrError.notFound
                : RovrError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RovrError.malformedResponse
        }
    }
}
