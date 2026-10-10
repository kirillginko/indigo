//
//  ArtistNodeIdentity.swift
//  Indigo
//
//  Who an artist node in the graph is, and how that is known.
//
//  A graph node is a key — the folded name it stands for — with a title and
//  sometimes a Discogs id along for the ride. The id was not always earned.
//  Cached artist rows are keyed by the name somebody asked for, older ones were
//  filed by looser matching, and the graph built nodes from them: one row
//  filed under "duenn nyantora" holds Duenn's record, and became a node keyed
//  "duenn nyantora" and titled "Duenn". Resolve that by its title and two
//  artists are one.
//
//  So a node is identified by what it stands for — its key — and an id it
//  carries counts as verified only when a source that identifies the artist
//  supports it: one of the records' own credits, the identity evidence
//  (`ArtistIdentityResolver`), or a cached record filed under exactly this
//  name. Anything else is inferred: kept, because navigation still uses it,
//  but never taken for identity, and never over what verified evidence says.
//
//  Nothing here is stored on the node or shown anywhere. Graph keys stay the
//  folded names they are — synced visits, steps and stored edges hold them —
//  and this is read alongside them.
//

import Foundation
import SwiftData

nonisolated struct ArtistNodeIdentity: Hashable, Sendable {
    /// Where the identity came from, strongest first.
    nonisolated enum Provenance: String, Hashable, Sendable {
        /// A release's own credit names this spelling with this entry.
        case credit
        /// Identity evidence: an explicit id, a MusicBrainz link, a verified
        /// spelling (see `IdentityBasis`).
        case resolver
        /// A cached record filed under exactly this name.
        case filedRecord
        /// An id the node carried that nothing above supports.
        case inferred
        /// No entry at all: the artist is their name.
        case nameOnly
    }

    /// The identity the node resolves to: a Discogs entry when verified,
    /// otherwise its name.
    let identity: ArtistIdentity
    let provenance: Provenance
    /// The id the node carried, whatever it rested on.
    let carriedDiscogsID: Int?

    /// Whether the identity rests on something that identifies the artist.
    var isVerified: Bool { provenance == .credit || provenance == .resolver || provenance == .filedRecord }
}

/// Identifies graph nodes from the evidence DIG holds. The one place the graph
/// asks who a node is; it reuses `DigStore.artistResolution` rather than
/// deciding anything of its own.
@MainActor
final class ArtistNodeIdentifier {
    let store: DigStore

    init(store: DigStore) { self.store = store }

    // Explicit, so releasing one under XCTest does not abort the host; see
    // the note on `DigStore`'s deinit.
    nonisolated deinit {}

    /// Every spelling a kept credit names each entry under, folded. Read once:
    /// a graph asks about hundreds of nodes.
    private lazy var creditedKeys: [Int: Set<String>] = {
        var keys: [Int: Set<String>] = [:]
        for record in (try? store.context.fetch(FetchDescriptor<ReleaseCreditRecord>())) ?? [] {
            for credit in record.credits {
                guard let id = credit.discogsID else { continue }
                keys[id, default: []].insert(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(credit.creditedName)))
                keys[id, default: []].insert(RecordingKey.normalizeArtist(credit.name))
            }
        }
        return keys
    }()

    func identify(_ node: MusicNode) -> ArtistNodeIdentity {
        precondition(node.kind == .artist, "Only artist nodes have an artist identity")
        let key = node.key
        // The name the node stands for. A title that folds to something else
        // is a label put on it by a record that may not be this artist's.
        let name = RecordingKey.normalizeArtist(node.title) == key ? node.title : key
        let resolution = store.artistResolution(ArtistReference(name: name, mbid: node.mbid))
        let resolved: ArtistIdentityState? = resolution.isVerified
            ? ArtistIdentityState(identity: resolution.identity,
                                  provenance: resolution.basis == .filedRecord ? .filedRecord : .resolver)
            : nil

        guard let carried = node.discogsID else {
            return ArtistNodeIdentity(
                identity: resolved?.identity ?? .name(name),
                provenance: resolved?.provenance ?? .nameOnly,
                carriedDiscogsID: nil
            )
        }
        // Verified evidence decides; an id the node carried never overrides it.
        if let resolved, resolved.identity.discogsID != nil {
            return ArtistNodeIdentity(identity: resolved.identity, provenance: resolved.provenance, carriedDiscogsID: carried)
        }
        if creditsSupport(carried, for: key) {
            return ArtistNodeIdentity(identity: .discogs(carried), provenance: .credit, carriedDiscogsID: carried)
        }
        if store.identityStore.facts(carried).map({ RecordingKey.normalizeArtist($0.canonicalName) == key }) == true {
            return ArtistNodeIdentity(identity: .discogs(carried), provenance: .resolver, carriedDiscogsID: carried)
        }
        return ArtistNodeIdentity(identity: resolved?.identity ?? .name(name), provenance: .inferred, carriedDiscogsID: carried)
    }

    /// Whether any kept credit names this spelling with this entry.
    private func creditsSupport(_ discogsID: Int, for key: String) -> Bool {
        creditedKeys[discogsID]?.contains(key) == true
    }

    private struct ArtistIdentityState {
        let identity: ArtistIdentity
        let provenance: ArtistNodeIdentity.Provenance
    }
}

extension DiscogsArtist {
    /// Whether this cached record is filed under its own name — the name its
    /// Discogs entry gives, without filing marks — or under a spelling the
    /// identity evidence verifies as theirs. A record filed under anything
    /// else came from looser matching than today's and says nothing about who
    /// that name is.
    func isFiledUnderItsOwnName(identityStore: ArtistIdentityStore? = nil) -> Bool {
        guard discogsID > 0 else { return false }
        if RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) == nameKey { return true }
        guard let identityStore, let verdict = identityStore.verdict(for: nameKey) else { return false }
        return verdict == .variation(discogsID) || verdict == .canonical([discogsID])
    }
}
