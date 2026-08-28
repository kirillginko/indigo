//
//  NTSProvider.swift
//  Indigo
//
//  The app's first internet provider. Owns the two live channels, their
//  current/next shows, and the polling that keeps them fresh.
//

import Foundation
import Observation

@Observable
final class NTSProvider: RadioProvider {
    static let providerID = "nts"
    let displayName = "NTS"

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let stations: [RadioStation] = [
        RadioStation(
            id: "nts.1",
            providerID: NTSProvider.providerID,
            name: "NTS 1",
            shortName: "1",
            strapline: "London",
            streamURL: URL(string: "https://stream-relay-geo.ntslive.net/stream")!
        ),
        RadioStation(
            id: "nts.2",
            providerID: NTSProvider.providerID,
            name: "NTS 2",
            shortName: "2",
            strapline: "Manchester",
            streamURL: URL(string: "https://stream-relay-geo.ntslive.net/stream2")!
        )
    ]

    private(set) var loadState: LoadState = .idle
    private(set) var lastUpdated: Date?
    private(set) var shows: [String: RadioStationState] = [:]

    @ObservationIgnored private let api = NTSAPI()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    init() {
        for station in stations {
            shows[station.id] = RadioStationState(station: station)
        }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Lookup

    func station(id: String) -> RadioStation? {
        stations.first { $0.id == id }
    }

    func state(for stationID: String) -> RadioStationState? {
        shows[stationID]
    }

    /// The provider-independent item the player consumes.
    func mediaItem(for station: RadioStation) -> MediaItem {
        let show = shows[station.id]?.now
        return MediaItem(
            id: station.id,
            sourceID: Self.providerID,
            kind: .radioStation,
            title: station.name,
            subtitle: show?.title ?? "Live",
            detail: displayName,
            remoteArtworkURL: show?.artworkURL,
            playbackURL: station.streamURL
        )
    }

    // MARK: - Polling

    /// Station pages and active NTS playback call this to poll more often.
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
            let response = try await api.fetchLive()
            apply(response)
            loadState = .loaded
            lastUpdated = .now
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep showing the last good data; surface the failure quietly.
            loadState = .failed(message)
        }
    }

    private func apply(_ response: NTSLiveResponse) {
        for channel in response.results {
            guard let name = channel.channelName,
                  let station = stations.first(where: { $0.shortName == name })
            else { continue }

            shows[station.id] = RadioStationState(
                station: station,
                now: channel.now?.asRadioShow(),
                next: channel.next?.asRadioShow()
            )
        }
    }
}
