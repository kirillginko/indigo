//
//  GraphStore.swift
//  Indigo
//
//  Walks the music graph outward from a node.
//
//  Until now this logic lived inside `DigEngine.relatedArtists`, which meant
//  it could only ever answer one question — which artists resemble this
//  artist — and threw the reasoning away as soon as a view had rendered it.
//  DEEP, RADIO and TRAILS all need to step from a label to a white label to
//  the show that played it, so the step itself has to be the thing the app
//  owns.
//
//  Everything here reads the local caches and nothing here goes to the
//  network. A graph you can only walk online is not a graph, and DIG has to
//  stay navigable on a train.
//

import Foundation
import SwiftData

nonisolated struct GraphStore {
    let context: ModelContext

    /// Built at most once per store, and only if something is actually
    /// walked.
    ///
    /// Assembling it reads six tables, and callers walk repeatedly from one
    /// store — the "TRY" list steps out of four different places at once, and
    /// paying for the whole cache four times over is most of what made DIG
    /// feel slow. A box because a struct cannot memoise into itself, and the
    /// alternative is making every call site pass a cache it should not have
    /// to know about.
    private let box = CacheBox()

    private final class CacheBox {
        var caches: Caches?
    }

    init(context: ModelContext) {
        self.context = context
    }

    private var caches: Caches {
        if let existing = box.caches { return existing }
        let fresh = Caches(context: context)
        box.caches = fresh
        return fresh
    }

    /// Everything reachable from a node in one step, with the reasons.
    func neighbors(of node: MusicNode) -> EdgeSet {
        let caches = self.caches
        var edges = EdgeSet()
        switch node.kind {
        case .artist: addArtistNeighbors(node, caches: caches, into: &edges)
        case .label: addLabelNeighbors(node, caches: caches, into: &edges)
        case .release: addReleaseNeighbors(node, caches: caches, into: &edges)
        case .broadcast: addBroadcastNeighbors(node, caches: caches, into: &edges)
        case .recording, .unknownRecording: addRecordingNeighbors(node, caches: caches, into: &edges)
        case .catalogNumber: addCatalogNeighbors(node, caches: caches, into: &edges)
        case .scene: addSceneNeighbors(node, caches: caches, into: &edges)
        // A style is a lens rather than a place, and a selector's neighbours
        // are radio evidence — RadioNeighborhoodEngine owns those, and its
        // findings arrive here through `MusicGraph.absorb`.
        case .style, .selector: break
        }
        return edges
    }

    /// The artists reachable from an artist, which is the RELATED list.
    /// Kept as a named entry point because it is asked for constantly and
    /// filtering a full walk down to one kind every time would be wasteful.
    func relatedArtists(to node: MusicNode) -> [(node: MusicNode, edges: [MusicEdge], confidence: Double)] {
        let caches = self.caches
        var edges = EdgeSet()
        addArtistPeers(node, caches: caches, into: &edges)
        return edges.byDestination.filter { $0.node.kind == .artist }
    }

    // MARK: - Artist

    private func addArtistNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        addAliasFamily(node, into: &edges)

        addArtistCatalogue(node, caches: caches, into: &edges)
        addArtistBroadcasts(node, caches: caches, into: &edges)
        addArtistPeers(node, caches: caches, into: &edges)
    }

    /// The alias branch. Distinct nodes joined by a strong edge, never merged
    /// into one — the names are different on purpose.
    private func addAliasFamily(_ node: MusicNode, into edges: inout EdgeSet) {
        let family = AliasResolver(context: context).family(of: node.title)
        for member in family.members {
            let reason: String
            let kind: RelationshipKind
            switch member.role {
            case .alias, .primary:
                kind = .sameAlias
                reason = "Also records as \(family.primary)"
            case .project:
                kind = .aliasOrProject
                reason = "\(family.primary) is part of \(member.name)"
            case .member:
                kind = .aliasOrProject
                reason = "Makes up \(family.primary)"
            }
            edges.insert(MusicEdge(
                from: node, to: .artist(member.name), kind: kind, source: .discogs,
                reason: reason, confidence: member.role.confidence
            ))
        }
    }

    /// What the artist put out, and on whose imprint. Labels and catalogue
    /// numbers become nodes here rather than strings, which is what makes
    /// "↓ DEEPER INTO LABEL" possible at all.
    private func addArtistCatalogue(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        let discogs = caches.discogsArtist(node.key)

        var labels: [String: String?] = [:]
        for recording in caches.recordings(byArtistKey: node.key) {
            guard let metadata = caches.metadata[recording.id], let name = metadata.labelName else { continue }
            labels[name] = metadata.labelMBID
            if let catalog = metadata.catalogNumber, !catalog.isEmpty {
                edges.insert(MusicEdge(
                    from: node, to: .catalogNumber(catalog), kind: .appearsOnRelease,
                    source: .musicBrainz, reason: "Released as \(catalog.uppercased())",
                    confidence: 0.9
                ))
            }
        }
        for name in discogs?.labelNames ?? [] where labels[name] == nil {
            // Assigning nil into a dictionary whose values are themselves
            // optional removes the key. `updateValue` is what actually
            // stores "known label, unknown MBID" — the ordinary case for
            // anything Discogs knows and MusicBrainz does not.
            labels.updateValue(nil, forKey: name)
        }

        for (name, mbid) in labels where LabelName.isRealLabel(name) {
            edges.insert(MusicEdge(
                from: node, to: .label(name, mbid: mbid), kind: .sharedLabel,
                source: mbid == nil ? .discogs : .musicBrainz,
                reason: "Releases on \(name)", confidence: RelationshipKind.sharedLabel.baseConfidence
            ))
        }

        for (index, title) in (discogs?.releaseTitles ?? []).enumerated() {
            let identifier = index < (discogs?.releaseDiscogsIDs.count ?? 0)
                ? discogs?.releaseDiscogsIDs[index] : nil
            let year = index < (discogs?.releaseYears.count ?? 0) ? discogs?.releaseYears[index] : nil
            edges.insert(MusicEdge(
                from: node, to: .release(title, discogsID: identifier, year: year),
                kind: .appearsOnRelease, source: .discogs,
                reason: "Released \(title)", confidence: RelationshipKind.appearsOnRelease.baseConfidence
            ))
        }

        for style in discogs?.styles ?? [] {
            edges.insert(MusicEdge(
                from: node, to: .style(style), kind: .sharedStyle, source: .discogs,
                reason: "Tagged \(style)", confidence: RelationshipKind.sharedStyle.baseConfidence
            ))
        }
    }

    /// Where the artist has actually been heard. This is the half no
    /// catalogue holds, and it is the reason any of this is worth building.
    private func addArtistBroadcasts(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        for recording in caches.recordings(byArtistKey: node.key) {
            for appearance in recording.appearances {
                guard let showID = appearance.showID else { continue }
                let show = MusicNode.broadcast(
                    providerID: appearance.providerID, showID: showID, title: appearance.showTitle
                )
                edges.insert(MusicEdge(
                    from: node, to: show, kind: .playedInShow, source: .radio,
                    reason: "Played on \(appearance.sourceLine)",
                    confidence: RelationshipKind.playedInShow.baseConfidence
                ))
            }
        }
    }

    /// Artist to artist. Ported from the old RELATED builder, with each
    /// reason now carrying its kind's own base confidence rather than a
    /// number chosen at the call site.
    private func addArtistPeers(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        let subject = node.key
        let family = caches.aliasKeys(of: node.title, context: context)
        let discogs = caches.discogsArtist(subject)

        func link(
            _ name: String,
            _ kind: RelationshipKind,
            _ source: RelationshipSource,
            _ reason: String,
            confidence: Double? = nil,
            occurrences: Int = 1
        ) {
            let key = RecordingKey.normalizeArtist(name)
            // An artist's own aliases belong on the alias branch, not in the
            // peer list, or every family member arrives twice. And "Various"
            // is a filing convention rather than a person — left in, it would
            // join every compilation in the catalogue to every other one.
            guard !key.isEmpty, !family.contains(key), ArtistName.isRealArtist(name) else { return }
            var destination = MusicNode.artist(name, mbid: caches.mbid(forArtistKey: key))
            // Their own portrait when we have already dug into them; otherwise
            // a record of theirs, which came free with the search that found
            // them. Either beats an empty box in a row of forty.
            let peer = caches.discogsArtist(key)
            destination.artworkURL = peer?.imageURL
                ?? caches.portrait(key)
                ?? discogs?.neighbourImageURL(for: name)
                ?? peer?.anyReleaseImageURL
            edges.insert(MusicEdge(
                from: node, to: destination,
                kind: kind, source: source, reason: reason,
                confidence: confidence ?? kind.baseConfidence, occurrences: occurrences
            ))
        }

        // Label rosters, from whichever catalogue knows them.
        for label in caches.labels(forArtistKey: subject) {
            guard let mbid = label.mbid, let cached = caches.musicLabel(mbid) else { continue }
            for peer in cached.roster {
                link(peer.name, .sharedLabel, .musicBrainz, "Same label: \(cached.name)")
            }
        }
        // Only where there is a label to have in common. "Not On Label" is the
        // absence of one, and two self-released records are not labelmates.
        if let shared = discogs?.labelNames.first(where: { LabelName.isRealLabel($0) }) {
            for peer in discogs?.labelNeighbourNames ?? [] {
                link(peer, .sharedLabel, .discogs, "Also on \(shared)", confidence: 0.72)
            }
        }
        for collaborator in discogs?.collaboratorNames ?? [] {
            link(collaborator, .collaborator, .discogs, "Credited together")
        }
        for peer in discogs?.styleNeighbourNames ?? [] {
            link(peer, .sharedStyle, .discogs, "Also tagged \(discogs?.styles.first ?? "the same style")",
                 confidence: 0.58)
        }

        // Artists already visited form an instant local graph, which is often
        // better than either catalogue: it is made of what this listener has
        // actually looked at.
        if let discogs {
            let subjectLabels = Set(discogs.labelNames.map(RecordingKey.normalize))
            let subjectStyles = Set(discogs.styles.map(RecordingKey.normalize))
            let subjectDecades = Set(discogs.releaseYears.compactMap(Self.decade))
            for peer in caches.discogsArtists where !family.contains(peer.nameKey) {
                let peerLabels = Set(peer.labelNames.map(RecordingKey.normalize))
                if let shared = discogs.labelNames.first(where: { name in
                    guard LabelName.isRealLabel(name) else { return false }
                    let key = RecordingKey.normalize(name)
                    return subjectLabels.contains(key) && peerLabels.contains(key)
                }) {
                    link(peer.name, .sharedLabel, .discogs, "Both release on \(shared)", confidence: 0.8)
                }
                let sharedStyles = subjectStyles.intersection(peer.styles.map(RecordingKey.normalize))
                if let style = discogs.styles.first(where: {
                    sharedStyles.contains(RecordingKey.normalize($0))
                }) {
                    link(peer.name, .sharedStyle, .discogs, "Shared sound: \(style)",
                         occurrences: sharedStyles.count)
                }
                let peerDecades = Set(peer.releaseYears.compactMap(Self.decade))
                if let decade = subjectDecades.intersection(peerDecades).sorted().last {
                    link(peer.name, .sameEra, .discogs, "Catalogues overlap in the \(decade)s")
                }
            }
        }

        addRadioPeers(node, family: family, caches: caches, link: link)
        addCollectionPeers(node, family: family, caches: caches, link: link)

        // The listener's own judgement, which outranks a catalogue edge in a
        // tool that exists to follow taste rather than metadata.
        for (name, count) in caches.cratedArtistCounts {
            let key = RecordingKey.normalizeArtist(name)
            guard !family.contains(key), edges.edges.values.contains(where: { $0.to.key == key })
            else { continue }
            link(name, .inYourCrate, .crate,
                 "\(RelationshipReason.occurrences(count, singular: "track")) in your crate",
                 occurrences: count)
        }
    }

    private func addRadioPeers(
        _ node: MusicNode,
        family: Set<String>,
        caches: Caches,
        link: (String, RelationshipKind, RelationshipSource, String, Double?, Int) -> Void
    ) {
        var subjectShows: [String: String] = [:]
        for recording in caches.recordings(byArtistKey: node.key) {
            for appearance in recording.appearances {
                guard let showID = appearance.showID else { continue }
                subjectShows["\(appearance.providerID)|\(showID)"] = appearance.showTitle ?? appearance.sourceLine
            }
        }
        guard !subjectShows.isEmpty else { return }

        // Counted rather than merely noted: sharing one broadcast is a
        // coincidence and sharing eleven is the thing worth surfacing.
        var shared: [String: (title: String, count: Int)] = [:]
        for recording in caches.recordings {
            guard let peer = recording.artistName,
                  !family.contains(RecordingKey.normalizeArtist(peer)) else { continue }
            for appearance in recording.appearances {
                guard let showID = appearance.showID,
                      let title = subjectShows["\(appearance.providerID)|\(showID)"] else { continue }
                let existing = shared[peer]
                shared[peer] = (existing?.title ?? title, (existing?.count ?? 0) + 1)
            }
        }
        for (peer, evidence) in shared {
            let reason = evidence.count == 1
                ? "Played in the same broadcast: \(evidence.title)"
                : "Played in \(RelationshipReason.occurrences(evidence.count, singular: "of the same show", plural: "of the same shows"))"
            link(peer, .sharedBroadcast, .radio, reason, nil, evidence.count)
        }
    }

    private func addCollectionPeers(
        _ node: MusicNode,
        family: Set<String>,
        caches: Caches,
        link: (String, RelationshipKind, RelationshipSource, String, Double?, Int) -> Void
    ) {
        let albums = Set(caches.tracks
            .filter { !DigEngine.artistKeys(for: $0).isDisjoint(with: family) }
            .map(\.albumKey)
            .filter { !$0.isEmpty })
        guard !albums.isEmpty else { return }
        for track in caches.tracks where albums.contains(track.albumKey) {
            let peer = track.artist.isEmpty ? track.albumArtist : track.artist
            guard !peer.isEmpty else { continue }
            link(peer, .sharedCollection, .library, "Together in your library: \(track.album)", nil, 1)
        }
    }

    // MARK: - Label

    private func addLabelNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        if let mbid = node.mbid, let cached = caches.musicLabel(mbid) {
            for peer in cached.roster where ArtistName.isRealArtist(peer.name) {
                edges.insert(MusicEdge(
                    from: node, to: .artist(peer.name, mbid: peer.mbid), kind: .sharedLabel,
                    source: .musicBrainz, reason: "Releases on \(cached.name)",
                    confidence: RelationshipKind.sharedLabel.baseConfidence
                ))
            }
        }
        for artist in caches.discogsArtists
        where artist.labelNames.contains(where: { RecordingKey.normalize($0) == node.key }) {
            edges.insert(MusicEdge(
                from: node, to: .artist(artist.name, discogsID: artist.discogsID),
                kind: .sharedLabel, source: .discogs, reason: "Releases on \(node.title)",
                confidence: RelationshipKind.sharedLabel.baseConfidence
            ))
        }
        for release in caches.discogsReleases
        where release.labelNames.contains(where: { RecordingKey.normalize($0) == node.key }) {
            edges.insert(MusicEdge(
                from: node, to: .release(release.title, discogsID: release.discogsID,
                                         year: release.year.map(String.init)),
                kind: .appearsOnRelease, source: .discogs,
                reason: "\(node.title) catalogue", confidence: 0.9
            ))
            for catalog in release.catalogNumbers where !catalog.isEmpty {
                edges.insert(MusicEdge(
                    from: node, to: .catalogNumber(catalog), kind: .appearsOnRelease,
                    source: .discogs, reason: "Issued as \(catalog.uppercased())", confidence: 0.92
                ))
            }
        }
    }

    // MARK: - Release

    private func addReleaseNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        guard let identifier = node.discogsID, let record = caches.discogsRelease(identifier) else { return }
        for artist in record.artistNames where ArtistName.isRealArtist(artist) {
            edges.insert(MusicEdge(
                from: node, to: .artist(artist), kind: .sameRelease, source: .discogs,
                reason: "Appears on \(record.title)", confidence: RelationshipKind.sameRelease.baseConfidence
            ))
        }
        for label in record.labelNames where LabelName.isRealLabel(label) {
            edges.insert(MusicEdge(
                from: node, to: .label(label), kind: .sharedLabel, source: .discogs,
                reason: "Issued by \(label)", confidence: RelationshipKind.sharedLabel.baseConfidence
            ))
        }
        for catalog in record.catalogNumbers where !catalog.isEmpty {
            edges.insert(MusicEdge(
                from: node, to: .catalogNumber(catalog), kind: .appearsOnRelease, source: .discogs,
                reason: "Catalogued \(catalog.uppercased())", confidence: 0.92
            ))
        }
        for style in record.styles {
            edges.insert(MusicEdge(
                from: node, to: .style(style), kind: .sharedStyle, source: .discogs,
                reason: "Tagged \(style)", confidence: RelationshipKind.sharedStyle.baseConfidence
            ))
        }
    }

    // MARK: - Broadcast

    /// What was on. Unknown recordings come back from here exactly as
    /// identified ones do, which is the whole reason the graph has a node
    /// kind for them.
    private func addBroadcastNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        guard let providerID = node.providerID, let showID = node.handle else { return }
        for recording in caches.recordings {
            for appearance in recording.appearances
            where appearance.providerID == providerID && appearance.showID == showID {
                edges.insert(MusicEdge(
                    from: node,
                    to: .recording(recording, artwork: caches.metadata[recording.id]?.artworkURL),
                    kind: .playedInShow, source: .radio,
                    reason: appearance.offsetLabel.map { "Played at \($0)" } ?? "Played on \(node.title)",
                    confidence: RelationshipKind.playedInShow.baseConfidence
                ))
                if let artist = recording.artistName, !artist.isEmpty {
                    edges.insert(MusicEdge(
                        from: node, to: .artist(artist), kind: .playedInShow, source: .radio,
                        reason: "Played on \(node.title)",
                        confidence: RelationshipKind.playedInShow.baseConfidence
                    ))
                }
            }
        }
    }

    // MARK: - Recording

    private func addRecordingNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        guard let identifier = node.recordingID,
              let recording = caches.recordings.first(where: { $0.id == identifier }) else { return }

        for appearance in recording.appearances {
            guard let showID = appearance.showID else { continue }
            edges.insert(MusicEdge(
                from: node,
                to: .broadcast(providerID: appearance.providerID, showID: showID, title: appearance.showTitle),
                kind: .playedInShow, source: .radio,
                reason: "Heard on \(appearance.sourceLine) · \(appearance.dateLabel)",
                confidence: RelationshipKind.playedInShow.baseConfidence
            ))
        }
        if let artist = recording.artistName, !artist.isEmpty {
            edges.insert(MusicEdge(
                from: node, to: .artist(artist), kind: .sameArtist, source: .musicBrainz,
                reason: "By \(artist)", confidence: RelationshipKind.sameArtist.baseConfidence
            ))
        }
        if let metadata = caches.metadata[recording.id] {
            if let label = metadata.labelName, LabelName.isRealLabel(label) {
                edges.insert(MusicEdge(
                    from: node, to: .label(label, mbid: metadata.labelMBID), kind: .sharedLabel,
                    source: .musicBrainz, reason: "Issued by \(label)",
                    confidence: RelationshipKind.sharedLabel.baseConfidence
                ))
            }
            if let catalog = metadata.catalogNumber, !catalog.isEmpty {
                edges.insert(MusicEdge(
                    from: node, to: .catalogNumber(catalog), kind: .appearsOnRelease,
                    source: .musicBrainz, reason: "Catalogued \(catalog.uppercased())", confidence: 0.9
                ))
            }
        }
    }

    // MARK: - Scene

    /// Who and what a place is made of. The membership is worked out by
    /// `SceneEngine` from origins and tags; this turns it into steps the graph
    /// can walk, so a scene is somewhere you can dig out of rather than a
    /// page you have to reverse out of.
    private func addSceneNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        let city = node.key.split(separator: "|").first.map(String.init) ?? node.key
        guard let scene = SceneEngine(context: context).scene(city: city) else { return }
        let where_ = "\(scene.city) \(scene.eraLabel)"

        for artist in scene.artists {
            edges.insert(MusicEdge(
                from: node, to: .artist(artist, mbid: caches.mbid(forArtistKey: RecordingKey.normalizeArtist(artist))),
                kind: .sameScene, source: .discogs,
                reason: "Part of \(where_)", confidence: RelationshipKind.sameScene.baseConfidence
            ))
        }
        for label in scene.labels {
            edges.insert(MusicEdge(
                from: node, to: .label(label), kind: .sameScene, source: .discogs,
                reason: "Releasing out of \(where_)",
                confidence: RelationshipKind.sameScene.baseConfidence
            ))
        }
    }

    // MARK: - Catalogue

    /// Catalogue numbers as somewhere you can go. A run of them is a label's
    /// spine, so the neighbours of ITLP09 are ITLP08 and ITLP10 — which is
    /// how a shelf is read and how a reissue or a promo is stumbled upon.
    private func addCatalogNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        guard let parts = CatalogNumber.split(node.title) else { return }
        for release in caches.discogsReleases {
            for catalog in release.catalogNumbers {
                guard let other = CatalogNumber.split(catalog), other.prefix == parts.prefix else { continue }
                let distance = abs(other.number - parts.number)
                guard distance > 0, distance <= 3 else {
                    if distance == 0 {
                        edges.insert(MusicEdge(
                            from: node,
                            to: .release(release.title, discogsID: release.discogsID,
                                         year: release.year.map(String.init)),
                            kind: .sameRelease, source: .discogs,
                            reason: "Catalogued \(node.title)", confidence: 0.95
                        ))
                    }
                    continue
                }
                edges.insert(MusicEdge(
                    from: node,
                    to: .release(release.title, discogsID: release.discogsID,
                                 year: release.year.map(String.init)),
                    kind: .appearsOnRelease, source: .discogs,
                    reason: "\(catalog.uppercased()) — neighbouring catalogue number",
                    confidence: max(0.4, 0.75 - Double(distance) * 0.1)
                ))
            }
        }
    }

    private static func decade(_ year: String) -> Int? {
        guard let value = Int(year.prefix(4)), value > 0 else { return nil }
        return value / 10 * 10
    }
}

