//
//  AlharaBrowseStore.swift
//  Indigo
//
//  alHara's recorded shows. The station hosts no archive itself, so this reads
//  the one it keeps on Mixcloud — a hundred and forty-odd shows, nearly all of
//  them from 2020, which is the year the station started and broadcast almost
//  continuously.
//

import Foundation
import Observation

@Observable
final class AlharaBrowseStore {
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

    private(set) var shows: [AlharaShow] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false

    private(set) var details: [String: AlharaShow] = [:]
    private(set) var loadingDetails: Set<String> = []
    private(set) var detailErrors: [String: String] = [:]

    @ObservationIgnored private let api = AlharaAPI()
    @ObservationIgnored private var next: URL?
    /// Every show a grid has rendered, so opening one is instant.
    @ObservationIgnored private var known: [String: AlharaShow] = [:]

    // MARK: - The archive

    func loadIfNeeded() async {
        guard shows.isEmpty, phase != .loading else { return }
        await load()
    }

    func load() async {
        phase = .loading
        do {
            let page = try await api.fetchArchive()
            shows = dedupe(page.shows)
            remember(shows)
            next = page.next
            phase = .loaded
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    var canLoadMore: Bool { next != nil && !isLoadingMore }

    func loadMore() async {
        guard let cursor = next, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.fetchArchive(cursor: cursor)
            let merged = dedupe(shows + page.shows)
            // A cursor that returns nothing new is the end, however it answered.
            guard merged.count > shows.count else {
                next = nil
                return
            }
            shows = merged
            remember(page.shows)
            next = page.next
        } catch is CancellationError {
        } catch {
            next = nil
            phase = .failed(message(for: error))
        }
    }

    /// The span the archive actually covers, so the page can say so rather
    /// than implying the station still uploads.
    var yearRange: (first: String, last: String)? {
        let years = shows.compactMap { show -> String? in
            guard let date = show.publishedAt else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy"
            return formatter.string(from: date)
        }.sorted()
        guard let first = years.first, let last = years.last else { return nil }
        return (first, last)
    }

    // MARK: - One show

    func remember(_ shows: [AlharaShow]) {
        for show in shows { known[show.slug] = show }
    }

    func show(slug: String) -> AlharaShow? { details[slug] ?? known[slug] }
    func isLoadingDetail(_ slug: String) -> Bool { loadingDetails.contains(slug) }
    func detailError(_ slug: String) -> String? { detailErrors[slug] }

    /// The listing leaves out the description and tracklist, so a detail page
    /// asks for the show again — even when it already has the tile's version.
    func loadDetailIfNeeded(slug: String) async {
        guard details[slug] == nil, !loadingDetails.contains(slug) else { return }
        loadingDetails.insert(slug)
        detailErrors[slug] = nil
        defer { loadingDetails.remove(slug) }

        do {
            let show = try await api.fetchShow(slug: slug)
            details[slug] = show
            remember([show])
        } catch is CancellationError {
        } catch {
            // The listing entry is still a real page: title, artwork, date and
            // something to play.
            if known[slug] == nil {
                detailErrors[slug] = message(for: error)
            }
        }
    }

    // MARK: - Helpers

    private func dedupe(_ shows: [AlharaShow]) -> [AlharaShow] {
        var seen = Set<String>()
        return shows.filter { seen.insert($0.slug).inserted }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
