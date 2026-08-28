//
//  KioskBrowseStore.swift
//  Indigo
//
//  The browsable side of Kiosk: the curated Moods playlists and the archive of
//  shows. Neither endpoint pages — Moods ship whole with the page and the
//  archive answers with its 100 most recent — so unlike NTS there is no feed
//  to walk, only a load and a reload.
//

import Foundation
import Observation

@Observable
final class KioskBrowseStore {
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

    private(set) var moods: [KioskMood] = []
    private(set) var moodsPhase: Phase = .idle

    private(set) var library: [KioskEpisode] = []
    private(set) var libraryPhase: Phase = .idle

    /// Live search against Kiosk's archive — not a filter over what's loaded.
    private(set) var searchResults: [KioskEpisode] = []
    private(set) var searchPhase: Phase = .idle
    private(set) var activeQuery = ""

    private(set) var episodeDetails: [String: KioskEpisodeDetail] = [:]
    private(set) var loadingEpisodeDetails: Set<String> = []
    private(set) var episodeDetailErrors: [String: String] = [:]

    @ObservationIgnored private let api = KioskAPI()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: Moods

    func loadMoodsIfNeeded() async {
        guard moods.isEmpty, moodsPhase != .loading else { return }
        await loadMoods()
    }

    func loadMoods() async {
        moodsPhase = .loading
        do {
            let playlists = try await api.fetchMoods()
            moods = playlists.compactMap { $0.asMood() }.filter { !$0.episodes.isEmpty }
            moodsPhase = moods.isEmpty
                ? .failed("Kiosk isn't publishing any moods right now.")
                : .loaded
        } catch is CancellationError {
            moodsPhase = .idle
        } catch {
            moodsPhase = .failed(message(for: error))
        }
    }

    func mood(id: String) -> KioskMood? {
        moods.first { $0.id == id }
    }

    func episode(slug: String) -> KioskEpisode? {
        library.first { $0.slug == slug }
            ?? searchResults.first { $0.slug == slug }
            ?? moods.lazy.flatMap(\.episodes).first { $0.slug == slug }
    }

    func episodeDetail(slug: String) -> KioskEpisodeDetail? { episodeDetails[slug] }
    func isLoadingEpisodeDetail(_ slug: String) -> Bool { loadingEpisodeDetails.contains(slug) }
    func episodeDetailError(_ slug: String) -> String? { episodeDetailErrors[slug] }

    func loadEpisodeDetailIfNeeded(slug: String) async {
        guard episodeDetails[slug] == nil, !loadingEpisodeDetails.contains(slug) else { return }
        loadingEpisodeDetails.insert(slug)
        episodeDetailErrors[slug] = nil
        defer { loadingEpisodeDetails.remove(slug) }

        do {
            let page = try await api.fetchEpisodePage(slug: slug)
            let dto = page.props.pageProps.episode
            guard let episode = dto.asEpisode(fallbackSlug: slug) else {
                throw KioskError.malformedResponse
            }

            var summary: String?
            var schedule: String?
            var related: [KioskEpisode] = []
            if let showSlug = dto.show?.slug, !showSlug.isEmpty,
               let showPage = try? await api.fetchShowPage(slug: showSlug) {
                summary = showPage.props.pageProps.show.excerpt
                schedule = showPage.props.pageProps.show.when
                related = (showPage.props.pageProps.episodes ?? [])
                    .compactMap { $0.asEpisode() }
                    .filter { $0.slug != episode.slug }
            }

            if related.isEmpty {
                related = fallbackRelated(to: episode)
            }

            episodeDetails[slug] = KioskEpisodeDetail(
                episode: episode,
                description: dto.description.flatMap { $0.isEmpty ? nil : HTMLText.decode($0) },
                tracklist: (dto.trackList ?? "").split(whereSeparator: \.isNewline)
                    .map { HTMLText.decode(String($0)).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                residencyName: dto.show?.name.map(HTMLText.decode),
                residencySummary: summary.map(HTMLText.decode),
                residencySchedule: schedule.map(HTMLText.decode),
                related: Array(related.prefix(8))
            )
        } catch is CancellationError {
        } catch {
            // Browse payloads still contain enough information for a useful
            // detail page even if this older episode's page has disappeared.
            if let episode = episode(slug: slug) {
                episodeDetails[slug] = KioskEpisodeDetail(
                    episode: episode,
                    description: nil,
                    tracklist: [],
                    residencyName: nil,
                    residencySummary: nil,
                    residencySchedule: nil,
                    related: fallbackRelated(to: episode)
                )
            } else {
                episodeDetailErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: Library

    func loadLibraryIfNeeded() async {
        guard library.isEmpty, libraryPhase != .loading else { return }
        await loadLibrary()
    }

    func loadLibrary() async {
        libraryPhase = .loading
        do {
            library = dedupe(try await api.fetchLibrary().compactMap { $0.asEpisode() })
            libraryPhase = .loaded
        } catch is CancellationError {
            libraryPhase = .idle
        } catch {
            libraryPhase = .failed(message(for: error))
        }
    }

    // MARK: Search

    var hasActiveSearch: Bool { !activeQuery.isEmpty }

    /// Debounced so typing doesn't fire a request per keystroke.
    func updateSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != activeQuery else { return }

        searchTask?.cancel()
        activeQuery = trimmed

        guard trimmed.count >= 2 else {
            searchResults = []
            searchPhase = .idle
            return
        }

        searchPhase = .loading
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    func retrySearch() async {
        guard !activeQuery.isEmpty else { return }
        await performSearch(activeQuery)
    }

    private func performSearch(_ query: String) async {
        searchPhase = .loading
        do {
            let response = try await api.search(query)
            // The user may have typed on while this was in flight.
            guard query == activeQuery else { return }
            searchResults = dedupe((response.episodeCollection?.items ?? []).compactMap { $0.asEpisode() })
            searchPhase = .loaded
        } catch is CancellationError {
        } catch {
            guard query == activeQuery else { return }
            searchPhase = .failed(message(for: error))
        }
    }

    // MARK: Helpers

    /// Kiosk files some broadcasts under more than one entry; identity is the
    /// episode slug.
    private func dedupe(_ episodes: [KioskEpisode]) -> [KioskEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.id).inserted }
    }

    /// Older Kiosk pages sometimes omit their residency link. In that case,
    /// rank the archive by shared genres so the page still offers a useful
    /// route forward without claiming those shows belong to one residency.
    private func fallbackRelated(to episode: KioskEpisode) -> [KioskEpisode] {
        let genres = Set(episode.genres.map { $0.lowercased() })
        let candidates = dedupe(library + moods.flatMap(\.episodes))
            .filter { $0.slug != episode.slug }

        return Array(candidates.sorted { left, right in
            let leftScore = Set(left.genres.map { $0.lowercased() }).intersection(genres).count
            let rightScore = Set(right.genres.map { $0.lowercased() }).intersection(genres).count
            if leftScore != rightScore { return leftScore > rightScore }
            return (left.airedAt ?? .distantPast) > (right.airedAt ?? .distantPast)
        }.prefix(8))
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
