//
//  RovrBrowseStore.swift
//  Indigo
//
//  The browsable side of ROVR: ten thousand seven hundred archived broadcasts,
//  the shows they belong to and the people who make them.
//
//  Everything about the archive narrows at the station — search, tags and
//  curator all — because with an archive this size anything narrowed on screen
//  would be narrowing the two dozen rows that happen to be loaded. The
//  directories are small enough to hold whole and are filtered here.
//

import Foundation
import Observation

@Observable
final class RovrBrowseStore {
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

    private(set) var broadcasts: [RovrBroadcast] = []
    private(set) var archivePhase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var archiveTotal = 0

    /// What the archive is currently narrowed by. All three reach the station.
    private(set) var selectedTags: Set<String> = []
    private(set) var searchQuery: String = ""
    private(set) var curatorFilter: String?

    private(set) var shows: [RovrShow] = []
    private(set) var showsPhase: Phase = .idle

    private(set) var curators: [RovrCurator] = []
    private(set) var curatorsPhase: Phase = .idle

    private(set) var tags: [RovrTag] = []

    private(set) var showDetails: [String: RovrShow] = [:]
    private(set) var showBroadcasts: [String: [RovrBroadcast]] = [:]
    private(set) var loadingShows: Set<String> = []
    private(set) var showErrors: [String: String] = [:]
    private(set) var curatorDetails: [String: RovrCurator] = [:]
    private(set) var curatorBroadcasts: [String: [RovrBroadcast]] = [:]
    private(set) var loadingCurators: Set<String> = []
    private(set) var curatorErrors: [String: String] = [:]

    private(set) var details: [String: RovrBroadcast] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = RovrAPI()
    @ObservationIgnored private var archivePage = 1
    @ObservationIgnored private var archivePageCount = 1
    /// Every broadcast a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: RovrBroadcast] = [:]

    // MARK: - The archive

    func loadArchiveIfNeeded() async {
        guard broadcasts.isEmpty, archivePhase != .loading else { return }
        await loadArchive()
    }

