//
//  KeptShow.swift
//  Indigo
//
//  Where a show kept off the air opens.
//
//  Crating while a station is on air keeps a show that has no page yet: the
//  broadcast may not be posted for days, and some stations never name it at
//  all. So there is a ladder — the broadcast if it was named, the show if only
//  that was, and the station's shows if neither.
//
//  Here rather than in a view because three places climb it: the crate, the
//  For You page's crate block, and its radio shows. Twice now a fix made in
//  one of them left the others opening the wrong page, and the second time it
//  was a page reporting a broadcast nobody had ever named.
//

import Foundation

/// A rung of the ladder. The two are not interchangeable: a page stacks on
/// top of wherever the listener is, a section replaces it.
nonisolated enum KeptShowDestination: Equatable {
    case page(DetailPage)
    case section(Route)
}

enum KeptShow {
    /// Where this crate row should open.
    ///
    /// `radio80000` is passed rather than reached for because the lookup it
    /// answers is the one station that needs it: Airtime tells Radio 80000
    /// what is on by name and gives no identifier at all, so the only way
    /// back to the show is its own catalogue. Every other station either
    /// names the broadcast or names nothing.
    static func destination(
        for item: CrateItem,
        radio80000: Radio80000BrowseStore
    ) async -> KeptShowDestination? {
        if let showID = item.showID, let providerID = item.providerID,
           let page = BroadcastSource.destination(showID: showID, providerID: providerID) {
            return .page(page)
        }
        guard item.isLiveShowSnapshot else { return nil }
        if item.providerID == Radio80000Provider.providerID,
           let page = await radio80000.showDestination(named: item.displayTitle) {
            return .page(page)
        }
        return BroadcastSource.showsRoute(for: item.providerID).map { .section($0) }
    }

    /// The same ladder for a graph node.
    ///
    /// EXPLORE offers shows as nodes rather than crate rows, and a node whose
    /// handle names a station rather than a broadcast has nowhere of its own
    /// to go — a card that does nothing when it is pressed, which in a thing
    /// built on "no dead ends" is the worst kind of gap, because it looks
    /// like a link.
    static func destination(
        for node: MusicNode,
        radio80000: Radio80000BrowseStore
    ) async -> KeptShowDestination? {
        if let page = node.destination { return .page(page) }
        guard node.kind == .broadcast, let providerID = node.providerID else { return nil }
        if providerID == Radio80000Provider.providerID,
           let page = await radio80000.showDestination(named: node.title) {
            return .page(page)
        }
        return BroadcastSource.showsRoute(for: providerID).map { .section($0) }
    }
}
