//
//  Radio80000BrowseStore.swift
//  Indigo
//
//  The browsable side of Radio 80000: the recent broadcasts and the hundred
//  and ninety-three shows behind them.
//
//  The directory arrives whole — two pages of a hundred — so genre narrows it
//  on screen here rather than at the station, the way most of the other
//  stations work. The recent uploads are the shallow end: SoundCloud stops
//  that listing at a hundred, and the depth is inside each show's playlists,
//  which is what the show pages are for.
//

import Foundation
import Observation

@Observable
final class Radio80000BrowseStore {
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

    private(set) var latest: [Radio80000Episode] = []
    private(set) var latestPhase: Phase = .idle
    private(set) var isLoadingMore = false

    private(set) var shows: [Radio80000Show] = []
    private(set) var showsPhase: Phase = .idle

    private(set) var genres: [Radio80000Genre] = []

    private(set) var showEpisodes: [String: [Radio80000Episode]] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]
    private(set) var showDetails: [String: Radio80000Show] = [:]

    private(set) var details: [String: Radio80000Episode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = Radio80000API()
    @ObservationIgnored private var latestCursor: String?
    @ObservationIgnored private var latestExhausted = false
    /// Every broadcast a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: Radio80000Episode] = [:]
    /// Ids whose Mixcloud tracklist has already been asked for, so a page that
    /// genuinely has none does not ask again on every redraw.
    @ObservationIgnored private var tracklistsAsked: Set<String> = []

    // MARK: - Latest

    func loadLatestIfNeeded() async {
        guard latest.isEmpty, latestPhase != .loading else { return }
        await loadLatest()
    }

    func loadLatest() async {
        latestPhase = .loading
        latestExhausted = false
        latestCursor = nil
        do {
            let page = try await api.fetchLatest()
            latest = dedupe(page.episodes)
            remember(latest)
            latestCursor = page.nextCursor
            latestExhausted = page.nextCursor == nil
            latestPhase = .loaded
        } catch is CancellationError {
            latestPhase = .idle
        } catch {
            latestPhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { !latestExhausted && !isLoadingMore && !latest.isEmpty }

    func loadMore() async {
        guard canLoadMore, let cursor = latestCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchLatest(cursor: cursor)
            let merged = dedupe(latest + page.episodes)
            // A page that adds nothing is the end, whatever it claimed.
            guard merged.count > latest.count else {
                latestExhausted = true
                return
            }
            latest = merged
            remember(page.episodes)
            latestCursor = page.nextCursor
            latestExhausted = page.nextCursor == nil
        } catch is CancellationError {
        } catch {
            latestExhausted = true
            latestPhase = .failed(message(for: error))
        }
    }

    // MARK: - Shows

    func loadShowsIfNeeded() async {
        guard shows.isEmpty, showsPhase != .loading else { return }
        await loadShows()
    }

    /// Both pages at once. The directory is small enough to hold whole, which
    /// is what lets the page filter and search it without going back out.
    func loadShows() async {
        showsPhase = .loading
        do {
            async let first = api.fetchShows(page: 1)
            async let second = api.fetchShows(page: 2)
            let (one, two) = try await (first, second)

            var seen = Set<String>()
            shows = (one + two)
                .filter { seen.insert($0.slug).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            showsPhase = .loaded
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    func show(slug: String) -> Radio80000Show? {
        showDetails[slug] ?? shows.first { $0.slug == slug }
    }

    func episodes(ofShow slug: String) -> [Radio80000Episode] { showEpisodes[slug] ?? [] }
    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    func loadShowIfNeeded(slug: String) async {
        guard showEpisodes[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        do {
            // The directory may already have it; a cold open will not.
            let show: Radio80000Show
            if let known = self.show(slug: slug) {
                show = known
            } else {
                show = try await api.fetchShow(slug: slug)
            }
            showDetails[slug] = show

            let episodes = await api.fetchEpisodes(of: show)
            showEpisodes[slug] = episodes
            remember(episodes)
        } catch is CancellationError {
        } catch {
            showErrors[slug] = message(for: error)
        }
    }

    // MARK: - Genres

    /// Asked once and kept: the vocabulary does not change between launches.
    func loadGenresIfNeeded() async {
        guard genres.isEmpty else { return }
        guard let loaded = try? await api.fetchGenres() else { return }
        genres = loaded
    }

    // MARK: - Episodes

    func remember(_ episodes: [Radio80000Episode]) {
        for episode in episodes { known[episode.id] = episode }
    }

    func episode(id: String) -> Radio80000Episode? { details[id] ?? known[id] }
    func isLoadingDetail(_ id: String) -> Bool { loadingDetails.contains(id) }
    func detailError(_ id: String) -> String? { detailErrors[id] }

    func loadDetailIfNeeded(id: String) async {
        guard details[id] == nil, !loadingDetails.contains(id) else { return }

        // A Mixcloud broadcast already in hand still has no tracklist: that
        // only comes back on the single-cloudcast read. So a page opened from
        // a grid is topped up rather than left looking as though the station
        // logged nothing.
        if let existing = known[id] {
            guard case .mixcloud = Radio80000EpisodeID.parse(id),
                  existing.tracks.isEmpty,
                  tracklistsAsked.insert(id).inserted
            else { return }

            loadingDetails.insert(id)
            defer { loadingDetails.remove(id) }
            if let tracks = try? await api.fetchTracklist(id: id), !tracks.isEmpty {
                details[id] = existing.withTracks(tracks)
            }
            return
        }

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

    // MARK: - Helpers

    private func dedupe(_ episodes: [Radio80000Episode]) -> [Radio80000Episode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension Radio80000Episode {
    /// The same broadcast with its tracklist filled in.
    func withTracks(_ tracks: [Radio80000Track]) -> Radio80000Episode {
        Radio80000Episode(
            id: id,
            title: title,
            broadcastAt: broadcastAt,
            duration: duration,
            artworkURL: artworkURL,
            permalink: permalink,
            summary: summary,
            genres: genres,
            tracks: tracks,
            showSlug: showSlug,
            showTitle: showTitle,
            source: source
        )
    }
}
