//
//  LYLProvider.swift
//  Indigo
//
//  LYL Radio broadcasts from studios in Lyon, Paris, Marseille and Brussels,
//  and from a network of contributors beyond them. One channel, streamed as
//  HLS, with the address published alongside what is currently on it.
//

import Foundation
import Observation

@Observable
final class LYLProvider: RadioProvider {
    nonisolated static let providerID = "lyl"
    let displayName = "LYL Radio"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Known up front so the Listen button works before the first poll, and
    /// still works if the endpoint goes quiet. LYL publishes the same address
    /// through `onair`, and that one wins once it arrives.
    private static let fallbackStream = URL(string: "https://radio.lyl.live/hls/live.m3u8")!

    /// The station's own mark, for when there is no picture of what is on.
    static let logoURL = URL(string: "https://lyl.live/favicon.ico")

    private(set) var onAirTitle: String?
    private(set) var streamURL: URL = LYLProvider.fallbackStream
    private(set) var schedule: [LYLScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Now / next are derived from the clock, and @Observable only notices
    /// stored state — so the poll stamps the moment it read and everything
    /// downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = LYLAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var scheduleLoadedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Station

    var stations: [RadioStation] {
        [
            RadioStation(
                id: "lyl.live",
                providerID: Self.providerID,
                name: "LYL Radio",
                shortName: "LYL",
                strapline: "Lyon / Paris",
                streamURL: streamURL
            )
        ]
    }

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - Schedule

    var onAir: LYLScheduleEntry? {
        schedule.first { $0.contains(referenceDate) }
    }

    var upNext: LYLScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the calendar from now on, for the schedule list.
    var upcoming: [LYLScheduleEntry] {
        schedule.filter { $0.endsAt > referenceDate }
    }

    var now: RadioShow? {
        // `onair` names what is actually going out, which can differ from the
        // calendar when a slot runs over or a guest takes the desk.
        if let onAirTitle {
            guard let entry = onAir else {
                return RadioShow(
                    title: onAirTitle,
                    host: nil,
                    summary: nil,
                    location: "Lyon / Paris",
                    genres: [],
                    moods: [],
                    artworkURL: nil,
                    startsAt: nil,
                    endsAt: nil,
                    detailID: nil
                )
            }
            return RadioShow(
                title: onAirTitle,
                host: entry.artists,
                summary: nil,
                location: "Lyon / Paris",
                genres: [],
                moods: [],
                artworkURL: nil,
                startsAt: entry.startsAt,
                endsAt: entry.endsAt,
                detailID: entry.episodeSlug
            )
        }
        return onAir?.asRadioShow()
    }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAirTitle ?? onAir?.title ?? "Live",
            detail: station.strapline,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    func beginWatching() {
        watchers += 1
        startPolling()
        Task { await refresh() }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.watchers > 0 ? 45.0 : 300.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    func refresh() async {
        if case .loaded = loadState {} else if lastUpdated == nil {
            loadState = .loading
        }

        do {
            let onair = try await api.fetchOnAir()
            onAirTitle = onair.title
            if let published = onair.streamURL { streamURL = published }
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
            await refreshScheduleIfStale()
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last known state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }

    /// The calendar changes by the week, not by the minute.
    private func refreshScheduleIfStale() async {
        if let loaded = scheduleLoadedAt, Date.now.timeIntervalSince(loaded) < 1800, !schedule.isEmpty {
            return
        }
        let from = Date.now.addingTimeInterval(-6 * 3600)
        let to = Date.now.addingTimeInterval(7 * 24 * 3600)
        guard let entries = try? await api.fetchSchedule(from: from, to: to), !entries.isEmpty else { return }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
