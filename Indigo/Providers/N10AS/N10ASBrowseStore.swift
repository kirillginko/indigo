//
//  N10ASBrowseStore.swift
//  Indigo
//
//  The browsable side of n10.as: the archive, the directory, and the join
//  between them that the station does not publish.
//
//  The directory arrives whole in one request, so genre and search narrow it
//  on screen here rather than at the station. The archive is the opposite —
//  11,849 uploads in one flat Mixcloud feed, paged fifty at a time, and there
//  is no listing anywhere of which of them belong to which show.
//
//  So a show's run is assembled from two sources that are each incomplete on
//  their own: a search of the station's Mixcloud account, which is fast and
//  usually good but has no guaranteed recall, and whatever the archive
//  listing has already been scrolled through, which is exact but shallow.
//  Both are matched on the programme read out of the broadcast's title, and
//  the page says how many it found rather than implying that is all there is.
//

import Foundation
import Observation

@Observable
final class N10ASBrowseStore {
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

    private(set) var archive: [N10ASEpisode] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var isLoadingMore = false
    /// How many broadcasts the station has published altogether, so a page of
    /// fifty can say what it is a page of.
    private(set) var archiveTotal: Int?

    private(set) var shows: [N10ASShow] = []
    private(set) var showsPhase: Phase = .idle

