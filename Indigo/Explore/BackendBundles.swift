//
//  BackendBundles.swift
//  Indigo
//
//  Artist knowledge bundles from R2, for the backend's For You in shadow.
//
//  The backend's SQL answer knows labels, releases and radio, but not who made
//  records with whom: credits and collaborations live in Discogs' release
//  documents, which the worker folds into one bundle per artist
//  (supabase/functions/_shared/artist_bundle.ts) and publishes under its
//  digest, with a small reference per artist naming the current one. This
//  reads them for the starting points the backend can name by Discogs id, and
//  turns what they say into edges -- each kind of relationship kept apart, with
//  the record it rests on in its reason.
//
//  Bundles are kept by digest: an object under a digest never changes, so one
//  fetched and checked is kept for good. References are asked for again once
//  per edge generation. Every bundle is checked against its reference's digest
//  before anything is read from it. An artist without one is reported, never
//  filled in from this device's own Discogs cache.
//

import CryptoKit
import Foundation

// MARK: - What R2 holds

/// The fields of an artist bundle the shadow reads (format
/// indigo.artist-knowledge/1). Unknown fields are ignored, so the worker can
/// add to the format without breaking this.
nonisolated struct ArtistBundle: Codable, Sendable, Equatable {
    struct Person: Codable, Sendable, Equatable {
        let discogsID: Int?
        let name: String
        let anv: String?
    }
    struct Release: Codable, Sendable, Equatable {
        let id: Int
        let masterID: Int?
        let title: String
        let year: Int?
        let relation: String
        let compilation: Bool
    }
    struct Count: Codable, Sendable, Equatable {
        let name: String
        let releases: Int
    }
    struct Label: Codable, Sendable, Equatable {
        let discogsID: Int?
        let name: String
        let display: String
        let releases: Int
        let placeholder: Bool
        let ownName: Bool
    }
    struct Collaborator: Codable, Sendable, Equatable {
        let artist: Person
        let how: [String]
        let releases: [Int]
    }
    struct Credit: Codable, Sendable, Equatable {
        struct Role: Codable, Sendable, Equatable {
            struct On: Codable, Sendable, Equatable {
                let id: Int
                let tracks: [String]
            }
            let role: String
            let kind: String?
            let releases: [On]
        }
        let artist: Person
        let roles: [Role]
    }
    struct Source: Codable, Sendable, Equatable {
        let identity: String
        let discography: String?
        let complete: Bool
        let truncated: Bool
        let totalReported: Int?
        let pagesReported: Int?
        let pagesFetched: Int
        let entries: Int
        let representativeReleases: Int
        let documentsRead: Int
        let documentsMissing: Int
        let documentsTruncated: Int
        let otherPressingsRead: Int?
    }
    struct Artist: Codable, Sendable, Equatable {
        let discogsID: Int
        let name: String
    }

    let format: String
    let artist: Artist
    let releases: [Release]
    let styles: [Count]
    let genres: [Count]
    let stylesAround: [Count]
    let labels: [Label]
    let collaborators: [Collaborator]
    let credits: [Credit]
    let source: Source?
}

/// An artist's current bundle, as its reference names it.
nonisolated struct ArtistBundleRef: Codable, Sendable, Equatable {
    let artist: Int
    let digest: String
    let key: String
    let builtAt: String
    let bytes: Int
    /// What the bundle was built from, repeated on the reference so its
    /// completeness can be told before the bundle itself is read.
    let source: ArtistBundle.Source?
}

// MARK: - Fetching and keeping

/// How an artist's bundle stands, for the diagnostics.
nonisolated struct BundleStatus: Codable, Sendable, Equatable {
    /// The starting point it was asked for.
    let node: String
    let discogsID: Int?
    /// `complete` (every release the discovered Discogs entries name was
    /// read -- complete relative to what Discogs lists, which is not the same
    /// as everything the artist made), `partial` (some missing, truncated, or
    /// discovery incomplete), `missing` (no bundle published), `no-identity`
    /// (the backend knows no catalogued Discogs id for it), `failed` (could
    /// not be fetched or did not match its digest). `stale` is added when the
    /// reference could not be refreshed this generation.
    let status: String
    let detail: String
}

