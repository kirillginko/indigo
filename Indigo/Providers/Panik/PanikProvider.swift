//
//  PanikProvider.swift
//  Indigo
//
//  Radio Panik broadcasts from Saint-Josse in Brussels on 105.4 FM, and has
//  since 1983 — a free radio run by its own contributors, in French.
//
//  One channel. What is on the air comes from the station's own `onair.json`,
//  and the week around it from the published programme, because Panik gives a
//  start time per slot and no end: a slot runs until the next one begins, so
//  the calendar is what makes the on-air progress line possible at all.
//

import Foundation
import Observation

@Observable
final class PanikProvider: RadioProvider {
    nonisolated static let providerID = "panik"
    let displayName = "Radio Panik"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The station's own mark, for when there is no picture of what is on.
    static let logoURL = URL(string: "https://www.radiopanik.org/static/img/logo-panik-500.png")

    private(set) var onAir: PanikOnAir = .idle
    private(set) var schedule: [PanikScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Now / next and the on-air progress are derived from the clock, and
    /// @Observable only notices stored state — so the poll stamps the moment
    /// it read and everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = PanikAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var scheduleLoadedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Station

    let stations: [RadioStation] = [
        RadioStation(
            id: "panik.live",
            providerID: PanikProvider.providerID,
            name: "Radio Panik",
            shortName: "105.4",
            strapline: "Brussels",
            streamURL: PanikAPI.stream
        )
    ]

    var station: RadioStation { stations[0] }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    // MARK: - What is on

    /// The slot the calendar puts us in, which is the only thing that knows
    /// when the current show ends.
    var currentSlot: PanikScheduleEntry? {
        schedule.first { $0.contains(referenceDate) }
    }

    /// `onair.json` names what is actually going out, which is the truth when
    /// it and the calendar disagree; the calendar supplies the times.
    var now: RadioShow? {
        guard let title = onAir.title ?? currentSlot?.title else { return nil }
        let slot = currentSlot
        return RadioShow(
            title: title,
            host: onAir.subtitle,
            summary: nil,
            location: "Brussels",
            genres: slot?.categories ?? [],
            moods: [],
            artworkURL: nil,
            startsAt: slot?.startsAt,
            endsAt: slot?.endsAt,
            detailID: onAir.showSlug ?? slot?.showSlug
        )
    }

    var upNext: PanikScheduleEntry? {
        schedule.first { $0.startsAt > referenceDate }
    }

    /// What is left of the published week from now on.
    var upcoming: [PanikScheduleEntry] {
        schedule.filter { ($0.endsAt ?? $0.startsAt) > referenceDate }
    }

    /// The provider-independent item the player consumes.
    func mediaItem() -> MediaItem {
        MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: onAir.title ?? currentSlot?.title ?? "Live",
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
            onAir = try await api.fetchOnAir()
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

    /// The programme is a week at a time. It is also the more expensive of the
    /// two reads by far — a rendered page rather than a line of JSON — so the
    /// live poll does not drag it along every time.
    private func refreshScheduleIfStale() async {
        if let loaded = scheduleLoadedAt, Date.now.timeIntervalSince(loaded) < 1800, !schedule.isEmpty {
            return
        }
        guard let entries = try? await api.fetchSchedule(), !entries.isEmpty else { return }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