    private(set) var showRuns: [String: [N10ASEpisode]] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]
    private(set) var showDetails: [String: N10ASShow] = [:]

    private(set) var details: [String: N10ASEpisode] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = N10ASAPI()
    @ObservationIgnored private var archiveCursor: String?
    @ObservationIgnored private var archiveExhausted = false
    /// Every broadcast a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: N10ASEpisode] = [:]

    // MARK: - Archive

    func loadArchiveIfNeeded() async {
        guard archive.isEmpty, archivePhase != .loading else { return }
        await loadArchive()
    }

    func loadArchive() async {
        archivePhase = .loading
        archiveExhausted = false
        archiveCursor = nil
        do {
            let page = try await api.fetchArchive()
            archive = dedupe(page.episodes)
            remember(archive)
            archiveCursor = page.nextCursor
            archiveExhausted = page.nextCursor == nil
            archivePhase = .loaded
            if archiveTotal == nil { archiveTotal = await api.fetchArchiveCount() }
        } catch is CancellationError {
            archivePhase = .idle
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { !archiveExhausted && !isLoadingMore && !archive.isEmpty }

    func loadMore() async {
        guard canLoadMore, let cursor = archiveCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchArchive(cursor: cursor)
            let merged = dedupe(archive + page.episodes)
            // A page that adds nothing is the end, whatever it claimed.
            guard merged.count > archive.count else {
                archiveExhausted = true
                return
            }
            archive = merged
            remember(page.episodes)
            archiveCursor = page.nextCursor
            archiveExhausted = page.nextCursor == nil
        } catch is CancellationError {
        } catch {
            archiveExhausted = true
            archivePhase = .failed(message(for: error))
        }
    }

    // MARK: - Shows

    /// The show a name belongs to, for a row that kept only the name.
    ///
    /// RadioCult says what is on air and gives no identifier, so a show crated
    /// mid-broadcast knows what it was called and nothing else. The directory
    /// is loaded on demand: somebody may never have opened the Shows page,
    /// and a crate row should not depend on their having done so.
    ///
    /// Nil for a name that matches nothing — half the archive's programmes
    /// have ended their run and left the directory, and the caller falls back
    /// rather than inventing a slug.
    func showDestination(named title: String) async -> DetailPage? {
        let wanted = N10ASTitle.matchKey(title)
        guard !wanted.isEmpty else { return nil }
        await loadShowsIfNeeded()
        guard let match = shows.first(where: { N10ASTitle.matchKey($0.title) == wanted })
        else { return nil }
        return .n10asShow(slug: match.slug)
    }

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

    func show(slug: String) -> N10ASShow? {
        showDetails[slug] ?? shows.first { $0.slug == slug }
    }

    func isLoadingShow(_ slug: String) -> Bool { loadingShows.contains(slug) }
    func showError(_ slug: String) -> String? { showErrors[slug] }

    /// One show's broadcasts, newest first.
    ///
    /// The searched run and the scrolled archive are merged at read time
    /// rather than at load time, so paging the Archive page deepens every
    /// show page that is open behind it without either knowing about the
    /// other.
    func episodes(ofShow slug: String) -> [N10ASEpisode] {
        guard let show = show(slug: slug) else { return showRuns[slug] ?? [] }
        let wanted = N10ASTitle.matchKey(show.title)
        let fromArchive = archive.filter { episode in
            guard let programme = episode.programme else { return false }
            return N10ASTitle.matchKey(programme) == wanted
        }
        return dedupe((showRuns[slug] ?? []) + fromArchive)
            .sorted { ($0.broadcastAt ?? .distantPast) > ($1.broadcastAt ?? .distantPast) }
    }

    func loadShowIfNeeded(slug: String) async {
        guard showRuns[slug] == nil, !loadingShows.contains(slug) else { return }
        loadingShows.insert(slug)
        showErrors[slug] = nil
        defer { loadingShows.remove(slug) }

        do {
            // The directory may already have it; a cold open will not.
            let show: N10ASShow
            if let held = self.show(slug: slug) {
                show = held
            } else {
                show = try await api.fetchShow(slug: slug)
            }
            showDetails[slug] = show

            let found = await api.searchEpisodes(title: show.title)
            // An empty result is still an answer — it stops the page asking
            // again on every redraw, and `episodes(ofShow:)` still merges
            // anything the archive listing turns up later.
            showRuns[slug] = dedupe(found)
                .sorted { ($0.broadcastAt ?? .distantPast) > ($1.broadcastAt ?? .distantPast) }
            remember(found)
        } catch is CancellationError {
        } catch {
            showErrors[slug] = message(for: error)
        }
    }

    // MARK: - Episodes

    func remember(_ episodes: [N10ASEpisode]) {
        for episode in episodes { known[episode.id] = episode }
    }

    func episode(id: String) -> N10ASEpisode? { details[id] ?? known[id] }
    func isLoadingDetail(_ id: String) -> Bool { loadingDetails.contains(id) }
    func detailError(_ id: String) -> String? { detailErrors[id] }

    /// Mixcloud's listing already carries everything n10.as publishes about a
    /// broadcast — there is no tracklist to top up, because the station logs
    /// none — so a broadcast already in hand needs no second request.
    func loadDetailIfNeeded(id: String) async {
        guard details[id] == nil, !loadingDetails.contains(id) else { return }
        if known[id] != nil { return }

        loadingDetails.insert(id)
        detailErrors[id] = nil
        defer { loadingDetails.remove(id) }

        do {
            let episode = try await api.fetchEpisode(slug: id)
            details[id] = episode
            remember([episode])
        } catch is CancellationError {
        } catch {
            detailErrors[id] = message(for: error)
        }
    }

    /// Other broadcasts of the same programme, for the foot of an episode
    /// page. Read out of what is already loaded — opening one broadcast is
    /// not a reason to go looking for its whole run.
    func siblings(of episode: N10ASEpisode) -> [N10ASEpisode] {
        guard let programme = episode.programme else { return [] }
        let wanted = N10ASTitle.matchKey(programme)
        guard !wanted.isEmpty else { return [] }

        let pool = (showRuns.values.flatMap { $0 }) + archive
        return dedupe(pool)
            .filter { other in
                guard other.id != episode.id, let name = other.programme else { return false }
                return N10ASTitle.matchKey(name) == wanted
            }
            .sorted { ($0.broadcastAt ?? .distantPast) > ($1.broadcastAt ?? .distantPast) }
    }

    /// The directory entry a broadcast belongs to, when the station still
    /// lists that programme. Half the archive's shows have ended and are not
    /// in the directory at all, which is why this is optional everywhere it
    /// is used.
    func directoryShow(for episode: N10ASEpisode) -> N10ASShow? {
        guard let programme = episode.programme else { return nil }
        let wanted = N10ASTitle.matchKey(programme)
        guard !wanted.isEmpty else { return nil }
        return shows.first { N10ASTitle.matchKey($0.title) == wanted }
    }

    // MARK: - Helpers

    private func dedupe(_ episodes: [N10ASEpisode]) -> [N10ASEpisode] {
        var seen = Set<String>()
        return episodes.filter { seen.insert($0.id).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
