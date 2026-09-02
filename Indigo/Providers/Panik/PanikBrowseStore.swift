//
//  PanikBrowseStore.swift
//  Indigo
//
//  The browsable side of Radio Panik: the recent broadcasts and the hundred
//  and twenty-four shows behind them.
//
//  The directory arrives whole in one request, so category and search narrow
//  it here rather than at the station — which is also the only way Indigo can
//  search Panik at all: the station's robots.txt reserves `/recherche/`, so
//  searching means searching what has been loaded, and the pages say so.
//

import Foundation
import Observation

@Observable
final class PanikBrowseStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)

        var isLoading: Bool { self == .loading }
        var error: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    // MARK: State

    private(set) var podcasts: [PanikEpisode] = []
    private(set) var podcastsPhase: Phase = .idle

    private(set) var shows: [PanikShow] = []
    private(set) var showsPhase: Phase = .idle

    private(set) var showEpisodes: [String: [PanikEpisode]] = [:]
    private(set) var showDetails: [String: PanikShow] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]

    private(set) var details: [String: PanikEpisode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    /// Track logs, by the path they were read from. Most broadcasts have none,
    /// so a miss is remembered too — otherwise every redraw asks again.
    private(set) var tracks: [String: [PanikTrack]] = [:]
    private(set) var loadingTracks: Set<String> = []

    @ObservationIgnored private let api = PanikAPI()
    /// Every broadcast a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: PanikEpisode] = [:]

    // MARK: - Recent broadcasts

    func loadPodcastsIfNeeded() async {
        guard podcasts.isEmpty, podcastsPhase != .loading else { return }
        await loadPodcasts()
    }

    func loadPodcasts() async {
        podcastsPhase = .loading
        do {
            let episodes = try await api.fetchPodcasts()
            podcasts = dedupe(episodes)
            remember(podcasts)
            podcastsPhase = .loaded
        } catch is CancellationError {
            podcastsPhase = .idle
        } catch {
            podcastsPhase = .failed(message(for: error))
        }
    }

    // MARK: - Shows

    func loadShowsIfNeeded() async {
        guard shows.isEmpty, showsPhase != .loading else { return }
        await loadShows()
    }

    func loadShows() async {
        showsPhase = .loading
        do {
            shows = try await api.fetchShows()
            showsPhase = .loaded
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    func show(slug: String) -> PanikShow? {
        showDetails[slug] ?? shows.first { $0.slug == slug }
    }

    func episodes(ofShow slug: String) -> [PanikEpisode] { showEpisodes[slug] ?? [] }
    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    func loadShowIfNeeded(slug: String) async {
        guard showEpisodes[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        let listing = shows.first { $0.slug == slug }
        do {
            async let detail = api.fetchShow(slug: slug, listing: listing)
            async let run = api.fetchEpisodes(showSlug: slug, showTitle: listing?.title)
            let (show, episodes) = try await (detail, run)
            showDetails[slug] = show
            showEpisodes[slug] = episodes
            remember(episodes)
        } catch is CancellationError {
        } catch {
            // A show with no podcast feed is a show that has never been
            // recorded, not a page that failed — and its own page still works.
            if let show = try? await api.fetchShow(slug: slug, listing: listing) {
                showDetails[slug] = show
                showEpisodes[slug] = []
            } else if listing != nil {
                showEpisodes[slug] = []
            } else {
                showErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: - Broadcasts

    func remember(_ episodes: [PanikEpisode]) {
        for episode in episodes { known[episode.id] = episode }
    }

    func episode(id: String) -> PanikEpisode? { details[id] ?? known[id] }
    func isLoadingDetail(_ id: String) -> Bool { loadingDetails.contains(id) }
    func detailError(_ id: String) -> String? { detailErrors[id] }

    func loadDetailIfNeeded(id: String) async {
        guard details[id] == nil, known[id] == nil, !loadingDetails.contains(id) else { return }
        loadingDetails.insert(id)
        detailErrors[id] = nil
        defer { loadingDetails.remove(id) }

        do {
            let episode = try await api.fetchEpisode(id: id)
            details[id] = episode
            remember([episode])
        } catch is CancellationError {
        } catch {
            detailErrors[id] = message(for: error)
        }
    }

    // MARK: - Track logs

    func tracks(forShow slug: String, on date: DateComponents) -> [PanikTrack] {
        tracks[key(slug, date)] ?? []
    }

    func isLoadingTracks(forShow slug: String, on date: DateComponents) -> Bool {
        loadingTracks.contains(key(slug, date))
    }

    /// Asked once per show and day, whether or not it turns anything up: most
    /// broadcasts have no log, and an empty answer is the answer.
    func loadTracksIfNeeded(forShow slug: String, on date: DateComponents) async {
        let identity = key(slug, date)
        guard tracks[identity] == nil, !loadingTracks.contains(identity) else { return }
        loadingTracks.insert(identity)
        defer { loadingTracks.remove(identity) }
        tracks[identity] = await api.fetchTracks(showSlug: slug, on: date)
    }

    private func key(_ slug: String, _ date: DateComponents) -> String {
        "\(slug)|\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)"
    }

    // MARK: - Helpers

    private func dedupe(_ episodes: [PanikEpisode]) -> [PanikEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
