//
//  ListeningEvent.swift
//  Indigo
//
//  What the listener actually met, and how much of it they got through.
//
//  Indigo already remembers two narrower things: `MediaAppearance` records
//  where a piece of music was heard, and `DigVisit` records how often a page
//  was opened. Neither answers "what have they been listening to" — the first
//  only exists for music a tracklist happened to name, and the second counts
//  openings rather than listening. An event log is the missing middle: one row
//  per encounter, with enough of the encounter kept to tell a twenty-minute
//  session from a mis-click.
//
//  The subject is stored as a graph identity rather than as a foreign key, so
//  a station, a show, an artist and a track are all logged the same way and
//  can be counted against the same node DIG navigates to. Everything here is
//  local, and throwing it away costs nothing the app cannot relearn.
//

import Foundation
import SwiftData

/// What happened to the thing. Ordered roughly by how much it says about
/// taste: a save is a statement, a skip is close to a rejection.
nonisolated enum ListeningAction: String, Codable, CaseIterable, Sendable {
    /// Heard, for however long `seconds` says.
    case played
    /// Put on and moved past before it could count as listening.
    case skipped
    /// Kept — crated, or otherwise claimed.
    case saved
    /// A page was opened. Weaker evidence than listening, but evidence.
    case opened
    /// Offered and refused. The only action that argues against something.
    case dismissed

    var label: String {
        switch self {
        case .played: "Played"
        case .skipped: "Skipped"
        case .saved: "Saved"
        case .opened: "Opened"
        case .dismissed: "Dismissed"
        }
    }
}

@Model
nonisolated final class ListeningEvent {
    @Attribute(.unique) var id: UUID
    var at: Date
    var actionRaw: String

    // MARK: What was met

    /// `MusicNode.id` — "artist:susosaiz". Queried against directly, so it is
    /// stored rather than recomputed from the parts below.
    var nodeID: String
    var nodeKindRaw: String
    var nodeKey: String
    var title: String
    var subtitle: String?

    // Whatever identifiers were known at the time, so a remembered encounter
    // can be reopened. An encounter nobody can act on is a statistic.
    var mbid: String?
    var discogsID: Int?
    var recordingID: UUID?
    var providerID: String?
    var handle: String?

    // MARK: Where it was met

    /// The station it came through — "nts", "kiosk", "local".
    var sourceProviderID: String?
    /// The broadcast it came out of, in the provider's own handle form.
    var sourceShowID: String?
    var sourceShowTitle: String?

    // MARK: How much of it

    /// Seconds actually heard, paused time excluded. Zero for actions that
    /// are not listening.
    var seconds: Double
    /// 0…1 of the way through. Zero when unknowable, which is every live
    /// stream — `seconds` carries those.
    var completion: Double

    /// Genres and styles as they were described at the time, kept here rather
    /// than looked up later so building a taste profile never has to walk the
    /// graph. What a provider called a show in August is also better evidence
    /// than what a catalogue says about it now.
    var tags: [String]

    init(
        id: UUID = UUID(),
        node: MusicNode,
        action: ListeningAction,
        at: Date = Date(),
        seconds: Double = 0,
        completion: Double = 0,
        tags: [String] = [],
        source: ListeningSource? = nil
    ) {
        self.id = id
        self.at = at
        self.actionRaw = action.rawValue
        self.nodeID = node.id
        self.nodeKindRaw = node.kind.rawValue
        self.nodeKey = node.key
        self.title = node.title
        self.subtitle = node.subtitle
        self.mbid = node.mbid
        self.discogsID = node.discogsID
        self.recordingID = node.recordingID
        self.providerID = node.providerID
        self.handle = node.handle
        self.sourceProviderID = source?.providerID
        self.sourceShowID = source?.showID
        self.sourceShowTitle = source?.showTitle
        self.seconds = max(0, seconds)
        self.completion = min(1, max(0, completion))
        self.tags = tags
    }

    var action: ListeningAction { ListeningAction(rawValue: actionRaw) ?? .played }
    var kind: MusicNodeKind { MusicNodeKind(rawValue: nodeKindRaw) ?? .artist }

    /// The node again, so an encounter can be walked from.
    var node: MusicNode {
        MusicNode(
            kind: kind, key: nodeKey, title: title, subtitle: subtitle,
            mbid: mbid, discogsID: discogsID, recordingID: recordingID,
            providerID: providerID, handle: handle
        )
    }

    /// "NTS / Perfect Sound Forever", or nil when it came from nowhere in
    /// particular.
    var sourceLine: String? {
        guard let sourceProviderID else { return sourceShowTitle }
        let station = BroadcastSource.label(for: sourceProviderID)
        guard let sourceShowTitle, !sourceShowTitle.isEmpty else { return station }
        return "\(station) / \(sourceShowTitle)"
    }

    // MARK: - Weight

    /// Below this, a play is an accident: a wrong click, a station sampled and
    /// left. Counting those the same as listening is what turns a taste
    /// profile into a log of the buttons someone pressed.
    static let accidentSeconds: Double = 30
    /// Below *this*, nothing happened at all. Between the two is a rejection,
    /// which is worth knowing about — long enough to have been a decision,
    /// short enough that the decision was no.
    static let noticedSeconds: Double = 5
    /// Where a play stops earning more for running longer. Twenty minutes is
    /// about a side, and about a radio segment.
    static let fullListenSeconds: Double = 1200

    /// How much this encounter should count for, before any decay.
    ///
    /// Negative only for a dismissal, which is the one action that argues
    /// against something rather than merely failing to argue for it.
    var weight: Double {
        switch action {
        case .saved: return 1.5
        case .dismissed: return -1
        case .opened: return 0.3
        case .skipped: return 0
        case .played:
            guard seconds >= Self.accidentSeconds else { return 0 }
            // Whichever is the more generous reading: a third of a long mix
            // is real listening, and so is all of a two-minute interlude.
            return max(min(1, seconds / Self.fullListenSeconds), completion)
        }
    }
}

/// Where an encounter happened. Not a node of its own — the same station is
/// also logged as a subject in its own right — but the provenance that lets
/// Phase 2 say "Noods — Endpapers" under an artist's name.
nonisolated struct ListeningSource: Hashable, Sendable {
    var providerID: String?
    /// The provider's own handle for the broadcast, in the prefixed form
    /// `BroadcastSource.destination` can navigate back from.
    var showID: String?
    var showTitle: String?

    init(providerID: String? = nil, showID: String? = nil, showTitle: String? = nil) {
        self.providerID = providerID
        self.showID = showID
        self.showTitle = showTitle
    }

    var isEmpty: Bool { providerID == nil && showID == nil && showTitle == nil }
}
