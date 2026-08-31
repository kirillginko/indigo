//
//  StoredEdge.swift
//  Indigo
//
//  The graph, kept.
//
//  Until now every connection was derived on demand: open a page and the app
//  read six tables whole and rebuilt every edge out of the node. That cost
//  about six hundred milliseconds, and — worse — it was thrown away the
//  instant anything anywhere was written. Background enrichment writes
//  constantly, so pages were paying it again and again for a graph that had
//  not changed.
//
//  An edge is a fact. Once worked out it is worth keeping until the thing it
//  was worked out from changes, which is what this is.
//
//  The destination is stored flat rather than as a relationship. Reading a
//  page should be one indexed query and no joins; a `MusicNode` is a value and
//  can be rebuilt from columns.
//

import Foundation
import SwiftData

@Model
nonisolated final class StoredEdge {
    @Attribute(.unique) var id: String
    /// The node this edge leaves — what a page looks up.
    var fromID: String

    var kindRaw: String
    var sourceRaw: String
    var reason: String
    var confidence: Double
    var occurrences: Int

    // The destination, denormalised.
    var toID: String
    var toKindRaw: String
    var toKey: String
    var toTitle: String
    var toSubtitle: String?
    var toMBID: String?
    var toDiscogsID: Int?
    var toRecordingID: UUID?
    var toProviderID: String?
    var toHandle: String?
    var toArtworkURLString: String?

    init(from origin: MusicNode, edge: MusicEdge) {
        id = "\(origin.id)|\(edge.to.id)|\(edge.kind.rawValue)"
        fromID = origin.id
        kindRaw = edge.kind.rawValue
        sourceRaw = edge.source.rawValue
        reason = edge.reason
        confidence = edge.confidence
        occurrences = edge.occurrences

        toID = edge.to.id
        toKindRaw = edge.to.kind.rawValue
        toKey = edge.to.key
        toTitle = edge.to.title
        toSubtitle = edge.to.subtitle
        toMBID = edge.to.mbid
        toDiscogsID = edge.to.discogsID
        toRecordingID = edge.to.recordingID
        toProviderID = edge.to.providerID
        toHandle = edge.to.handle
        toArtworkURLString = edge.to.artworkURL?.absoluteString
    }

    var destination: MusicNode {
        MusicNode(
            kind: MusicNodeKind(rawValue: toKindRaw) ?? .artist,
            key: toKey,
            title: toTitle,
            subtitle: toSubtitle,
            mbid: toMBID,
            discogsID: toDiscogsID,
            recordingID: toRecordingID,
            providerID: toProviderID,
            handle: toHandle,
            artworkURL: toArtworkURLString.flatMap(URL.init(string:))
        )
    }

    func edge(from origin: MusicNode) -> MusicEdge {
        MusicEdge(
            from: origin,
            to: destination,
            kind: RelationshipKind(rawValue: kindRaw) ?? .sharedStyle,
            source: RelationshipSource(rawValue: sourceRaw) ?? .discogs,
            reason: reason,
            confidence: confidence,
            occurrences: occurrences
        )
    }
}

/// A record that a node has been walked, so an empty result is told apart
/// from one nobody has computed.
///
/// Without this, an artist with genuinely no connections would be rebuilt on
/// every visit forever — the expensive case being indistinguishable from the
/// unvisited one.
@Model
nonisolated final class GraphSnapshot {
    @Attribute(.unique) var nodeID: String
    var builtAt: Date

    init(nodeID: String) {
        self.nodeID = nodeID
        builtAt = Date()
    }
}