nonisolated struct BundleCache: Codable, Sendable, Equatable {
    struct KeptRef: Codable, Sendable, Equatable {
        /// Nil: asked, and there was none.
        var ref: ArtistBundleRef?
        var generation: String
        var fetchedAt: Date
    }
    var refs: [String: KeptRef] = [:]
    /// By digest. An addressed object never changes.
    var bundles: [String: ArtistBundle] = [:]

    static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("explore-backend-bundles.json")
    }

    static func load(from url: URL?) -> BundleCache {
        guard let url, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(BundleCache.self, from: data) else { return .init() }
        return cache
    }

    /// Without the bundles no reference names any more: a bundle is kept for
    /// good only while something still points at it.
    func save(to url: URL?) {
        var kept = self
        let named = Set(refs.values.compactMap { $0.ref?.digest })
        kept.bundles = bundles.filter { named.contains($0.key) }
        guard let url, let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

nonisolated enum BundleFetcher {
    /// Reads one object by its key; the status, and the body when 200.
    typealias Read = @Sendable (String) async throws -> (status: Int, data: Data?)

    @Sendable static func live(_ key: String) async throws -> (status: Int, data: Data?) {
        guard let host = SupabaseConfiguration.catalogCacheHost, !host.contains("/"),
              let url = URL(string: "https://\(host)/\(key)") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, status == 200 ? data : nil)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What one round of reading did.
    struct Report: Codable, Sendable, Equatable {
        var reads = 0
        var bytes = 0
        var errors: [String] = []
    }

    /// Brings the bundles for these Discogs ids up to this generation: each
    /// reference once a generation, each bundle once ever (by digest), checked
    /// before it is kept.
    static func refresh(
        _ cache: inout BundleCache, discogsIDs: [Int], now: Date, read: Read = live
    ) async -> Report {
        var report = Report()
        let generation = BackendKnowledgeCache.generation(at: now)
        for id in Array(Set(discogsIDs)).sorted() {
            let key = String(id)
            if cache.refs[key]?.generation != generation {
                do {
                    let (status, data) = try await read("knowledge/v1/refs/artists/\(id).json")
                    report.reads += 1
                    report.bytes += data?.count ?? 0
                    if status == 404 || status == 403 {
                        cache.refs[key] = .init(ref: nil, generation: generation, fetchedAt: now)
                    } else if status == 200, let data {
                        let ref = try JSONDecoder().decode(ArtistBundleRef.self, from: data)
                        cache.refs[key] = .init(ref: ref, generation: generation, fetchedAt: now)
                    } else {
                        report.errors.append("ref \(id): HTTP \(status)")
                    }
                } catch {
                    report.errors.append("ref \(id): \(error.localizedDescription)")
                }
            }
            guard let ref = cache.refs[key]?.ref, cache.bundles[ref.digest] == nil else { continue }
            do {
                let (status, data) = try await read(ref.key)
                report.reads += 1
                report.bytes += data?.count ?? 0
                guard status == 200, let data else { report.errors.append("bundle \(id): HTTP \(status)"); continue }
                guard digest(data) == ref.digest else { report.errors.append("bundle \(id): digest mismatch"); continue }
                cache.bundles[ref.digest] = try JSONDecoder().decode(ArtistBundle.self, from: data)
            } catch {
                report.errors.append("bundle \(id): \(error.localizedDescription)")
            }
        }
        return report
    }
}

// MARK: - Edges from a bundle

nonisolated enum BundleEdges {
    /// The edges a bundle adds out of its artist, each kind of relationship
    /// kept apart: collaborations (records made together, or a record of
    /// somebody else's this artist appeared on, remixed or played on),
    /// credits (a job somebody did on this artist's own records), and the
    /// labels that released them.
    ///
    /// `ownIdentities` are every Discogs id the backend knows for the
    /// artist. Discogs often files one person under two names -- Anika's
    /// records credit "Annika Henderson" as their producer -- and offering
    /// somebody their own real name is a spelling, not a discovery. A label
    /// the backend's SQL already reaches is not added again, so one fact is
    /// not counted as two.
    static func edges(
        from origin: MusicNode, bundle: ArtistBundle, ownIdentities: Set<Int>, sqlTargets: Set<String>
    ) -> [MusicEdge] {
        let records = Dictionary(bundle.releases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let own = ownIdentities.union([bundle.artist.discogsID])
        /// The record a relationship is told by: the latest of them, then the
        /// lowest id, so the sentence is the same wherever it is worked out.
        func headline(_ ids: [Int]) -> ArtistBundle.Release? {
            ids.compactMap { records[$0] }.min {
                ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.id < $1.id
            }
        }
        func person(_ ref: ArtistBundle.Person) -> MusicNode? {
            if let id = ref.discogsID, own.contains(id) { return nil }
            let name = DiscogsClient.withoutDisambiguator(ref.name)
            guard ArtistName.isRealArtist(name) else { return nil }
            let node = MusicNode.artist(name, discogsID: ref.discogsID)
            return node.id == origin.id ? nil : node
        }
        var out: [MusicEdge] = []

        for collaborator in bundle.collaborators {
            guard let target = person(collaborator.artist), let record = headline(collaborator.releases) else { continue }
            // Discogs' shelf says *that* the artist is on somebody's record;
            // only a job says they made it with them. A track in a DJ's mix,
            // or a song of theirs on someone's compilation, is a record both
            // are on -- worth less than a collaboration, and said as such.
            let jobs = collaborator.how.filter { how in
                how != "joint" && !Self.appearances.contains(how) && CreditRole.kind(of: how).map { $0 != .writing } == true
            }
            if collaborator.how.contains("joint") || !jobs.isEmpty {
                out.append(MusicEdge(
                    from: origin, to: target, kind: .collaborator, source: .discogs,
                    reason: collaborator.how.contains("joint") || jobs.isEmpty
                        ? "Made \(record.title) together"
                        : "\(jobs.prefix(2).joined(separator: ", ")) on \(record.title)",
                    confidence: RelationshipKind.collaborator.baseConfidence,
                    occurrences: collaborator.releases.count
                ))
            } else {
                out.append(MusicEdge(
                    from: origin, to: target, kind: .sameRelease, source: .discogs,
                    reason: "Appears on \(record.title)",
                    confidence: RelationshipKind.sameRelease.baseConfidence,
                    occurrences: collaborator.releases.count
                ))
            }
        }

        for credit in bundle.credits {
            guard let target = person(credit.artist) else { continue }
            for role in credit.roles {
                guard let kind = role.kind, let record = headline(role.releases.map(\.id)) else { continue }
                let tracks = role.releases.first { $0.id == record.id }?.tracks ?? []
                let relationship: RelationshipKind = kind == "production" ? .producer : .personnel
                out.append(MusicEdge(
                    from: origin, to: target, kind: relationship, source: .discogs,
                    // The job as the record stated it, as the device's own
                    // credits are written (`GraphStore.addCredits`).
                    reason: tracks.isEmpty
                        ? "\(role.role) on \(record.title)"
                        : "\(role.role) on \(record.title) (\(tracks.joined(separator: ", ")))",
                    confidence: relationship.baseConfidence, occurrences: role.releases.count
                ))
            }
        }

        for label in bundle.labels where !label.placeholder && !label.ownName {
            guard LabelName.isRealLabel(label.display), !LabelName.isOwnName(label.display, artist: origin.title)
            else { continue }
            let target = MusicNode.label(label.display, discogsID: label.discogsID)
            guard !sqlTargets.contains(target.id) else { continue }
            out.append(MusicEdge(
                from: origin, to: target, kind: .sharedLabel, source: .discogs,
                reason: "Releases on \(label.display)",
                confidence: RelationshipKind.sharedLabel.baseConfidence, occurrences: label.releases
            ))
        }
        return out
    }

    /// Discogs' words for being on a record, as against doing something on it.
    static let appearances: Set<String> = ["Appearance", "TrackAppearance", "UnofficialRelease"]

    /// Styles and genres as an artist's tags, folded the way the taste
    /// profile reads them. Metadata only: nothing here makes a peer.
    static func tags(_ bundle: ArtistBundle) -> [String] {
        ListeningLog.foldTags(bundle.styles.map(\.name) + bundle.genres.map(\.name))
    }

    /// How an artist's bundle stands. Complete means every release the
    /// discovered Discogs entries name was read -- relative to what Discogs
    /// lists, not to everything the artist made.
    static func status(
        node: String, discogsID: Int, kept: BundleCache.KeptRef?, cache: BundleCache, generation: String
    ) -> BundleStatus {
        guard let kept else { return BundleStatus(node: node, discogsID: discogsID, status: "failed", detail: "never fetched") }
        let stale = kept.generation == generation ? "" : ", stale"
        guard let ref = kept.ref else { return BundleStatus(node: node, discogsID: discogsID, status: "missing" + stale, detail: "no bundle published") }
        guard let bundle = cache.bundles[ref.digest] else {
            return BundleStatus(node: node, discogsID: discogsID, status: "failed" + stale, detail: "ref \(ref.digest.prefix(8)) unread")
        }
        let source = bundle.source ?? ref.source
        var gaps: [String] = []
        if let source {
            if !source.complete { gaps.append("discovery \(source.pagesFetched)/\(source.pagesReported.map(String.init) ?? "?") pages") }
            if source.truncated { gaps.append("discography truncated") }
            if source.documentsMissing > 0 { gaps.append("\(source.documentsMissing) documents missing") }
            if source.documentsTruncated > 0 { gaps.append("\(source.documentsTruncated) over budget") }
        } else {
            gaps.append("no source")
        }
        let read = source.map { "\($0.documentsRead)/\($0.representativeReleases) read of \($0.entries) entries" } ?? ""
        let detail = [read, "\(bundle.collaborators.count) collaborators, \(bundle.credits.count) credited, \(bundle.labels.count) labels",
                      "built \(ref.builtAt.prefix(10))", gaps.joined(separator: "; ")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return BundleStatus(node: node, discogsID: discogsID, status: (gaps.isEmpty ? "complete" : "partial") + stale, detail: detail)
    }
}

// MARK: - How deeply a recommendation is supported

/// How many starting points reach a recommendation, and how many of them by
/// a strong route -- a label, a credit, a collaboration, the radio, a record --
/// rather than a resemblance (style, era, scene). Broad styles reach
/// everything; they are not independent evidence.
nonisolated struct CorroborationDepth: Codable, Sendable, Equatable {
    let id: String
    let startingPoints: Int
    let strong: Int
    let kinds: [String]

    static let weak: Set<RelationshipKind> = [.sharedStyle, .sameEra, .sameScene, .sameCity]

    static func of(_ ids: [String], personal: PersonalInputs, knowledge: KnowledgeSnapshot) -> [CorroborationDepth] {
        let wanted = Set(ids)
        let sets = ExploreRanker.edgeSets(knowledge)
        var reaching: [String: Set<String>] = [:]
        var strong: [String: Set<String>] = [:]
        var kinds: [String: Set<String>] = [:]
        for origin in ExploreRanker.startingPoints(personal) {
            for connection in (sets[origin] ?? EdgeSet()).byDestination where wanted.contains(connection.node.id) {
                let id = connection.node.id
                let worth = connection.edges.filter { $0.weight * ExploreSuggestionEngine.worth($0) > 0 }
                guard !worth.isEmpty else { continue }
                reaching[id, default: []].insert(origin.id)
                if worth.contains(where: { !weak.contains($0.kind) }) { strong[id, default: []].insert(origin.id) }
                kinds[id, default: []].formUnion(worth.map(\.kind.rawValue))
            }
        }
        return ids.map {
            CorroborationDepth(id: $0, startingPoints: reaching[$0]?.count ?? 0, strong: strong[$0]?.count ?? 0,
                               kinds: (kinds[$0] ?? []).sorted())
        }
    }

    /// A top twenty's depth in one line: how many rest on two or more
    /// starting points, and how many of those on two or more strong ones.
    struct Summary: Codable, Sendable, Equatable {
        var count = 0
        var corroborated = 0
        var stronglyCorroborated = 0
        var singleStrong = 0
        var weakOnly = 0
        var meanStartingPoints = 0.0
        var meanStrong = 0.0

        init() {}
        init(_ depths: [CorroborationDepth]) {
            count = depths.count
            corroborated = depths.filter { $0.startingPoints >= 2 }.count
            stronglyCorroborated = depths.filter { $0.strong >= 2 }.count
            singleStrong = depths.filter { $0.strong == 1 }.count
            weakOnly = depths.filter { $0.strong == 0 && $0.startingPoints > 0 }.count
            guard !depths.isEmpty else { return }
            meanStartingPoints = Double(depths.map(\.startingPoints).reduce(0, +)) / Double(depths.count)
            meanStrong = Double(depths.map(\.strong).reduce(0, +)) / Double(depths.count)
        }

        var line: String {
            String(format: "%d: ≥2 points %d, ≥2 strong %d, 1 strong %d, weak only %d, mean %.1f/%.1f strong",
                   count, corroborated, stronglyCorroborated, singleStrong, weakOnly, meanStartingPoints, meanStrong)
        }
    }
}
