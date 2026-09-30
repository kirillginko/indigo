//
//  CrateNavigator.swift
//  Indigo
//
//  Where a crate row goes when it is opened rather than played. Shared by the
//  crate page and the mini player's crate list: the mini player once had its
//  own shorter version, and every kept show without a stream, every artist and
//  every label did nothing when pressed there.
//

import SwiftUI
import SwiftData

@MainActor
struct CrateNavigator {
    let appState: AppState
    let crate: CrateService
    let dig: DigStore
    let stations: KeptShow.Stations

    /// True when the row has somewhere to go. A broadcast always does — the
    /// ladder ends at the station's directory — so it answers before the
    /// page it lands on is known.
    @discardableResult
    func open(_ item: CrateItem) -> Bool {
        if let destination = Self.digDestination(for: item) {
            appState.open(destination)
            return true
        }
        if let track = Self.localTrack(for: item, context: crate.context) {
            appState.open(.album(track.albumKey))
            return true
        }
        // Every broadcast row climbs the one ladder — the broadcast, the
        // show, and the station's directory last. The crate page used to
        // route the ones it recognised itself, and For You, which only has
        // the ladder, opened the same rows somewhere else. See `KeptShow`.
        if item.kind == .broadcast {
            Task { await followKeptShow(item) }
            return true
        }
        // The row opens the track's own page — where it was heard, and what
        // was heard beside it. The DIG button still means the artist.
        if let recording = item.recording, let page = dig.recordingDestination(for: recording) {
            appState.open(page)
            return true
        }
        return false
    }

    private func followKeptShow(_ item: CrateItem) async {
        switch await KeptShow.destination(for: item, stations: stations, crate: crate) {
        case .page(let page): appState.open(page)
        case .section(let route): appState.select(route)
        case nil: break
        }
    }

    static func digDestination(for item: CrateItem) -> DetailPage? {
        guard let identifier = item.showID else { return nil }
        switch (item.kind, item.providerID) {
        case (.artist, "dig.artist.mbid"):
            return .digArtist(mbid: identifier, name: item.displayTitle)
        case (.artist, "dig.artist.name"):
            return .digArtist(mbid: nil, name: item.displayTitle)
        case (.release, "dig.release.discogs"):
            guard let id = Int(identifier) else { return nil }
            return .digRelease(id: id, title: item.displayTitle)
        case (.label, "dig.label.mbid"):
            return .digLabel(mbid: identifier, name: item.displayTitle)
        case (.label, "dig.label.discogs"):
            return .digDiscogsLabel(name: item.displayTitle)
        default:
            return nil
        }
    }

    static func localTrack(for item: CrateItem, context: ModelContext) -> Track? {
        guard let path = item.recording?.sources.first(where: { $0.kind == .localFile })?.identifier else {
            return nil
        }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
