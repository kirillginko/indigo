//
//  AlharaProvider.swift
//  Indigo
//
//  Radio alHara broadcasts from Bethlehem, Palestine, and has since 2020 —
//  three channels: a studio, a second for events and relays, and a third that
//  travels with the station's exhibitions.
//
//  alHara publishes no archive, no schedule and no roster, so this provider is
//  the three streams and what is on them. There is nothing to browse because
//  the station does not put anything out to browse.
//

import Foundation
import Observation

@Observable
final class AlharaProvider: RadioProvider {
    nonisolated static let providerID = "alhara"
    let displayName = "Radio alHara"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let stations: [RadioStation] = [
        RadioStation(
            id: "alhara.ra",
            providerID: AlharaProvider.providerID,
            name: "Radio alHara",
            shortName: "RA",
            strapline: "Bethlehem",
            streamURL: URL(string: "https://stream.radioalhara.net/ra")!
        ),
        RadioStation(
            id: "alhara.ra2",
            providerID: AlharaProvider.providerID,
            name: "alHara RA2",
            shortName: "RA2",
            strapline: "Events & relay",
            streamURL: URL(string: "https://stream.radioalhara.net/ra2")!
        ),
        RadioStation(
            id: "alhara.ra3",
            providerID: AlharaProvider.providerID,
            name: "alHara RA3",
            shortName: "RA3",
            strapline: "Exhibitions",
            streamURL: URL(string: "https://stream.radioalhara.net/ra3")!
        )
    ]

    /// The station's own mark, for when there is no picture of what is on —
    /// which for alHara is always, since it publishes none.
    static let logoURL = URL(string: "https://radioalhara.net/img/radio-alhara-logo-512.png")

    private(set) var channels: [String: AlharaChannelState] = [:]
    /// Channels the station has asked not to be shown for now.
    private(set) var hidden: Set<String> = []
    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?

    /// Progress is derived from the clock, and @Observable only notices stored
    /// state — so the poll stamps the moment the state was read and everything
    /// downstream keys off that.
    private(set) var referenceDate: Date = .now

    @ObservationIgnored private let api = AlharaAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lookup

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    /// Every channel the station has not asked to hide, whatever it is doing.
    var publishedStations: [RadioStation] {
        stations.filter { !hidden.contains($0.id) }
    }

    /// What the listener should actually be offered. alHara's secondary
    /// channels carry the main one whenever they have nothing of their own on,
    /// so listing all three would be three ways to hear the same thing — and
    /// three ways to wonder why they sound identical. They appear once they
    /// are doing something.
    var visibleStations: [RadioStation] {
        publishedStations.filter { station in
            guard station.id != stations[0].id else { return true }
            // Before the first poll nothing is known, and the main channel is
            // the honest default.
            guard !channels.isEmpty else { return false }
            return state(for: station.id).isOnAir
        }
    }

    /// True when a secondary channel is simply relaying the main one.
    func isSimulcast(_ stationID: String) -> Bool {
        guard stationID != stations[0].id, !channels.isEmpty else { return false }
        return !state(for: stationID).isOnAir
    }

    func state(for stationID: String) -> AlharaChannelState {
        channels[stationID] ?? .idle
    }

    func now(for stationID: String) -> RadioShow? {
        state(for: stationID).asRadioShow()
    }

    /// The channel with something actually on it, preferring the studio.
    var liveStation: RadioStation? {
        visibleStations.first { state(for: $0.id).isOnAir }
    }

    /// The provider-independent item the player consumes.
    func mediaItem(for stationID: String) -> MediaItem? {
        guard let station = station(id: stationID) else { return nil }
        let state = state(for: stationID)
        return MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: state.title ?? state.mode.label,
            detail: state.city ?? station.strapline,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    /// A station page and active alHara playback call this to poll faster.
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
                let interval = self.watchers > 0 ? 30.0 : 240.0
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
            let snapshot = try await api.fetchSnapshot()
            channels = snapshot.channels
            hidden = snapshot.hidden
            referenceDate = .now
            loadState = .loaded
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last known state; surface the failure quietly.
            referenceDate = .now
            loadState = .failed(message)
        }
    }
}