    func loadArchive() async {
        archivePhase = .loading
        do {
            let page = try await api.fetchArchive(
                page: 1,
                query: searchQuery.nilIfEmpty,
                tags: Array(selectedTags),
                curatorID: curatorFilter
            )
            broadcasts = dedupe(page.broadcasts)
            remember(broadcasts)
            archivePage = page.page
            archivePageCount = page.pageCount
            archiveTotal = page.total
            archivePhase = .loaded
        } catch is CancellationError {
            archivePhase = .idle
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool {
        !isLoadingMore && !broadcasts.isEmpty && archivePage < archivePageCount
    }

    func loadMore() async {
        guard canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchArchive(
                page: archivePage + 1,
                query: searchQuery.nilIfEmpty,
                tags: Array(selectedTags),
                curatorID: curatorFilter
            )
            let merged = dedupe(broadcasts + page.broadcasts)
            // A page that adds nothing is the end, whatever it claimed.
            guard merged.count > broadcasts.count else {
                archivePageCount = page.page
                return
            }
            broadcasts = merged
            remember(page.broadcasts)
            archivePage = page.page
            archivePageCount = page.pageCount
        } catch is CancellationError {
        } catch {
            archivePhase = .failed(message(for: error))
        }
    }

    /// The tag filter narrows at the station, so changing it starts the walk
    /// again rather than hiding rows already on screen.
    func setTags(_ values: Set<String>) {
        guard selectedTags != values else { return }
        selectedTags = values
        Task { await loadArchive() }
    }

    /// ROVR indexes the whole archive, so this is a real search of ten
    /// thousand broadcasts rather than of the two dozen loaded.
    func search(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard searchQuery != clean else { return }
        searchQuery = clean
        Task { await loadArchive() }
    }

    func setCuratorFilter(_ id: String?) {
        guard curatorFilter != id else { return }
        curatorFilter = id
        Task { await loadArchive() }
    }

    // MARK: - Shows

    func loadShowsIfNeeded() async {
        guard shows.isEmpty, showsPhase != .loading else { return }
        await loadShows()
    }

    /// Three pages of a hundred covers the roster, and holding it whole is
    /// what lets the page filter and search without going back out.
    func loadShows() async {
        showsPhase = .loading
        do {
            var found: [RovrShow] = []
            var page = 1
            while page <= 6 {
                let response = try await api.fetchShows(page: page)
                found += response.data.compactMap { $0.asShow() }
                guard page < (response.pageCount ?? 1) else { break }
                page += 1
            }
            var seen = Set<String>()
            shows = found
                .filter { seen.insert($0.documentID).inserted }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            showsPhase = .loaded
        } catch is CancellationError {
            showsPhase = .idle
        } catch {
            showsPhase = .failed(message(for: error))
        }
    }

    func show(id: String) -> RovrShow? {
        showDetails[id] ?? shows.first { $0.documentID == id }
    }

    func broadcasts(ofShow id: String) -> [RovrBroadcast] { showBroadcasts[id] ?? [] }
    func isLoadingShow(_ id: String) -> Bool { loadingShows.contains(id) }
    func showError(_ id: String) -> String? { showErrors[id] }

    /// A show's page is what it is and its run. The archive can be asked for
    /// one show's broadcasts directly, so this is a real filter of ten
    /// thousand rather than whatever the archive page happened to have loaded.
    func loadShowIfNeeded(id: String) async {
        guard showBroadcasts[id] == nil, !loadingShows.contains(id) else { return }
        loadingShows.insert(id)
        showErrors[id] = nil
        defer { loadingShows.remove(id) }

        do {
            if show(id: id) == nil {
                showDetails[id] = try await api.fetchShow(id: id)
            }
            let page = try await api.fetchArchive(page: 1, pageSize: 50, showID: id)
            showBroadcasts[id] = page.broadcasts
            remember(page.broadcasts)
        } catch is CancellationError {
        } catch {
            if show(id: id) != nil {
                showBroadcasts[id] = []
            } else {
                showErrors[id] = message(for: error)
            }
        }
    }

    // MARK: - Curators

    func loadCuratorsIfNeeded() async {
        guard curators.isEmpty, curatorsPhase != .loading else { return }
        await loadCurators()
    }

    func loadCurators() async {
        curatorsPhase = .loading
        do {
            var found: [RovrCurator] = []
            var page = 1
            while page <= 6 {
                let response = try await api.fetchCurators(page: page)
                found += response.data.compactMap { $0.asCurator() }
                guard page < (response.pageCount ?? 1) else { break }
                page += 1
            }
            var seen = Set<String>()
            curators = found
                .filter { seen.insert($0.documentID).inserted }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            curatorsPhase = .loaded
        } catch is CancellationError {
            curatorsPhase = .idle
        } catch {
            curatorsPhase = .failed(message(for: error))
        }
    }

    func curator(id: String) -> RovrCurator? {
        curatorDetails[id] ?? curators.first { $0.documentID == id }
    }

    func broadcasts(byCurator id: String) -> [RovrBroadcast] { curatorBroadcasts[id] ?? [] }
    func isLoadingCurator(_ id: String) -> Bool { loadingCurators.contains(id) }
    func curatorError(_ id: String) -> String? { curatorErrors[id] }

    /// A curator's page is their biography and their run, and the archive can
    /// be asked for one curator's broadcasts directly.
    func loadCuratorIfNeeded(id: String) async {
        guard curatorBroadcasts[id] == nil, !loadingCurators.contains(id) else { return }
        loadingCurators.insert(id)
        curatorErrors[id] = nil
        defer { loadingCurators.remove(id) }

        do {
            if curator(id: id) == nil {
                curatorDetails[id] = try await api.fetchCurator(id: id)
            }
            let page = try await api.fetchArchive(page: 1, pageSize: 50, curatorID: id)
            curatorBroadcasts[id] = page.broadcasts
            remember(page.broadcasts)
        } catch is CancellationError {
        } catch {
            if curator(id: id) != nil {
                curatorBroadcasts[id] = []
            } else {
                curatorErrors[id] = message(for: error)
            }
        }
    }

    // MARK: - Tags

    /// Asked once and kept: eight words that do not change between launches.
    func loadTagsIfNeeded() async {
        guard tags.isEmpty else { return }
        guard let loaded = try? await api.fetchTags() else { return }
        tags = loaded
    }

    /// The station filters on a tag's `type` and shows its `label`, and the
    /// two are different words — so the bar works in labels and this turns
    /// them back into what the archive understands.
    func tagTypes(forLabels labels: Set<String>) -> Set<String> {
        Set(tags.filter { labels.contains($0.label) }.map(\.type))
    }

    func tagLabels(forTypes types: Set<String>) -> Set<String> {
        Set(tags.filter { types.contains($0.type) }.map(\.label))
    }

    // MARK: - Broadcasts

    func remember(_ broadcasts: [RovrBroadcast]) {
        for broadcast in broadcasts { known[broadcast.documentID] = broadcast }
    }

    func broadcast(id: String) -> RovrBroadcast? { details[id] ?? known[id] }
    func isLoadingDetail(_ id: String) -> Bool { loadingDetails.contains(id) }
    func detailError(_ id: String) -> String? { detailErrors[id] }

    func loadDetailIfNeeded(id: String) async {
        guard details[id] == nil, known[id] == nil, !loadingDetails.contains(id) else { return }
        loadingDetails.insert(id)
        detailErrors[id] = nil
        defer { loadingDetails.remove(id) }

        do {
            let broadcast = try await api.fetchBroadcast(id: id)
            details[id] = broadcast
            remember([broadcast])
        } catch is CancellationError {
        } catch {
            detailErrors[id] = message(for: error)
        }
    }

    // MARK: - Helpers

    private func dedupe(_ broadcasts: [RovrBroadcast]) -> [RovrBroadcast] {
        var seen = Set<String>()
        return broadcasts.filter { seen.insert($0.documentID).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
