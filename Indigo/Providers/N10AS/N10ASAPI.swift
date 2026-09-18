//
//  N10ASAPI.swift
//  Indigo
//
//  Transport for n10.as. Three doors, none of them needing a key:
//
//  · api.radiocult.fm — the platform the station broadcasts on. `schedule/live`
//    is what is on the air this second, `schedule` is the calendar for any
//    range asked for. Both answer in UTC, which is the reason they are read
//    directly rather than through the station's own wrapper: n10.as re-serves
//    them at /radiocult/*, but flattened to naive local timestamps.
//  · n10asmaster.herokuapp.com/shows — the show directory, and the only place
//    a programme's description, slot, genres and links exist.
//  · api.mixcloud.com — the recordings. The station keeps 11,849 of them in
//    one flat feed under a single account, with no playlist per show.
//
//  Playback goes through Mixcloud's own widget, as their terms require.
//

import Foundation

nonisolated enum N10ASError: LocalizedError, Equatable {
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
            "n10.as returned an unexpected response (\(code))."
        case .malformedResponse:
            "n10.as sent something Indigo couldn't read."
        case .notFound:
            "n10.as no longer publishes this."
        case .transport(let message):
            message
        }
    }
}

/// A page of broadcasts plus the cursor for the next, when there is one.
nonisolated struct N10ASEpisodePage: Sendable {
    var episodes: [N10ASEpisode]
    var nextCursor: String?
}

