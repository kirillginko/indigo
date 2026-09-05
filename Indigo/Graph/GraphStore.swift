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

    /// How many neighbours one artist is worth working out.
    ///
    /// The page shows six lanes of twelve, and DEEP descends through the same
    /// set — so this is roughly four times the deepest thing anybody has ever
    /// scrolled to, and about a fifth of what the sweep used to build. The
    /// difference was never on screen: it was built, ranked, written to the
    /// store and read back so a `prefix` could throw it away.
    static let peerLimit = 300

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
        /// The tables the last generation read, offered to this one.
        var inherited: Caches?
    }

    init(context: ModelContext, inheriting previous: GraphStore? = nil) {
        self.context = context
        box.inherited = previous?.box.caches
    }

    /// The fold, but only if somebody has already paid for it.
    ///
    /// Assembling it reads four tables whole. The questions below are worth
    /// answering from it when a page is being built — that is the whole point
    /// — but several callers ask one of them in isolation, from an engine
    /// that will never walk anything. Building the entire cache to look up a
    /// single row would turn a saving into a much larger cost, on the main
    /// thread, which is exactly the shape of stall this is meant to remove.
    private var assembledCaches: Caches? { box.caches }

    /// Assembles the fold now, for a caller that is certainly going to need
    /// it.
    ///
    /// Building a profile asks the fold a dozen questions. Without this the
    /// first of them decides whether the rest are answered from an index or
    /// from a table scan, purely by where it happens to sit in the function —
    /// which is not a thing anybody should have to keep in their head.
    func prepare() { _ = caches }

    private var caches: Caches {
        if let existing = box.caches { return existing }
        let fresh = Trace.step("graph.tables") {
            Caches(context: context, reusing: box.inherited)
        }
        box.caches = fresh
        box.inherited = nil
        return fresh
    }

    /// Everything reachable from a node in one step, with the reasons.
    ///
    /// Read from what was worked out last time, when there is one. Deriving
    /// this reads six tables whole; a stored answer is a single indexed query
    /// and survives every unrelated write, which is what stopped background
    /// enrichment from re-costing every page.
    func neighbors(of node: MusicNode) -> EdgeSet {
        if let kept = Trace.step("g.stored", node.key, { stored(for: node) }) { return kept }
        let computed = compute(node)
        Trace.step("g.persist", node.key) { persist(computed, for: node) }
        return computed
    }

    /// Every record an artist is credited on, from the fold rather than from
    /// a scan of the whole table. See `Caches`.
    func releases(creditedTo key: String) -> [DiscogsReleaseRecord] {
        caches.releases(creditedTo: key)
    }

    // MARK: - What the profile builder was scanning for itself
    //
    // Each of these already existed inside `Caches`, folded once when the
    // tables are read, and the graph walk has used them for a while. The
    // profile builder went on answering the same questions with a full table
    // scan apiece — the recordings filtered by a normalised name, every track
    // in the library folded twice, the crate walked per artist — which is
    // most of what a page costs when it re-reads itself after a write. And a
    // cold artist makes it re-read five or six times.

    /// Everything credited to an artist, by the fold rather than by a scan.
    func recordings(byArtistKey key: String) -> [Recording] {
        if let caches = assembledCaches { return caches.recordings(byArtistKey: key) }
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        return all.filter { RecordingKey.normalizeArtist($0.artistName) == key }
    }

    /// What one recording's catalogue entry says, from the dictionary the
    /// tables were read into — or from one indexed row, when they have not
    /// been.
    func metadata(for recordingID: UUID) -> RecordingMetadata? {
        if let caches = assembledCaches { return caches.metadata[recordingID] }
        var descriptor = FetchDescriptor<RecordingMetadata>(
            predicate: #Predicate { $0.recordingID == recordingID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// How many tracks in the listener's own library are this artist's.
    func libraryTrackCount(forArtistKey key: String) -> Int {
        if let caches = assembledCaches { return caches.libraryTrackCount(forArtistKey: key) }
        return LibraryAlbums.shared.index(in: context).trackCounts[key] ?? 0
    }

    /// How much of this artist is in the crate.
    func crateCount(forArtistKey key: String) -> Int {
        if let caches = assembledCaches { return caches.crateCount(forArtistKey: key) }
        let items = (try? context.fetch(FetchDescriptor<CrateItem>())) ?? []
        return items.filter {
            RecordingKey.normalizeArtist($0.recording?.artistName) == key
                || ($0.kind == .artist && RecordingKey.normalizeArtist($0.displayTitle) == key)
        }.count
    }

    /// The walk itself, with nothing remembered.
    func compute(_ node: MusicNode) -> EdgeSet {
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

    // MARK: - Keeping it

    private func stored(for node: MusicNode) -> EdgeSet? {
        let identity = node.id
        var marker = FetchDescriptor<GraphSnapshot>(predicate: #Predicate { $0.nodeID == identity })
        marker.fetchLimit = 1
        guard ((try? context.fetch(marker))?.first) != nil else { return nil }

        let rows = (try? context.fetch(
            FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.fromID == identity })
        )) ?? []
        // A picture found after the edge was written must not be hidden by it.
        //
        // Asked for by name. This used to fetch the whole portrait table on
        // the grounds that it is small — it is not, the background fill adds
        // a row every second and a half — and then to read the fold instead,
        // which is free only where somebody has already paid for the fold.
        //
        // On the main actor nobody has. `DigHistory.suggestions()` builds a
        // GraphStore of its own, and the first stored lookup through it
        // assembled six tables to colour in a handful of rows: 560ms of
        // stopped main thread in the trace, once per revision, which is the
        // hitch that paused the shader. A stored answer is meant to be a
        // couple of indexed queries, and now is one.
        // Built once. Asking each row for its edge to collect the names, and
        // again to assemble the answer, doubles the only real work in here —
        // which `testCostOfTheWalkThePageActuallyAsksFor` notices.
        let built = rows.map { $0.edge(from: node) }
        let portraits = portraitURLs(
            forKeys: built.compactMap { $0.to.artworkURL == nil ? $0.to.key : nil }
        )
        var edges = EdgeSet()
        for original in built {
            var edge = original
            if edge.to.artworkURL == nil, let portrait = portraits[edge.to.key] {
                var destination = edge.to
                destination.artworkURL = portrait
                edge = MusicEdge(
                    from: edge.from, to: destination, kind: edge.kind, source: edge.source,
                    reason: edge.reason, confidence: edge.confidence, occurrences: edge.occurrences
                )
            }
            edges.insert(edge)
        }
        return edges
    }

    /// Pictures for exactly these names.
    ///
    /// Reads the fold where one has already been assembled — the profile
    /// builder asks it a dozen questions and always has — and otherwise asks
    /// the store, which is one query against `nameKey` rather than a reason
    /// to read six tables whole.
    private func portraitURLs(forKeys keys: [String]) -> [String: URL] {
        guard !keys.isEmpty else { return [:] }
        if let caches = assembledCaches {
            return Dictionary(
                keys.compactMap { key in caches.portrait(key).map { (key, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let wanted = Array(Set(keys))
        let descriptor = FetchDescriptor<ArtistPortrait>(
            predicate: #Predicate { wanted.contains($0.nameKey) }
        )
        return Dictionary(
            ((try? context.fetch(descriptor)) ?? [])
                .compactMap { record in record.imageURL.map { (record.nameKey, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func persist(_ edges: EdgeSet, for node: MusicNode) {
        let identity = node.id
        for existing in (try? context.fetch(
            FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.fromID == identity })
        )) ?? [] {
            context.delete(existing)
        }
        for edge in edges.all { context.insert(StoredEdge(from: node, edge: edge)) }

        var marker = FetchDescriptor<GraphSnapshot>(predicate: #Predicate { $0.nodeID == identity })
        marker.fetchLimit = 1
        if let existing = (try? context.fetch(marker))?.first {
            existing.builtAt = Date()
        } else {
            context.insert(GraphSnapshot(nodeID: identity))
        }
        try? context.save()
    }

    /// Throws away what was worked out about a node, because what it was
    /// worked out from has changed.
    static func forget(_ node: MusicNode, in context: ModelContext) {
        let identity = node.id
        for row in (try? context.fetch(
            FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.fromID == identity })
        )) ?? [] {
            context.delete(row)
        }
        var marker = FetchDescriptor<GraphSnapshot>(predicate: #Predicate { $0.nodeID == identity })
        marker.fetchLimit = 1
        if let existing = (try? context.fetch(marker))?.first { context.delete(existing) }
    }

    /// The artists reachable from an artist, which is the RELATED list.
    /// Kept as a named entry point because it is asked for constantly and
    /// filtering a full walk down to one kind every time would be wasteful.
    func relatedArtists(to node: MusicNode) -> [(node: MusicNode, edges: [MusicEdge], confidence: Double)] {
        // The alias branch is not the peer list. Traumprinz is not a good way
        // to broaden out from Traumprinz, however strongly the two are
        // connected — that is what the aliases section is for.
        let family = caches.aliasKeys(of: node.title, context: context)
        return neighbors(of: node).byDestination.filter {
            $0.node.kind == .artist && !family.contains($0.node.key)
        }
    }

    // MARK: - Artist

    private func addArtistNeighbors(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        addAliasFamily(node, caches: caches, into: &edges)
        addArtistCatalogue(node, caches: caches, into: &edges)
        addArtistBroadcasts(node, caches: caches, into: &edges)
        addArtistPeers(node, caches: caches, into: &edges)
    }

    /// The alias branch. Distinct nodes joined by a strong edge, never merged
    /// into one — the names are different on purpose.
    private func addAliasFamily(_ node: MusicNode, caches: Caches, into edges: inout EdgeSet) {
        let family = caches.resolver(context: context).family(of: node.title)
        // Cleaned here too. This branch builds its edges itself rather than
        // going through `link`, which is why "Danny Miller (2)" was still
        // arriving under ALIASES & PROJECTS after every other route had been
        // put right.
        let primary = DiscogsClient.withoutDisambiguator(family.primary)
        for member in family.members {
            let reason: String
            let kind: RelationshipKind
            switch member.role {
            case .alias, .primary:
                kind = .sameAlias
                reason = "Also records as \(primary)"
            case .project:
                kind = .aliasOrProject
                reason = "\(primary) is part of \(DiscogsClient.withoutDisambiguator(member.name))"
            case .member:
                kind = .aliasOrProject
                reason = "Makes up \(family.primary)"
            }
            edges.insert(MusicEdge(
                from: node,
                to: .artist(DiscogsClient.withoutDisambiguator(member.name)),
                kind: kind, source: .discogs,
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

        // Styles are not places, so they are no longer offered as ones.
        //
        // A style node cannot be opened — nothing in `AppState` routes to
        // one — and `compute` returns nothing for it, so descending into one
        // was always going to be a dead end. They filled DEEP with rows that
        // could not be clicked and said nothing that the genre chips at the
        // top of the page do not already say, and every one of them was an
        // edge to build, store and walk.
        //
        // The styles two artists share still connect *them*: that is the
        // "same frequency" lane, and it is an edge between people.
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
            _ originalName: String,
            _ kind: RelationshipKind,
            _ source: RelationshipSource,
            _ reason: String,
            confidence: Double? = nil,
            occurrences: Int = 1,
            key precomputed: String? = nil
        ) {
            let name = originalName
            // Cleaned here, where names are read, rather than only where they
            // are written.
            //
            // Cleaning the fetch fixes rows nobody has yet; every artist
            // already cached keeps "Bing (14)" and "Hayden James, Bob Moses
            // (5)" in their stored neighbour lists, and those are the rows on
            // the page. A name is only worth offering if something is filed
            // under it, so it is put right on the way out as well as on the
            // way in.
            // Deliberately decided by the name alone, never by the cache.
            //
            // Asking "are both halves artists we know?" split a row into two
            // the moment enrichment happened to learn the second half — so
            // names changed and rows vanished while somebody was reading the
            // page. A rule whose answer moves under the reader is worse than
            // the ambiguity it was resolving.
            let credited = DiscogsClient.creditedNames(name)
            guard let name = credited.first else { return }
            for extra in credited.dropFirst() {
                link(extra, kind, source, reason, confidence: confidence, occurrences: occurrences)
            }
            // A precomputed key belongs to the name as it was stored; if
            // cleaning changed it, that key is no longer the right one.
            let key = credited.count == 1 && name == originalName
                ? (precomputed ?? RecordingKey.normalizeArtist(name))
                : RecordingKey.normalizeArtist(name)
            // An artist's own aliases belong on the alias branch, not in the
            // peer list, or every family member arrives twice. And "Various"
            // is a filing convention rather than a person — left in, it would
            // join every compilation in the catalogue to every other one.
            guard !key.isEmpty, !family.contains(key), ArtistName.isRealArtist(name) else { return }
            // Everything already stored was filed under the name as it came
            // from Discogs, marks and all. Cleaning the name for display
            // changed the key it is looked up by — so portraits, catalogue
            // rows and neighbour pictures all stopped being found, and the
            // rows went blank. Both keys are tried: the tidy one first, the
            // one on disk behind it.
            // Only when cleaning actually changed the name. Otherwise it is
            // the key that was just worked out, and folding it a second time
            // is nine case-insensitive searches for the same answer.
            let storedKey = name == originalName
                ? key : RecordingKey.normalizeArtist(originalName)
            let mbid = caches.mbid(forArtistKey: key) ?? caches.mbid(forArtistKey: storedKey)
            var destination = MusicNode.artist(name, key: key, mbid: mbid)
            // Their own portrait when we have already dug into them; otherwise
            // a record of theirs, which came free with the search that found
            // them. Either beats an empty box in a row of forty.
            let peer = caches.discogsArtist(key) ?? caches.discogsArtist(storedKey)
            destination.artworkURL = peer?.imageURL
                ?? caches.portrait(key)
                ?? caches.portrait(storedKey)
                ?? discogs?.neighbourImageURL(for: name)
                ?? discogs?.neighbourImageURL(for: originalName)
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
        Trace.step("p.shapes") {
        if let subject = caches.shape(of: subject) {
            // Normalised once, in `Caches`, rather than on every comparison.
            //
            // This loop runs over every artist the app has ever cached, and it
            // used to normalise each of their labels, styles and years inside
            // the comparison — tens of thousands of foldings for one page, at
            // about twenty microseconds each. That was four fifths of the time
            // it took to open an artist.
            //
            // It no longer runs over every artist either. `peerCandidates`
            // starts from the subject's own imprints and styles and returns
            // the best of what shares one — see the reasoning there.
            for peer in caches.peerCandidates(
                for: subject, excluding: family, limit: Self.peerLimit
            ) {
                let sharedLabel = subject.sharedLabel(with: peer)
                let sharedStyles = subject.styleKeys.intersection(peer.styleKeys)
                let sharedStyle = subject.style(forKey: sharedStyles.first)

                if let sharedLabel {
                    link(peer.name, .sharedLabel, .discogs, "Both release on \(sharedLabel)",
                         confidence: 0.8, key: peer.key)
                }
                if let sharedStyle {
                    link(peer.name, .sharedStyle, .discogs, "Shared sound: \(sharedStyle)",
                         occurrences: sharedStyles.count, key: peer.key)
                }

                // Working at the same time is not a connection. Everybody who
                // put a record out in the 2010s did, and offering that as a
                // reason filled the list with strangers.
                //
                // It is worth something as a *qualifier*: two artists on the
                // same imprint, or in the same style, whose catalogues also
                // overlap are contemporaries rather than coincidences. So it
                // is only said where there is already something to say it
                // about, and it says what it is qualifying.
                if let decade = subject.decades.intersection(peer.decades).max(),
                   sharedLabel != nil || sharedStyle != nil {
                    let what = sharedLabel ?? sharedStyle ?? ""
                    link(peer.name, .sameEra, .discogs,
                         "\(what) in the \(decade)s", key: peer.key)
                }
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
        link: (String, RelationshipKind, RelationshipSource, String, Double?, Int, String?) -> Void
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
            link(peer, .sharedBroadcast, .radio, reason, nil, evidence.count, nil)
        }
    }

    private func addCollectionPeers(
        _ node: MusicNode,
        family: Set<String>,
        caches: Caches,
        link: (String, RelationshipKind, RelationshipSource, String, Double?, Int, String?) -> Void
    ) {
        // Both of these used to be a scan of the whole library, and the
        // first one normalised two names for every track it looked at. That
        // is eight thousand foldings to answer one artist's page, on every
        // walk, growing with the size of somebody's music folder rather than
        // with anything they were asking about. Filed once when the tables
        // are read, the same answer costs a dictionary lookup.
        let albums = caches.albumKeys(forArtistKeys: family)
        guard !albums.isEmpty else { return }
        for album in albums {
            for track in caches.tracks(onAlbumKey: album) {
                let peer = track.artist.isEmpty ? track.albumArtist : track.artist
                guard !peer.isEmpty else { continue }
                link(peer, .sharedCollection, .library,
                     "Together in your library: \(track.album)", nil, 1, nil)
            }
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
        // See above: a style is a lens, not a place to go.
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
    let discogsArtists: [DiscogsArtist]
    let discogsReleases: [DiscogsReleaseRecord]
    let metadata: [UUID: RecordingMetadata]
    let cratedArtistCounts: [String: Int]

    private let artistsByKey: [String: DiscogsArtist]
    private let releasesByID: [Int: DiscogsReleaseRecord]
    /// Records filed by who is credited on them.
    private let releasesByArtistKey: [String: [DiscogsReleaseRecord]]
    /// Grouped once. Filtering the whole recording table per peer turns a
    /// RELATED list of forty into forty full scans, which is what made
    /// opening an artist page slow.
    private let shapeIndex: (values: [Shape], byKey: [String: Shape])
    /// Which artists share an imprint, and which share a style.
    ///
    /// The peer sweep used to look at every artist in the store and ask each
    /// one whether it had anything in common with the subject. At the size a
    /// real cache reaches that was the whole cost of opening a page — 229ms
    /// of a 234ms walk — and almost all of it spent deciding "no". These two
    /// indexes turn the question round: only the artists that actually share
    /// something are visited, and the answer is the same set it always was.
    private let shapeIndicesByLabelKey: [String: [Int]]
    private let shapeIndicesByStyleKey: [String: [Int]]
    private let portraitsByKey: [String: URL]
    /// When that dictionary was last brought up to date, so the next build can
    /// ask only for what has arrived since.
    private let portraitsReadAt: Date
    private let recordingsByArtistKey: [String: [Recording]]
    /// Which albums an artist appears on, and what is on each album.
    private let albumKeysByArtistKey: [String: Set<String>]
    private let tracksByAlbumKey: [String: [LibraryAlbums.Entry]]
    private let mbidByArtistKey: [String: String]
    /// Counted once when the tables are read, rather than by scanning the
    /// library and the crate again for every question a page asks.
    private let libraryCountsByArtistKey: [String: Int]
    private let crateCountsByArtistKey: [String: Int]
    private let context: ModelContext
    private let families = FamilyBox()

    private final class FamilyBox {
        var value: [String: Set<String>] = [:]
    }

    /// How many rows each table held when this was read.
    ///
    /// Materialising the artist and release tables is three quarters of the
    /// cost of assembling this cache — 963ms and 533ms at the size a real
    /// session reaches — and every write throws the cache away, so one page
    /// load pays for it several times over.
    ///
    /// These arrays hold live SwiftData objects, so an edit to a row is
    /// already visible through them; only an insertion or a deletion is not.
    /// A count is a `SELECT COUNT(*)` rather than a table read, which is
    /// enough to know whether the expensive half has to happen at all. The
    /// derived indexes below are rebuilt regardless, because those *are*
    /// snapshots of what the rows said.
    let rowCounts: [Int]

    /// When each shape's row was last rewritten, in the order the shapes are
    /// held. See the reuse in `init`.
    private let shapeStamps: [Date?]

    static func rowCounts(in context: ModelContext) -> [Int] {
        [
            (try? context.fetchCount(FetchDescriptor<Recording>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<DiscogsArtist>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<DiscogsReleaseRecord>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<RecordingMetadata>())) ?? -1,
            // Both of these were read in full on every build and never
            // inherited, because neither was in this list. The portrait table
            // is the one that hurt: the background fill writes to it all
            // session, so it is both the largest of them and the one most
            // often unchanged between two questions about the same page.
            // A portrait row is always inserted whole and never edited
            // afterwards, so a count is a complete answer about it.
            (try? context.fetchCount(FetchDescriptor<ArtistPortrait>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<CrateItem>())) ?? -1
        ]
    }

    init(context: ModelContext, reusing previous: Caches? = nil) {
        self.context = context
        let store = context
        let counts = Trace.step("t.counts") { Self.rowCounts(in: store) }
        rowCounts = counts

        // Each table is inherited on its own count, not on all four agreeing.
        //
        // Digging into somebody new inserts one artist row — and that used to
        // discard the release, recording and metadata tables along with it,
        // none of which had changed. It is the commonest write there is, and
        // it was the most expensive: the whole cache read again to learn one
        // artist. Now the artist table is re-read and the other three are
        // handed over.
        func kept<T>(_ index: Int, _ value: (Caches) -> T) -> T? {
            guard let previous, previous.rowCounts.count == counts.count,
                  previous.rowCounts[index] == counts[index] else { return nil }
            return value(previous)
        }

        let fetchedRecordings = kept(0, \.recordings)
            ?? Trace.step("t.recordings") { (try? store.fetch(FetchDescriptor<Recording>())) ?? [] }
        // The library, folded once for the process rather than per cache.
        let library = Trace.step("t.tracks") { LibraryAlbums.shared.index(in: store) }
        let fetchedArtists = kept(1, \.discogsArtists)
            ?? Trace.step("t.artists") { (try? store.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] }
        let inheritedReleases = kept(2, \.discogsReleases)
        let fetchedReleases = inheritedReleases
            ?? Trace.step("t.releases") { (try? store.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? [] }
        let entries = kept(3) { Array($0.metadata.values) }
            ?? Trace.step("t.metadata") { (try? store.fetch(FetchDescriptor<RecordingMetadata>())) ?? [] }
        recordings = fetchedRecordings
        discogsArtists = fetchedArtists
        discogsReleases = fetchedReleases
        let builtDicts = Trace.step("t.dicts") {(
            Dictionary(entries.map { ($0.recordingID, $0) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(fetchedArtists.map { ($0.nameKey, $0) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(fetchedReleases.map { ($0.discogsID, $0) }, uniquingKeysWith: { first, _ in first })
        )}
        metadata = builtDicts.0
        artistsByKey = builtDicts.1
        releasesByID = builtDicts.2

        // Who is on what, folded once.
        //
        // Building an artist's profile filtered the whole release table and
        // normalised every credit on every record to do it — for one artist,
        // and again for the next. With a few thousand records cached that was
        // the better part of a second per page, and it grew with every record
        // anybody had ever opened.
        var byCredit: [String: [DiscogsReleaseRecord]] = [:]
        Trace.step("t.releaseCredits") {
            // The fold belongs to the release table, so it travels with it.
            if inheritedReleases != nil, let previous {
                byCredit = previous.releasesByArtistKey
                return
            }
            var folded: [String: String] = [:]
            for release in fetchedReleases {
                for raw in release.artistNames where !raw.isEmpty {
                    let key: String
                    if let known = folded[raw] { key = known } else {
                        key = RecordingKey.normalizeArtist(raw)
                        folded[raw] = key
                    }
                    guard !key.isEmpty else { continue }
                    byCredit[key, default: []].append(release)
                }
            }
        }
        releasesByArtistKey = byCredit

        // Shapes are snapshots, so an inherited one is only good while the
        // row it was folded from has not been rewritten. `write` stamps
        // `fetchedAt` every time it touches an artist's labels, styles or
        // years — which are the only fields a shape reads — so that stamp is
        // exactly the question to ask. Reading two properties off a row is a
        // fraction of folding one, and the real trace has this rebuilt 523
        // times for 187 actual reads of the table.
        // Offered whatever else was inherited: a shape is keyed by the row it
        // was folded from and the moment that row was last written, so one new
        // artist costs one new shape rather than five thousand.
        let previousShapes = Trace.step("t.prevShapes") {
            previous.map { previous in
                Dictionary(
                    zip(previous.shapeIndex.values, previous.shapeStamps).map { ($0.key, ($1, $0)) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
        var stamps: [Date?] = []
        stamps.reserveCapacity(fetchedArtists.count)
        let shaped = Trace.step("t.shapes") {
            fetchedArtists.map { artist -> Shape in
                let stamp = artist.fetchedAt
                stamps.append(stamp)
                if let kept = previousShapes?[artist.nameKey], kept.0 == stamp { return kept.1 }
                return Shape(artist)
            }
        }
        shapeStamps = stamps
        shapeIndex = (
            shaped,
            Dictionary(shaped.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        )

        // Filed by what makes two artists neighbours, so the sweep can start
        // from the subject's own imprints and styles rather than from the
        // whole table.
        var byLabel: [String: [Int]] = [:]
        var byStyle: [String: [Int]] = [:]
        Trace.step("t.peerIndex") {
            for (index, shape) in shaped.enumerated() {
                for key in shape.labels.keys { byLabel[key, default: []].append(index) }
                for key in shape.styleKeys { byStyle[key, default: []].append(index) }
            }
        }
        shapeIndicesByLabelKey = byLabel
        shapeIndicesByStyleKey = byStyle

        // Only the pictures that have arrived since the last look.
        //
        // Reading this table whole was 243ms of a 614ms fold rebuild, and it
        // was paid on nearly every one: the background fill inserts a row
        // every second and a half for as long as the app is open, so its
        // count is almost never the same twice and `kept` almost never held.
        // That is the biggest single thing a cold page waits for.
        //
        // A row here is written once and never edited, and the one place that
        // replaces an attempt deletes and re-inserts — so the replacement
        // carries a newer `fetchedAt` too. Everything that can have changed
        // is therefore newer than the last read, which also makes this more
        // correct than the count was: a delete paired with an insert leaves
        // the count alone, and used to be inherited straight past.
        let portraitsCutoff = Date()
        if let previous {
            let since = previous.portraitsReadAt
            portraitsByKey = Trace.step("t.portraits.since") {
                var merged = previous.portraitsByKey
                for record in (try? store.fetch(FetchDescriptor<ArtistPortrait>(
                    predicate: #Predicate { $0.fetchedAt > since }
                ))) ?? [] {
                    guard let url = record.imageURL else { continue }
                    merged[record.nameKey] = url
                }
                return merged
            }
        } else {
            portraitsByKey = Trace.step("t.portraits") {
                Dictionary(
                    ((try? store.fetch(FetchDescriptor<ArtistPortrait>())) ?? [])
                        .compactMap { record in record.imageURL.map { (record.nameKey, $0) } },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        }
        // Captured before the read rather than after, so a row written while
        // it ran is picked up next time instead of missed by both.
        portraitsReadAt = portraitsCutoff

        albumKeysByArtistKey = library.albums
        tracksByAlbumKey = library.entries
        libraryCountsByArtistKey = library.trackCounts

        var byArtist: [String: [Recording]] = [:]
        Trace.step("t.groupRecordings") {
        for recording in fetchedRecordings {
            let key = RecordingKey.normalizeArtist(recording.artistName)
            guard !key.isEmpty else { continue }
            byArtist[key, default: []].append(recording)
        }
        }
        recordingsByArtistKey = byArtist

        var identifiers: [String: String] = [:]
        Trace.step("t.mbids") {
        for (key, group) in byArtist {
            for recording in group {
                guard let found = builtDicts.0[recording.id]?.artistMBID, !found.isEmpty else { continue }
                identifiers[key] = found
                break
            }
        }
        }
        mbidByArtistKey = identifiers

        let crateCounts = kept(5) { ($0.cratedArtistCounts, $0.crateCountsByArtistKey) }
            ?? Trace.step("t.crate") { () -> ([String: Int], [String: Int]) in
                var bySpelling: [String: Int] = [:]
                var byKey: [String: Int] = [:]
                for item in (try? store.fetch(FetchDescriptor<CrateItem>())) ?? [] {
                    let artist = item.recording?.artistName
                        ?? (item.kind == .artist ? item.displayTitle : nil)
                    guard let artist, !artist.isEmpty else { continue }
                    bySpelling[artist, default: 0] += 1
                    let key = RecordingKey.normalizeArtist(artist)
                    guard !key.isEmpty else { continue }
                    byKey[key, default: 0] += 1
                }
                return (bySpelling, byKey)
            }
        cratedArtistCounts = crateCounts.0
        crateCountsByArtistKey = crateCounts.1
    }

    /// Deliberately does not require the cache entry to be fresh. Freshness
    /// governs whether to go and ask Discogs again; it does not govern whether
    /// what Discogs already said is true. An artist's label did not stop being
    /// their label because the row is a day old, and DIG has to keep working
    /// with the network off.
    func discogsArtist(_ key: String) -> DiscogsArtist? { artistsByKey[key] }

    func discogsRelease(_ identifier: Int) -> DiscogsReleaseRecord? { releasesByID[identifier] }

    /// Every record this artist is credited on.
    func releases(creditedTo key: String) -> [DiscogsReleaseRecord] {
        releasesByArtistKey[key] ?? []
    }

    /// An artist reduced to the keys the peer walk compares on, folded once.
    nonisolated struct Shape {
        let key: String
        let name: String
        /// Normalised label key to the spelling worth showing.
        let labels: [String: String]
        let styleKeys: Set<String>
        private let styles: [String: String]
        let decades: Set<Int>

        init(_ artist: DiscogsArtist) {
            key = artist.nameKey
            name = artist.name
            var foundLabels: [String: String] = [:]
            for label in artist.labelNames where LabelName.isRealLabel(label) {
                foundLabels[RecordingKey.normalize(label)] = label
            }
            labels = foundLabels
            var foundStyles: [String: String] = [:]
            for style in artist.styles { foundStyles[RecordingKey.normalize(style)] = style }
            styles = foundStyles
            styleKeys = Set(foundStyles.keys)
            decades = Set(artist.releaseYears.compactMap {
                guard let value = Int($0.prefix(4)), value > 0 else { return nil }
                return value / 10 * 10
            })
        }

        func sharedLabel(with peer: Shape) -> String? {
            for (key, spelling) in labels where peer.labels[key] != nil { return spelling }
            return nil
        }

        func style(forKey key: String?) -> String? { key.flatMap { styles[$0] } }
    }

    var shapes: [Shape] { shapeIndex.values }

    func shape(of key: String) -> Shape? { shapeIndex.byKey[key] }

    /// The artists worth comparing this one against, best first.
    ///
    /// Two things are going on here. The candidates come from the imprint and
    /// style indexes rather than from the whole table, because an artist with
    /// nothing in common produces no edge and there is no reason to visit
    /// them. And the list is cut: a page shows six lanes of twelve, and a
    /// popular style in a well-dug store has thousands of members — building
    /// an edge for each, sorting them, writing them to the store and reading
    /// them back so a `prefix(12)` can discard them is the largest piece of
    /// work in DIG that nobody ever sees.
    ///
    /// What survives the cut is chosen rather than truncated: an imprint in
    /// common outranks a sound in common, more shared styles outrank fewer,
    /// and a shared decade breaks the tie — which is the same order the lanes
    /// themselves are built in. `limit` is far above what any lane shows, so
    /// DEEP still has a neighbourhood to descend through.
    func peerCandidates(for subject: Shape, excluding family: Set<String>, limit: Int) -> [Shape] {
        var seen = Set<Int>()
        var candidates: [Int] = []
        for key in subject.labels.keys {
            for index in shapeIndicesByLabelKey[key] ?? [] where seen.insert(index).inserted {
                candidates.append(index)
            }
        }
        for key in subject.styleKeys {
            for index in shapeIndicesByStyleKey[key] ?? [] where seen.insert(index).inserted {
                candidates.append(index)
            }
        }

        let shapes = shapeIndex.values
        var ranked: [(rank: Int, styles: Int, era: Bool, shape: Shape)] = []
        ranked.reserveCapacity(candidates.count)
        for index in candidates {
            let peer = shapes[index]
            guard peer.key != subject.key, !family.contains(peer.key) else { continue }
            let sharedStyles = subject.styleKeys.intersection(peer.styleKeys).count
            let sharedLabel = subject.sharedLabel(with: peer) != nil
            ranked.append((
                rank: sharedLabel ? 0 : 1,
                styles: sharedStyles,
                era: !subject.decades.isDisjoint(with: peer.decades),
                shape: peer
            ))
        }
        guard ranked.count > limit else { return ranked.map(\.shape) }
        return ranked.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            if left.styles != right.styles { return left.styles > right.styles }
            if left.era != right.era { return left.era }
            return left.shape.key < right.shape.key
        }.prefix(limit).map(\.shape)
    }

    /// A picture found by the background fill, for somebody nobody has dug
    /// into.
    func portrait(_ key: String) -> URL? { portraitsByKey[key] }

    /// The alias family, remembered for the duration of the walk. Resolving it
    /// closes over the whole artist cache, and both the alias branch and the
    /// peer filter ask for the same one.
    func aliasKeys(of name: String, context: ModelContext) -> Set<String> {
        let key = RecordingKey.normalizeArtist(name)
        if let known = families.value[key] { return known }
        let resolved = resolver(context: context).aliasKeys(of: name)
        families.value[key] = resolved
        return resolved
    }

    /// A resolver over the artists already fetched, rather than one that goes
    /// back to the store for them.
    func resolver(context: ModelContext) -> AliasResolver {
        AliasResolver(context: context, artists: discogsArtists)
    }

    /// Every album any of these artists appears on.
    func albumKeys(forArtistKeys family: Set<String>) -> Set<String> {
        var found: Set<String> = []
        for key in family { found.formUnion(albumKeysByArtistKey[key] ?? []) }
        return found
    }

    func tracks(onAlbumKey key: String) -> [LibraryAlbums.Entry] { tracksByAlbumKey[key] ?? [] }

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

    /// The library counted by artist rather than scanned per question.
    func libraryTrackCount(forArtistKey key: String) -> Int {
        libraryCountsByArtistKey[key] ?? 0
    }

    /// The crate counted the same way. `cratedArtistCounts` is filed by the
    /// spelling the crate used, because the peer walk offers those names back
    /// to the listener; this one is filed by key, because a count is a count.
    func crateCount(forArtistKey key: String) -> Int {
        crateCountsByArtistKey[key] ?? 0
    }

    func musicLabel(_ mbid: String) -> MusicLabel? {
        var descriptor = FetchDescriptor<MusicLabel>(predicate: #Predicate { $0.mbid == mbid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

// MARK: - The library, folded

/// What the graph asks of somebody's music folder, worked out once.
///
/// The "together in your library" lane needs to know which albums an artist
/// appears on and who else is on those albums. Deriving that read every
/// `Track` — measured at 317ms of the 700ms it took to assemble the graph's
/// caches — and it was done again on every write, because every write throws
/// the caches away. A music folder does not change because somebody opened an
/// artist page.
///
/// So it is held for the life of the process and keyed on two cheap queries:
/// how many tracks there are, and the highest scan generation among them. An
/// import or a rescan moves one of those and the fold is redone; nothing else
/// costs more than the two counts.
///
/// Deliberately holds values rather than `Track` objects: a managed object
/// belongs to the context that fetched it, and this outlives any of them.
nonisolated final class LibraryAlbums: @unchecked Sendable {
    struct Entry: Sendable {
        let artist: String
        let albumArtist: String
        let album: String
    }

    struct Index: Sendable {
        let albums: [String: Set<String>]
        let entries: [String: [Entry]]
        /// How many tracks each artist has in the library.
        ///
        /// The artist page asked this by fetching every track and folding two
        /// names for each of them, which is the scan this fold exists to
        /// replace — it was simply never wired to it. A track credited to one
        /// performer on somebody else's album counts for both, and counts
        /// once for either, which is what the set here preserves.
        let trackCounts: [String: Int]
    }

    static let shared = LibraryAlbums()

    private let lock = NSLock()
    private var signature: [Int]?
    /// Which store the held fold was read from.
    ///
    /// Counts alone do not identify a library: two stores can hold the same
    /// number of tracks and hand each other the wrong answer. Tests do this
    /// routinely, and one day so would a second window.
    private var source: ObjectIdentifier?
    private var held = Index(albums: [:], entries: [:], trackCounts: [:])

    func index(in context: ModelContext) -> Index {
        let current = Self.signature(in: context)
        let store = ObjectIdentifier(context.container)
        lock.lock()
        if let signature, signature == current, source == store {
            let answer = held
            lock.unlock()
            return answer
        }
        lock.unlock()

        let built = Self.build(in: context)
        lock.lock()
        signature = current
        source = store
        held = built
        lock.unlock()
        return built
    }

    /// Two counts, which is a pair of `SELECT`s rather than a table read.
    private static func signature(in context: ModelContext) -> [Int] {
        let count = (try? context.fetchCount(FetchDescriptor<Track>())) ?? -1
        var newest = FetchDescriptor<Track>(
            sortBy: [SortDescriptor(\Track.scanGeneration, order: .reverse)]
        )
        newest.fetchLimit = 1
        newest.propertiesToFetch = [\.scanGeneration]
        let generation = (try? context.fetch(newest))?.first?.scanGeneration ?? -1
        return [count, generation]
    }

    private static func build(in context: ModelContext) -> Index {
        let tracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var albums: [String: Set<String>] = [:]
        var entries: [String: [Entry]] = [:]
        var counts: [String: Int] = [:]
        // Folded once per name, not once per track. A library is thousands of
        // files by hundreds of artists, so normalising every track's two
        // credits repeats the same fold over and over.
        var folded: [String: String] = [:]
        func key(_ raw: String) -> String {
            if let known = folded[raw] { return known }
            let value = RecordingKey.normalizeArtist(raw)
            folded[raw] = value
            return value
        }
        for track in tracks {
            // Counted for every track, including the ones filed under no
            // album — a loose file is still a track by somebody.
            var credited = Set<String>()
            for raw in [track.artist, track.albumArtist] where !raw.isEmpty {
                let artistKey = key(raw)
                guard !artistKey.isEmpty else { continue }
                credited.insert(artistKey)
            }
            for artistKey in credited { counts[artistKey, default: 0] += 1 }

            let album = track.albumKey
            guard !album.isEmpty else { continue }
            entries[album, default: []].append(Entry(
                artist: track.artist, albumArtist: track.albumArtist, album: track.album
            ))
            for artistKey in credited { albums[artistKey, default: []].insert(album) }
        }
        return Index(albums: albums, entries: entries, trackCounts: counts)
    }
}