// MARK: - Caches

/// One fetch of each table per walk. The graph builders ask the same
/// questions repeatedly, and SwiftData will happily answer a full table scan
/// every time if nobody stops it.
private nonisolated struct Caches {
    let recordings: [Recording]
    let tracks: [Track]
    let discogsArtists: [DiscogsArtist]
    let discogsReleases: [DiscogsReleaseRecord]
    let metadata: [UUID: RecordingMetadata]
    let cratedArtistCounts: [String: Int]

    private let artistsByKey: [String: DiscogsArtist]
    private let releasesByID: [Int: DiscogsReleaseRecord]
    /// Grouped once. Filtering the whole recording table per peer turns a
    /// RELATED list of forty into forty full scans, which is what made
    /// opening an artist page slow.
    private let portraitsByKey: [String: URL]
    private let recordingsByArtistKey: [String: [Recording]]
    private let mbidByArtistKey: [String: String]
    private let context: ModelContext
    private let families = FamilyBox()

    private final class FamilyBox {
        var value: [String: Set<String>] = [:]
    }

    init(context: ModelContext) {
        self.context = context
        recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        discogsArtists = (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
        discogsReleases = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<RecordingMetadata>())) ?? []
        metadata = Dictionary(entries.map { ($0.recordingID, $0) }, uniquingKeysWith: { first, _ in first })
        artistsByKey = Dictionary(discogsArtists.map { ($0.nameKey, $0) }, uniquingKeysWith: { first, _ in first })
        releasesByID = Dictionary(discogsReleases.map { ($0.discogsID, $0) }, uniquingKeysWith: { first, _ in first })

        portraitsByKey = Dictionary(
            ((try? context.fetch(FetchDescriptor<ArtistPortrait>())) ?? [])
                .compactMap { record in record.imageURL.map { (record.nameKey, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        var byArtist: [String: [Recording]] = [:]
        for recording in recordings {
            let key = RecordingKey.normalizeArtist(recording.artistName)
            guard !key.isEmpty else { continue }
            byArtist[key, default: []].append(recording)
        }
        recordingsByArtistKey = byArtist

        var identifiers: [String: String] = [:]
        for (key, group) in byArtist {
            for recording in group {
                guard let found = metadata[recording.id]?.artistMBID, !found.isEmpty else { continue }
                identifiers[key] = found
                break
            }
        }
        mbidByArtistKey = identifiers

        var counts: [String: Int] = [:]
        for item in (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [] {
            let artist = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let artist, !artist.isEmpty else { continue }
            counts[artist, default: 0] += 1
        }
        cratedArtistCounts = counts
    }

    /// Deliberately does not require the cache entry to be fresh. Freshness
    /// governs whether to go and ask Discogs again; it does not govern whether
    /// what Discogs already said is true. An artist's label did not stop being
    /// their label because the row is a day old, and DIG has to keep working
    /// with the network off.
    func discogsArtist(_ key: String) -> DiscogsArtist? { artistsByKey[key] }

    func discogsRelease(_ identifier: Int) -> DiscogsReleaseRecord? { releasesByID[identifier] }

    /// A picture found by the background fill, for somebody nobody has dug
    /// into.
    func portrait(_ key: String) -> URL? { portraitsByKey[key] }

    /// The alias family, remembered for the duration of the walk. Resolving it
    /// closes over the whole artist cache, and both the alias branch and the
    /// peer filter ask for the same one.
    func aliasKeys(of name: String, context: ModelContext) -> Set<String> {
        let key = RecordingKey.normalizeArtist(name)
        if let known = families.value[key] { return known }
        let resolved = AliasResolver(context: context).aliasKeys(of: name)
        families.value[key] = resolved
        return resolved
    }

    func recordings(byArtistKey key: String) -> [Recording] {
        guard !key.isEmpty else { return [] }
        return recordingsByArtistKey[key] ?? []
    }

    func labels(forArtistKey key: String) -> [ArtistProfile.LabelRef] {
        var found: [String: String?] = [:]
        for recording in recordings(byArtistKey: key) {
            guard let entry = metadata[recording.id], let name = entry.labelName else { continue }
            found[name] = entry.labelMBID
        }
        for name in discogsArtist(key)?.labelNames ?? [] where found[name] == nil {
            found.updateValue(nil, forKey: name)
        }
        return found.sorted { $0.key < $1.key }.map { ArtistProfile.LabelRef(name: $0.key, mbid: $0.value) }
    }

    func mbid(forArtistKey key: String) -> String? { mbidByArtistKey[key] }

    func musicLabel(_ mbid: String) -> MusicLabel? {
        var descriptor = FetchDescriptor<MusicLabel>(predicate: #Predicate { $0.mbid == mbid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