nonisolated struct N10ASAPI: Sendable {
    private static let radiocult = URL(string: "https://api.radiocult.fm/api/station/n10as/")!
    private static let station = URL(string: "https://n10asmaster.herokuapp.com/")!
    private static let mixcloud = URL(string: "https://api.mixcloud.com/")!

    /// The station's Mixcloud account — the whole archive, under one name.
    static let mixcloudAccount = "n10as"

    /// Mixcloud's own ceiling for a listing is a hundred; fifty keeps a page
    /// of the archive under a quarter-megabyte, which matters when the feed is
    /// eleven thousand deep and somebody is scrolling it.
    static let archivePageSize = 50

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    func fetchOnAir() async throws -> N10ASOnAir {
        let live: RadioCultLiveDTO = try await get(
            Self.radiocult.appendingPathComponent("schedule/live")
        )
        guard let slot = live.result?.content,
              let entry = slot.asScheduleEntry()
        else { return .idle }

        return N10ASOnAir(
            showName: entry.title,
            showSummary: entry.summary,
            startsAt: entry.startsAt,
            endsAt: entry.endsAt,
            isLiveSlot: entry.isLive
        )
    }

    /// The calendar from now to a week out.
    func fetchSchedule(days: Int = 7) async throws -> [N10ASScheduleEntry] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = Date.now

        var components = URLComponents(
            url: Self.radiocult.appendingPathComponent("schedule"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "startDate", value: formatter.string(from: now)),
            URLQueryItem(
                name: "endDate",
                value: formatter.string(from: now.addingTimeInterval(TimeInterval(days) * 86_400))
            )
        ]
        guard let url = components?.url else { throw N10ASError.malformedResponse }

        let page: RadioCultScheduleDTO = try await get(url)
        return (page.schedules ?? [])
            .compactMap { $0.asScheduleEntry() }
            .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: - Shows

    /// The whole directory in one request — a hundred and forty-seven shows,
    /// which is what lets the page filter and search without going back out.
    func fetchShows() async throws -> [N10ASShow] {
        let shows: [N10ASShowDTO] = try await get(Self.station.appendingPathComponent("shows"))
        return shows
            .compactMap { $0.asShow() }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func fetchShow(slug: String) async throws -> N10ASShow {
        let dto: N10ASShowDTO = try await get(
            Self.station.appendingPathComponent("shows/\(slug)")
        )
        guard let show = dto.asShow() else { throw N10ASError.notFound }
        return show
    }

    // MARK: - Archive

    /// A page of the station's uploads, newest first.
    ///
    /// Mixcloud pages by opaque cursor URL rather than by number, so the
    /// cursor handed back is the whole address of the next page.
    func fetchArchive(cursor: String? = nil) async throws -> N10ASEpisodePage {
        let url: URL
        if let cursor, let built = URL(string: cursor) {
            url = built
        } else {
            var components = URLComponents(
                url: Self.mixcloud.appendingPathComponent("\(Self.mixcloudAccount)/cloudcasts/"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "limit", value: String(Self.archivePageSize))
            ]
            guard let built = components?.url else { throw N10ASError.malformedResponse }
            url = built
        }

        let page: MixcloudPageDTO = try await get(url)
        return N10ASEpisodePage(
            episodes: page.data.compactMap { $0.asN10ASEpisode() },
            nextCursor: page.paging?.next
        )
    }

    /// How many broadcasts the station has published in total.
    ///
    /// The archive pages fifty at a time and nothing in a page says how deep
    /// the feed goes, so a listener scrolling it has no idea whether they are
    /// near the end. Mixcloud keeps the count on the account itself, which is
    /// one cheap request for an honest denominator.
    func fetchArchiveCount() async -> Int? {
        let url = Self.mixcloud.appendingPathComponent("\(Self.mixcloudAccount)/")
        guard let account: MixcloudAccountDTO = try? await get(url) else { return nil }
        return account.cloudcast_count
    }

    // MARK: - One show's run

    /// Everything the archive holds for one programme, as far as it can be
    /// found.
    ///
    /// Mixcloud gives the station one flat feed and no playlist per show, and
    /// eleven thousand uploads is a hundred and nineteen requests — not
    /// something to do because somebody opened a show page. So the run is
    /// searched for instead.
    ///
    /// Search is the station's whole archive under one query, and it is
    /// matched twice over: the account has to be the station's, because the
    /// search is global and "Overflow" belongs to a hundred other people, and
    /// the programme read out of the title has to be the one asked for,
    /// because Mixcloud matches loosely.
    ///
    /// This is recall, not truth. A show whose name is a common word can come
    /// back thin or empty however it is asked, which is why the caller merges
    /// whatever the archive listing has already loaded rather than treating
    /// this as the answer.
    ///
    /// `title` is the show as the directory names it, and it is the reduced
    /// form that is searched for. The directory's own wording is worse at
    /// finding the recordings than the bare programme is: "T Time with Tammy
    /// J" returns none of the station's uploads and "T Time" returns
    /// seventy-two of them, because the extra words have to be matched too.
    func searchEpisodes(title: String) async -> [N10ASEpisode] {
        let programme = N10ASTitle.parse(N10ASTitle.withoutRerunMarks(title)).programme ?? title
        let wanted = N10ASTitle.matchKey(title)
        guard !wanted.isEmpty else { return [] }

        var components = URLComponents(
            url: Self.mixcloud.appendingPathComponent("search/"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            // The account name in the query is what keeps the station's own
            // uploads above everyone else's: without it "Exhale" and
            // "Channel Z" come back as a hundred strangers and nothing of
            // n10.as's at all.
            URLQueryItem(name: "q", value: "\(programme) \(Self.mixcloudAccount)"),
            URLQueryItem(name: "type", value: "cloudcast"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components?.url else { return [] }
        guard let page: MixcloudPageDTO = try? await get(url) else { return [] }

        return page.data
            .filter { $0.user?.username?.caseInsensitiveCompare(Self.mixcloudAccount) == .orderedSame }
            .compactMap { $0.asN10ASEpisode() }
            .filter { episode in
                guard let name = episode.programme else { return false }
                return N10ASTitle.matchKey(name) == wanted
            }
    }

    // MARK: - One broadcast

    /// Fetches a single broadcast from nothing but its slug — which is what a
    /// crated episode opened months later has.
    func fetchEpisode(slug: String) async throws -> N10ASEpisode {
        let dto: MixcloudCloudcastDTO = try await get(
            Self.mixcloud.appendingPathComponent("\(Self.mixcloudAccount)/\(slug)/")
        )
        guard let episode = dto.asN10ASEpisode() else { throw N10ASError.notFound }
        return episode
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
                throw N10ASError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw N10ASError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404
                ? N10ASError.notFound
                : N10ASError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw N10ASError.malformedResponse
        }
    }
}
