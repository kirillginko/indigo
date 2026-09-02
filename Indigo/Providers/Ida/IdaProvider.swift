//
//  IdaProvider.swift
//  Indigo
//
//  IDA Radio broadcasts from Telliskivi in Tallinn, and since 2023 from a
//  second studio in Helsinki — two channels running their own schedules at
//  once, which is the thing that shapes this provider.
//
//  Everything live arrives in a single call: `/api/live` answers with what is
//  on each channel, what follows on each, and the two stream addresses. The
//  calendar is a second call, because IDA has no schedule resource — its
//  schedule is simply its episodes with their broadcast times.
//

import Foundation
import Observation

@Observable
final class IdaProvider: RadioProvider {
    nonisolated static let providerID = "ida"
    let displayName = "IDA Radio"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// The station's own mark, for when there is no picture of what is on.
    static let logoURL = URL(string: "https://idaidaida.net/favicon.ico")

    private(set) var channels: [IdaChannel: IdaChannelState] = [:]
    private(set) var schedule: [IdaScheduleEntry] = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Now / next and the on-air progress are derived from the clock, and
    /// @Observable only notices stored state — so the poll stamps the moment
    /// it read and everything downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = IdaAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var scheduleLoadedAt: Date?

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Stations

    /// Both channels, always. Unlike alHara's relays these are two genuinely
    /// different schedules — Helsinki is not carrying Tallinn when it has
    /// nothing on — so neither is ever hidden.
    var stations: [RadioStation] {
        IdaChannel.allCases.map { channel in
            RadioStation(
                id: channel.stationID,
                providerID: Self.providerID,
                name: channel.name,
                shortName: channel.shortName,
                strapline: channel.city,
                streamURL: channels[channel]?.streamURL ?? channel.fallbackStream
            )
        }
    }

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    func channel(for stationID: String) -> IdaChannel? {
        IdaChannel.allCases.first { $0.stationID == stationID }
    }

    // MARK: - What is on

    func state(for channel: IdaChannel) -> IdaChannelState {
        channels[channel] ?? .idle
    }

    func now(for channel: IdaChannel) -> RadioShow? {
        state(for: channel).asRadioShow(city: channel.city)
    }

    /// The channel worth opening on: whichever is actually broadcasting,
    /// preferring Tallinn, which is the station's home.
    var liveChannel: IdaChannel? {
        IdaChannel.allCases.first { state(for: $0).isOnAir }
    }

    /// The calendar for one channel from now on.
    func upcoming(on channel: IdaChannel) -> [IdaScheduleEntry] {
        schedule.filter { $0.channel == channel && $0.endsAt > referenceDate }
    }

    /// The provider-independent item the player consumes.
    func mediaItem(for stationID: String) -> MediaItem? {
        guard let channel = channel(for: stationID), let station = station(id: stationID) else {
            return nil
        }
        let state = state(for: channel)
        return MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: state.episode?.title ?? "Live",
            detail: channel.city,
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
            let live = try await api.fetchLive()
            channels = live.channels
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
        guard let entries = try? await api.fetchSchedule(from: from, to: to), !entries.isEmpty else {
            return
        }
        schedule = entries
        scheduleLoadedAt = .now
    }
}
