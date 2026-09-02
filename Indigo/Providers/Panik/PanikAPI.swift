//
//  PanikAPI.swift
//  Indigo
//
//  Transport for Radio Panik. Everything is the station's own site:
//
//  · `/onair.json` — the one endpoint that answers in JSON, and it says what
//    is on the air this second.
//  · `/podcasts.rss`, and `/emissions/<show>/podcasts.rss` — the archive, as
//    podcast feeds carrying a direct address for each recording.
//  · `/emissions/` and `/programme/` — the directory and the week, read out of
//    the markup, because Panik publishes no catalogue API. See `PanikHTML`.
//  · `/emissions/<show>/playlist/<date>/` — what a continuous-music show
//    actually played that day.
//
//  One path is deliberately absent. Panik's robots.txt allows everything to a
//  general client except `/recherche/`, so Indigo does not search the station:
//  its search narrows what has been loaded, and the pages say so.
//

import Foundation

nonisolated enum PanikError: LocalizedError, Equatable {
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
            "Radio Panik returned an unexpected response (\(code))."
        case .malformedResponse:
            "Radio Panik sent something Indigo couldn't read."
        case .notFound:
            "Radio Panik no longer publishes this."
        case .transport(let message):
            message
        }
    }
}

nonisolated struct PanikAPI: Sendable {
    private static let site = URL(string: "https://www.radiopanik.org")!

    /// Panik streams Icecast out of Domaine Public. It offers mp3 and ogg;
    /// mp3 is the one AVFoundation will take.
    static let stream = URL(string: "https://streaming.domainepublic.net/radiopanik.mp3")!

    /// The station broadcasts from Brussels and writes every time in its own
    /// wall clock, with no offset attached.
    static let timeZone = TimeZone(identifier: "Europe/Brussels") ?? .current

    private let session: URLSession

    init(session: URLSession = NetworkEnvironment.session) {
        self.session = session
    }

    // MARK: - Live

    func fetchOnAir() async throws -> PanikOnAir {
        let data = try await get(Self.site.appendingPathComponent("onair.json"))
        guard let dto = try? JSONDecoder().decode(PanikOnAirDTO.self, from: data) else {
            throw PanikError.malformedResponse
        }
        return dto.asOnAir()
    }

    /// The published week. Panik renders seven days at a time; `week` steps
    /// backwards and forwards from the current one when it is given.
    func fetchSchedule(year: Int? = nil, week: Int? = nil) async throws -> [PanikScheduleEntry] {
        let url: URL
        if let year, let week {
            url = Self.site.appendingPathComponent("programme/\(year)/\(week)/")
        } else {
            url = Self.site.appendingPathComponent("programme/")
        }
        let html = try await getText(url)
        return PanikHTML.schedule(in: html, zone: Self.timeZone)
    }

    // MARK: - The archive

    /// The station's recent broadcasts across every show, newest first.
    ///
    /// Fifty of them: a podcast feed is a window on an archive rather than the
    /// whole of it, and the depth is in the per-show feeds.
    func fetchPodcasts() async throws -> [PanikEpisode] {
        let data = try await get(Self.site.appendingPathComponent("podcasts.rss"))
        guard let feed = PodcastFeedParser.parse(data) else { throw PanikError.malformedResponse }
        return feed.items.compactMap { $0.asPanikEpisode() }
    }

    /// Every broadcast of one show the station still publishes.
    func fetchEpisodes(showSlug: String, showTitle: String? = nil) async throws -> [PanikEpisode] {
        let url = Self.site.appendingPathComponent("emissions/\(showSlug)/podcasts.rss")
        let data = try await get(url)
        guard let feed = PodcastFeedParser.parse(data) else { throw PanikError.malformedResponse }
        let name = showTitle ?? feed.title
        return feed.items.compactMap { $0.asPanikEpisode(showSlug: showSlug, showTitle: name) }
    }

    /// One broadcast, from nothing but its id — which is what a crated episode
    /// opened months later has. The id carries the show, so the show's own
    /// feed is the place to look.
    func fetchEpisode(id: String) async throws -> PanikEpisode {
        guard let showSlug = PanikEpisodeID.showSlug(of: id) else { throw PanikError.notFound }
        if let episodes = try? await fetchEpisodes(showSlug: showSlug),
           let match = episodes.first(where: { $0.id == id }) {
            return match
        }
        // A show that has been retired keeps its episodes in the station feed
        // for as long as they are recent.
        let recent = try await fetchPodcasts()
        guard let match = recent.first(where: { $0.id == id }) else { throw PanikError.notFound }
        return match
    }

    // MARK: - Shows

    /// The whole directory in one request, pictures and blurbs included.
    func fetchShows() async throws -> [PanikShow] {
        let html = try await getText(Self.site.appendingPathComponent("emissions/"))
        let shows = PanikHTML.shows(in: html)
        guard !shows.isEmpty else { throw PanikError.malformedResponse }
        return shows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// A show's own page, which carries more than its entry in the directory:
    /// the full blurb, the big picture, its slot and its links.
    func fetchShow(slug: String, listing: PanikShow?) async throws -> PanikShow {
        let html = try await getText(Self.site.appendingPathComponent("emissions/\(slug)/"))
        guard let show = PanikHTML.showDetail(in: html, slug: slug, listing: listing) else {
            throw PanikError.notFound
        }
        return show
    }

    // MARK: - Track logs

    /// What a show played on a given day. Panik keeps these for the
    /// continuous-music hours; most shows have none, and an empty answer here
    /// means exactly that rather than a failure.
    func fetchTracks(showSlug: String, on date: DateComponents) async -> [PanikTrack] {
        guard let year = date.year, let month = date.month, let day = date.day else { return [] }
        let path = "emissions/\(showSlug)/playlist/\(year)-\(month)-\(day)/"
        return await tracks(at: Self.site.appendingPathComponent(path))
    }

    /// The log a schedule row points at directly.
    func fetchTracks(path: String) async -> [PanikTrack] {
        guard let url = PanikHTML.absolute(path) else { return [] }
        return await tracks(at: url)
    }

    private func tracks(at url: URL) async -> [PanikTrack] {
        guard let html = try? await getText(url) else { return [] }
        return PanikHTML.tracks(in: html)
    }

    // MARK: - Transport

    private func getText(_ url: URL) async throws -> String {
        let data = try await get(url)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw PanikError.malformedResponse }
        return text
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json, application/rss+xml, text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw PanikError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw PanikError.transport(error.localizedDescription)
            }
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404
                ? PanikError.notFound
                : PanikError.badStatus(http.statusCode)
        }
        return data
    }
}
