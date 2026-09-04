//
//  LotBrowseStore.swift
//  Indigo
//
//  The browsable side of The Lot: the Index — every broadcast the station has
//  archived, some three and a half thousand of them — and the Shows directory
//  of residencies behind it.
//
//  The Index is cursor-paged rather than loaded whole, so what a page can say
//  about itself is always "N of M so far" rather than a total it is pretending
//  to hold.
//

import Foundation
import Observation

@Observable
final class LotBrowseStore {
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

    private(set) var episodes: [LotEpisode] = []
    private(set) var indexPhase: Phase = .idle
    private(set) var indexTotal = 0
    private(set) var isLoadingMore = false
    /// Nil once the archive has been walked to its end, or when the site is
    /// answering from the page fallback and there is no cursor to go on with.
    private(set) var indexCursor: String?

    private(set) var shows: [LotShow] = []
    private(set) var showsPhase: Phase = .idle
    private(set) var showsTotal = 0

    private(set) var showDetails: [String: LotShowDetail] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]

    private(set) var episodeDetails: [String: LotEpisodeDetail] = [:]
    private(set) var loadingEpisodes: Set<String> = []
    private(set) var episodeErrors: [String: String] = [:]

    @ObservationIgnored private let api = LotAPI()
    /// Every episode seen anywhere, keyed by its show/episode handle. A detail
    /// page opened from a grid needs no round trip to know what it is about.
    @ObservationIgnored private var known: [String: LotEpisode] = [:]

    private static let pageSize = 48

    // MARK: - The Index

    func loadIndexIfNeeded() async {
        guard episodes.isEmpty, indexPhase != .loading else { return }
        await loadIndex()
    }

    func loadIndex() async {
        indexPhase = .loading
        do {
            let feed = try await api.fetchEpisodes(limit: Self.pageSize)
            episodes = dedupe(feed.episodes)
            remember(episodes)
            indexCursor = feed.cursor
            indexTotal = max(feed.total, episodes.count)
            indexPhase = .loaded
        } catch is CancellationError {
            indexPhase = .idle
        } catch {
            indexPhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { indexCursor != nil && !isLoadingMore }

    func loadMore() async {
        guard let cursor = indexCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let feed = try await api.fetchEpisodes(limit: Self.pageSize, cursor: cursor)
            let merged = dedupe(episodes + feed.episodes)
            // A cursor that returns nothing new is the end of the archive,
            // however it answered.
            guard merged.count > episodes.count else {
                indexCursor = nil
                return
            }
            episodes = merged
            remember(feed.episodes)
            indexCursor = feed.cursor
            indexTotal = max(indexTotal, episodes.count)
        } catch is CancellationError {
        } catch {
            // Paging failures are not worth wiping a loaded page for; stop
            // walking and let the listener retry.
            indexCursor = nil
            indexPhase = .failed(message(for: error))
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
            var collected: [LotShow] = []
            var total = 0
            var failure: (any Error)?
            // The directory is small and alphabetical; walking it whole is
            // what makes searching it honest. The page count is bounded so a
            // server that stops advancing can't spin here.
            for _ in 0..<12 {
                do {
                    let page = try await api.fetchShows(limit: LotAPI.maxPageSize, skip: collected.count)
                    total = page.total
                    guard !page.shows.isEmpty else { break }
                    collected += page.shows
                    if collected.count >= total { break }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A page failing part-way stops the walk. It does not
                    // throw away the pages that did arrive: The Lot only
                    // server-renders the first twenty residencies, so when
                    // paging is unavailable those twenty are the whole of what
                    // Indigo can know — and twenty is a directory. Discarding
                    // them for an error screen was how a dead action id took
                    // the Shows page down entirely.
                    failure = error
                    break
                }
            }
            shows = collected
            // A detail request and the directory request can finish in either
            // order on a cold open. Enrich already-open details once the
            // directory's more complete cards arrive.
            let currentDetails = showDetails
            for (slug, detail) in currentDetails {
                guard let directoryShow = collected.first(where: { $0.slug == slug }) else { continue }
                showDetails[slug] = LotShowDetail(
                    show: detail.show.fillingMissingFields(from: directoryShow),
                    summary: detail.summary,
                    episodes: detail.episodes
                )
            }
            showsTotal = max(total, collected.count)
            showsPhase = if !collected.isEmpty {
                .loaded
            } else if let failure {
                .failed(message(for: failure))
            } else {
                .failed("The Lot isn't publishing any shows right now.")
            }
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    func show(slug: String) -> LotShow? {
        showDetails[slug]?.show ?? shows.first { $0.slug == slug }
    }

    func showDetail(slug: String) -> LotShowDetail? { showDetails[slug] }
    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    func loadShowIfNeeded(slug: String) async {
        guard showDetails[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        do {
            let page = try await api.fetchShowPage(slug: slug)
            let directoryShow = shows.first { $0.slug == slug }
            let show = page.show?.fillingMissingFields(from: directoryShow) ?? directoryShow
            guard let show else { throw LotError.malformedResponse }

            // The page server-renders only the first handful of broadcasts.
            // A residency's whole run is short enough to ask for outright.
            var episodes = page.episodes
            if page.cursor != nil || episodes.count < page.total {
                if let feed = try? await api.fetchEpisodes(
                    limit: LotAPI.maxPageSize,
                    filters: LotEpisodeFilters(shows: [show.name])
                ), !feed.episodes.isEmpty {
                    episodes = dedupe(feed.episodes + episodes)
                }
            }
            episodes.sort { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }
            remember(episodes)

            showDetails[slug] = LotShowDetail(show: show, summary: page.summary, episodes: episodes)
        } catch is CancellationError {
        } catch {
            if let show = shows.first(where: { $0.slug == slug }) {
                // The directory entry is still a real page: name, artwork,
                // genres, residents, and whatever broadcasts are in hand.
                showDetails[slug] = LotShowDetail(
                    show: show,
                    summary: nil,
                    episodes: known.values
                        .filter { $0.show?.slug == slug }
                        .sorted { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }
                )
            } else {
                showErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: - Episodes

    /// Keeps every episode a grid has rendered, so opening one is instant and
    /// so a detail page always has something to show while the note loads.
    func remember(_ episodes: [LotEpisode]) {
        for episode in episodes {
            guard let ref = episode.ref else { continue }
            known[ref.encoded] = episode
        }
    }

    func episode(ref: LotEpisodeRef) -> LotEpisode? {
        episodeDetails[ref.encoded]?.episode ?? known[ref.encoded]
    }

    func episodeDetail(ref: LotEpisodeRef) -> LotEpisodeDetail? { episodeDetails[ref.encoded] }
    func isLoadingEpisode(_ ref: LotEpisodeRef) -> Bool { loadingEpisodes.contains(ref.encoded) }
    func episodeError(_ ref: LotEpisodeRef) -> String? { episodeErrors[ref.encoded] }

    func loadEpisodeIfNeeded(ref: LotEpisodeRef) async {
        let key = ref.encoded
        guard episodeDetails[key] == nil, !loadingEpisodes.contains(key) else { return }
        loadingEpisodes.insert(key)
        episodeErrors[key] = nil
        defer { loadingEpisodes.remove(key) }

        // The page carries the session note and the rest of the residency; the
        // broadcast itself comes from wherever it was already seen, or from
        // its residency if this is a cold open out of the crate.
        let page = try? await api.fetchEpisodePage(ref: ref)
        if let page { remember(page.related) }

        var episode = known[key]
        if episode == nil {
            await loadShowIfNeeded(slug: ref.show)
            episode = showDetails[ref.show]?.episodes.first { $0.slug == ref.episode } ?? known[key]
        }

        guard let episode else {
            episodeErrors[key] = "The Lot is no longer publishing this broadcast."
            return
        }

        var related = page?.related ?? []
        if related.isEmpty {
            related = (showDetails[ref.show]?.episodes ?? []).filter { $0.slug != ref.episode }
        }
        related.sort { ($0.airedAt ?? .distantPast) > ($1.airedAt ?? .distantPast) }

        episodeDetails[key] = LotEpisodeDetail(
            episode: episode,
            summary: page?.summary,
            related: Array(related.prefix(12))
        )
    }

    // MARK: - Helpers

    private func dedupe(_ episodes: [LotEpisode]) -> [LotEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
