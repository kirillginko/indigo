//
//  PinnedGeneration.swift
//  Indigo
//
//  The backend's knowledge as one immutable generation (SHARED-KNOWLEDGE.md
//  §9, §14), read the way a device should read it, in shadow.
//
//  The publisher writes, once a day, a manifest naming every answer by digest,
//  a write-once day pointer naming the manifest, and a list of the retained
//  days (`current.json`). This reads them back: the list, the day it selects,
//  the manifest, and every object the manifest names -- each checked against
//  its digest over the exact bytes that arrived, before anything is decoded.
//  Only then is the generation kept, and only a generation kept whole is ever
//  used. Knowledge is built from it alone: a starting point it does not hold
//  is `deferred`, never asked of the live SQL, so two devices holding the same
//  generation hold the same knowledge, whatever the database has done since.
//
//  Which generation: the newest one listed, not withdrawn, dated *before* the
//  evaluation day. A day's generation is published forty minutes into that
//  day, so the one before it has been there all day and every device picks
//  the same one whenever it looks. A withdrawn generation is never served, and
//  the report says it was withdrawn. Offline, or when a download fails: the
//  newest generation kept whole on this device that still qualifies, and the
//  report says so.
//
//  Kept on disk, content-addressed: `objects/<aa>/<digest>` (raw bytes, each
//  written only after its digest was checked), and `generations/<manifest>.json`,
//  a marker written last, after every object the manifest names was present
//  and checked. An interrupted download leaves objects without a marker -- not
//  a generation -- and never touches one already kept.
//

import CryptoKit
import Foundation

// MARK: - The published format

nonisolated enum GenerationKeys {
    static let root = "knowledge/v1/generations"
    static let current = "\(root)/current.json"
    static func day(_ date: String) -> String { "\(root)/days/\(date).json" }
    static func manifest(_ digest: String) -> String { "\(root)/manifests/\(digest.prefix(2))/\(digest).json" }
    static func answer(_ digest: String) -> String { "\(root)/objects/\(digest.prefix(2))/\(digest).json" }
    static func identity(_ digest: String) -> String { "\(root)/identity/\(digest.prefix(2))/\(digest).json" }
    static func bundle(_ digest: String) -> String { "knowledge/v1/bundles/\(digest.prefix(2))/\(digest).json" }

    /// SHA-256 of the bytes as they are, lowercase hex.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The UTC date of a day number (`ExplorePeriod`), as the publisher names days.
    static func date(ofPeriod period: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(period) * ExplorePeriod.length))
    }
}

/// `current.json`: the retained generations, newest first, and withdrawals.
nonisolated struct GenerationList: Codable, Sendable, Equatable {
    struct Listed: Codable, Sendable, Equatable {
        let date: String
        let manifest: String
    }
    struct Withdrawn: Codable, Sendable, Equatable {
        let date: String
        var manifest: String? = nil
        var reason: String? = nil
    }
    var generations: [Listed] = []
    var withdrawn: [Withdrawn] = []

    init(generations: [Listed] = [], withdrawn: [Withdrawn] = []) {
        self.generations = generations
        self.withdrawn = withdrawn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generations = try c.decodeIfPresent([Listed].self, forKey: .generations) ?? []
        withdrawn = try c.decodeIfPresent([Withdrawn].self, forKey: .withdrawn) ?? []
    }

    /// Withdrawn by date, or by manifest when the withdrawal names one.
    func isWithdrawn(date: String, manifest: String) -> Bool {
        withdrawn.contains { $0.date == date && ($0.manifest == nil || $0.manifest == manifest) }
    }

    /// The generation an evaluation day ranks from: the newest listed, not
    /// withdrawn, dated before the day.
    func selection(for day: String) -> Listed? {
        generations
            .filter { $0.date < day && !isWithdrawn(date: $0.date, manifest: $0.manifest) }
            .max { $0.date < $1.date }
    }
}

/// `days/<date>.json`.
nonisolated struct GenerationDay: Codable, Sendable, Equatable {
    let date: String
    let manifest: String
    var publishedAt: String? = nil
}

/// The manifest (`indigo.knowledge-generation/1`): what the generation holds
/// and how complete it is, entity by entity.
nonisolated struct GenerationManifest: Codable, Sendable, Equatable {
    struct Bundle: Codable, Sendable, Equatable {
        let discogsID: Int
        /// `complete`, `partial` or `missing`.
        let status: String
        var digest: String? = nil
        var read: Int? = nil
        var of: Int? = nil
    }
    struct Entry: Codable, Sendable, Equatable {
        /// `found`, `unknown` or `unsupported`.
        let status: String
        var answer: String? = nil
        var ambiguousName: Bool? = nil
        var bundles: [Bundle]? = nil
    }
    struct Run: Codable, Sendable, Equatable {
        let runid: Int
        let endedAt: String
    }
    struct Source: Codable, Sendable, Equatable {
        let cutAt: String
        let snapshot: String
        var edges: Run? = nil
    }
    struct Publication: Codable, Sendable, Equatable {
        let complete: Bool
    }

    let format: String
    let id: String
    let date: String
    let identity: String
    let source: Source
    let nodes: [String: Entry]
    let artists: [String: Entry]
    var publication: Publication? = nil

    /// Every object the manifest names, with the digest it must have, once.
    var referenced: [(key: String, digest: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        func add(_ key: String, _ digest: String) {
            if seen.insert(digest).inserted { out.append((key, digest)) }
        }
        for (_, entry) in nodes.sorted(by: { $0.key < $1.key }) {
            if let answer = entry.answer { add(GenerationKeys.answer(answer), answer) }
            for bundle in entry.bundles ?? [] { if let d = bundle.digest { add(GenerationKeys.bundle(d), d) } }
        }
        for (_, entry) in artists.sorted(by: { $0.key < $1.key }) {
            if let answer = entry.answer { add(GenerationKeys.answer(answer), answer) }
        }
        add(GenerationKeys.identity(identity), identity)
        return out
    }
}

/// One entity's answer as the publisher stores it.
nonisolated struct GenerationAnswer<Answer: Decodable & Sendable>: Decodable, Sendable {
    let format: String
    let kind: String
    let id: String
    let answer: Answer
}

/// A generation held whole: the manifest, and every object it names, as
/// verified bytes.
nonisolated struct PinnedGeneration: Sendable {
    let date: String
    let manifestDigest: String
    let manifest: GenerationManifest
    let objects: [String: Data]

    var bytes: Int { objects.values.map(\.count).reduce(0, +) }

    func nodeAnswer(_ id: String) -> BackendNodeAnswer? {
        guard let digest = manifest.nodes[id]?.answer, let data = objects[digest] else { return nil }
        return try? JSONDecoder().decode(GenerationAnswer<BackendNodeAnswer>.self, from: data).answer
    }

    func artistAnswer(_ key: String) -> BackendArtistAnswer? {
        guard let digest = manifest.artists[key]?.answer, let data = objects[digest] else { return nil }
        return try? JSONDecoder().decode(GenerationAnswer<BackendArtistAnswer>.self, from: data).answer
    }

    func bundle(_ digest: String) -> ArtistBundle? {
        objects[digest].flatMap { try? JSONDecoder().decode(ArtistBundle.self, from: $0) }
    }
}

// MARK: - Kept on this device

nonisolated struct PinnedGenerationStore: Sendable {
    let root: URL

    /// Generations kept whole, besides the one in use.
    static let retained = 3

    static var standard: PinnedGenerationStore? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            .map { PinnedGenerationStore(root: $0.appendingPathComponent("knowledge-generations", isDirectory: true)) }
    }

    /// A generation kept whole: what it named, so it can be checked again.
    struct Marker: Codable, Sendable, Equatable {
        let date: String
        let manifest: String
        let objects: [String]
        let bytes: Int
        let keptAt: Date
    }

    /// The last list read, for withdrawals while offline.
    struct State: Codable, Sendable, Equatable {
        var list: GenerationList
        var readAt: Date
    }

    private var objectsDirectory: URL { root.appendingPathComponent("objects", isDirectory: true) }
    private var markersDirectory: URL { root.appendingPathComponent("generations", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }

    func objectURL(_ digest: String) -> URL {
        objectsDirectory.appendingPathComponent(String(digest.prefix(2)), isDirectory: true).appendingPathComponent(digest)
    }

    func markerURL(_ manifest: String) -> URL { markersDirectory.appendingPathComponent("\(manifest).json") }

    /// Keeps bytes under their digest -- only if they are what the digest says.
    func put(_ data: Data, digest: String) throws {
        guard GenerationKeys.digest(data) == digest else { throw PinnedGenerationError.digestMismatch(digest) }
        let url = objectURL(digest)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The bytes kept under a digest, checked; nil when absent or wrong (a
    /// wrong copy is removed, so it is fetched again).
    func object(_ digest: String) -> Data? {
        let url = objectURL(digest)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard GenerationKeys.digest(data) == digest else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return data
    }

    func markers() -> [Marker] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: markersDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.date, $0.manifest) > ($1.date, $1.manifest) }
    }

    /// Written last, after every object was checked.
    func mark(_ marker: Marker) throws {
        try FileManager.default.createDirectory(at: markersDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(marker).write(to: markerURL(marker.manifest), options: .atomic)
    }

    /// A kept generation, every byte checked again; nil (and the marker
    /// dropped) when anything it names is missing or wrong.
    func load(_ manifestDigest: String) -> PinnedGeneration? {
        guard let data = try? Data(contentsOf: markerURL(manifestDigest)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return nil }
        func drop() -> PinnedGeneration? {
            try? FileManager.default.removeItem(at: markerURL(manifestDigest))
            return nil
        }
        guard let manifestBytes = object(manifestDigest),
              let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: manifestBytes),
              manifest.date == marker.date else { return drop() }
        var objects: [String: Data] = [:]
        for (_, digest) in manifest.referenced {
            guard let bytes = object(digest) else { return drop() }
            objects[digest] = bytes
        }
        return PinnedGeneration(date: marker.date, manifestDigest: manifestDigest, manifest: manifest, objects: objects)
    }

    func state() -> State? {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    func save(_ state: State) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// Bytes on disk, everything included.
    func size() -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Keeps the newest `retained` generations and the one in use; removes
    /// other markers, then objects no kept marker names that have not been
    /// touched for an hour (one being downloaded meanwhile is younger).
    func prune(keeping inUse: String, now: Date) {
        let markers = markers()
        let kept = Set(markers.prefix(Self.retained).map(\.manifest) + [inUse])
        for marker in markers where !kept.contains(marker.manifest) {
            try? FileManager.default.removeItem(at: markerURL(marker.manifest))
        }
        let named = Set(markers.filter { kept.contains($0.manifest) }.flatMap { $0.objects + [$0.manifest] })
        guard let walker = FileManager.default.enumerator(
            at: objectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, !named.contains(url.lastPathComponent),
                  let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > 3_600 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

nonisolated enum PinnedGenerationError: Error, Equatable, CustomStringConvertible {
    case digestMismatch(String)
    case missing(String)
    case http(String, Int)
    case inconsistent(String)
    case undecodable(String)

    var description: String {
        switch self {
        case .digestMismatch(let d): "digest mismatch \(d.prefix(12))"
        case .missing(let key): "missing \(key)"
        case .http(let key, let status): "HTTP \(status) \(key)"
        case .inconsistent(let what): "inconsistent \(what)"
        case .undecodable(let what): "undecodable \(what)"
        }
    }
}

// MARK: - Reading

nonisolated enum PinnedGenerationClient {
    /// Reads one object by key: the status, and the body when 200. Throws
    /// when the bucket cannot be reached at all.
    typealias Read = @Sendable (String) async throws -> (status: Int, data: Data?)

    @Sendable static func live(_ key: String) async throws -> (status: Int, data: Data?) {
        try await reader(.shared)(key)
    }

    /// The public bucket through one session. `live` is the shared one; a
    /// measurement of a clean device uses an ephemeral one, so nothing the
    /// HTTP cache kept from another client is counted as fetched.
    static func reader(_ session: URLSession) -> Read {
        { key in
            guard let host = SupabaseConfiguration.catalogCacheHost, !host.contains("/"),
                  let url = URL(string: "https://\(host)/\(key)") else { throw URLError(.badURL) }
            // The list moves; everything else is addressed or written once.
            let policy: URLRequest.CachePolicy = key == GenerationKeys.current
                ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            let (data, response) = try await session.data(
                for: URLRequest(url: url, cachePolicy: policy, timeoutInterval: 15))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, status == 200 ? data : nil)
        }
    }

    static let concurrency = 8

    struct Report: Codable, Sendable, Equatable {
        /// `downloaded`, `cache` (kept whole, list read), `offline-cache` (list
        /// unreachable), `fallback` (the selected one could not be had), or
        /// `none`.
        var source = "none"
        var evaluationDay = ""
        /// What the list selected, and what is in use.
        var selected: String?
        var date: String?
        var manifest: String?
        var listRead = false
        var objectsDownloaded = 0
        var bytesDownloaded = 0
        var objectsReused = 0
        var milliseconds = 0.0
        var errors: [String] = []
        /// Kept generations the list withdraws, "date manifest12", never served.
        var revoked: [String] = []
        var cacheBytes = 0
        var keptGenerations = 0
    }

    /// The generation for an evaluation day, and how it was had.
    static func resolve(
        period: Int, store: PinnedGenerationStore, read: @escaping Read = live, now: Date = Date()
    ) async -> (PinnedGeneration?, Report) {
        let started = ContinuousClock.now
        var report = Report()
        let day = GenerationKeys.date(ofPeriod: period)
        report.evaluationDay = day

        // The list, or the one read last.
        var list: GenerationList?
        do {
            let (status, data) = try await read(GenerationKeys.current)
            if status == 200, let data {
                report.bytesDownloaded += data.count
                let decoded = try JSONDecoder().decode(GenerationList.self, from: data)
                list = decoded
                report.listRead = true
                store.save(.init(list: decoded, readAt: now))
            } else if status == 404 {
                list = GenerationList()
                report.listRead = true
            } else {
                report.errors.append(PinnedGenerationError.http(GenerationKeys.current, status).description)
            }
        } catch {
            report.errors.append("list unreachable: \(error.localizedDescription)")
        }
        let known = list ?? store.state()?.list ?? GenerationList()

        let markers = store.markers()
        report.revoked = markers.filter { known.isWithdrawn(date: $0.date, manifest: $0.manifest) }
            .map { "\($0.date) \($0.manifest.prefix(12))" }

        /// The newest generation kept whole that may still be served.
        func kept(except: String? = nil) -> PinnedGeneration? {
            for marker in markers where marker.date < day && marker.manifest != except
                && !known.isWithdrawn(date: marker.date, manifest: marker.manifest) {
                if let generation = store.load(marker.manifest) { return generation }
            }
            return nil
        }
        func finish(_ generation: PinnedGeneration?, _ source: String) -> (PinnedGeneration?, Report) {
            report.source = generation == nil ? "none" : source
            report.date = generation?.date
            report.manifest = generation?.manifestDigest
            if let generation { store.prune(keeping: generation.manifestDigest, now: now) }
            report.cacheBytes = store.size()
            report.keptGenerations = store.markers().count
            let spent = ContinuousClock.now - started
            report.milliseconds = Double(spent.components.seconds) * 1_000 + Double(spent.components.attoseconds) / 1e15
            return (generation, report)
        }

        guard list != nil else { return finish(kept(), "offline-cache") }
        guard let selected = known.selection(for: day) else { return finish(nil, "none") }
        report.selected = "\(selected.date) \(selected.manifest.prefix(12))"
        if let generation = store.load(selected.manifest) { return finish(generation, "cache") }
        do {
            let generation = try await download(selected, store: store, read: read, now: now, report: &report)
            return finish(generation, "downloaded")
        } catch {
            report.errors.append(String(describing: error))
            return finish(kept(except: selected.manifest), "fallback")
        }
    }

    /// One object's bytes, or why there are none.
    @Sendable private static func fetch(_ key: String, _ read: Read) async throws -> Data {
        let (status, data) = try await read(key)
        if status == 404 { throw PinnedGenerationError.missing(key) }
        guard status == 200, let data else { throw PinnedGenerationError.http(key, status) }
        return data
    }

    /// The day pointer, the manifest and every object it names, each checked
    /// over its exact bytes before it is kept; the marker last.
    private static func download(
        _ selected: GenerationList.Listed, store: PinnedGenerationStore, read: @escaping Read, now: Date, report: inout Report
    ) async throws -> PinnedGeneration {
        let dayBytes = try await fetch(GenerationKeys.day(selected.date), read)
        report.bytesDownloaded += dayBytes.count
        guard let pointer = try? JSONDecoder().decode(GenerationDay.self, from: dayBytes) else {
            throw PinnedGenerationError.undecodable("day \(selected.date)")
        }
        guard pointer.date == selected.date, pointer.manifest == selected.manifest else {
            throw PinnedGenerationError.inconsistent("day \(selected.date) names \(pointer.manifest.prefix(12))")
        }

        let manifestBytes: Data
        if let held = store.object(selected.manifest) {
            manifestBytes = held
            report.objectsReused += 1
        } else {
            manifestBytes = try await fetch(GenerationKeys.manifest(selected.manifest), read)
            report.bytesDownloaded += manifestBytes.count
            report.objectsDownloaded += 1
            try store.put(manifestBytes, digest: selected.manifest)
        }
        guard let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: manifestBytes) else {
            throw PinnedGenerationError.undecodable("manifest \(selected.manifest.prefix(12))")
        }
        guard manifest.date == selected.date, manifest.publication?.complete == true else {
            throw PinnedGenerationError.inconsistent("manifest \(selected.manifest.prefix(12))")
        }

        let wanted = manifest.referenced
        var objects: [String: Data] = [:]
        var missing: [(key: String, digest: String)] = []
        for item in wanted {
            if let held = store.object(item.digest) { objects[item.digest] = held } else { missing.append(item) }
        }
        report.objectsReused += objects.count
        for start in stride(from: 0, to: missing.count, by: concurrency) {
            let batch = Array(missing[start..<min(start + concurrency, missing.count)])
            let arrived = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for item in batch {
                    group.addTask {
                        let data = try await fetch(item.key, read)
                        guard GenerationKeys.digest(data) == item.digest else { throw PinnedGenerationError.digestMismatch(item.digest) }
                        return (item.digest, data)
                    }
                }
                var out: [(String, Data)] = []
                for try await pair in group { out.append(pair) }
                return out
            }
            for (digest, data) in arrived {
                try store.put(data, digest: digest)
                objects[digest] = data
                report.objectsDownloaded += 1
                report.bytesDownloaded += data.count
            }
        }

        try store.mark(.init(
            date: manifest.date, manifest: selected.manifest, objects: wanted.map(\.digest),
            bytes: objects.values.map(\.count).reduce(manifestBytes.count, +), keptAt: now))
        guard let generation = store.load(selected.manifest) else {
            throw PinnedGenerationError.inconsistent("kept generation \(selected.manifest.prefix(12)) did not read back")
        }
        return generation
    }
}

// MARK: - Knowledge from it

/// What the pinned generation could say about this listener's rows.
nonisolated struct PinnedCoverage: Codable, Sendable, Equatable {
    /// Starting point id to `found`, `unknown`, `unsupported` or `deferred`
    /// (not in this generation's demand: no neighbourhood, never filled in).
    var startingPoints: [String: String] = [:]
    var artists: [String: Int] = [:]
    /// Bundles of the starting artists: `complete`, `partial`, `missing`,
    /// `noIdentity`.
    var bundles: [String: Int] = [:]
    var ambiguous: [String] = []

    /// For the FY code: starting points found/unknown/unsupported/deferred,
    /// artists found/unknown/deferred, bundles complete/partial/missing/no id.
    var code: String {
        var points: [String: Int] = [:]
        for status in startingPoints.values { points[status, default: 0] += 1 }
        func n(_ d: [String: Int], _ k: String) -> Int { d[k] ?? 0 }
        return "s\(n(points, "found"))-\(n(points, "unknown"))-\(n(points, "unsupported"))-\(n(points, "deferred"))"
            + "a\(n(artists, "found"))-\(n(artists, "unknown"))-\(n(artists, "deferred"))"
            + "b\(n(bundles, "complete"))-\(n(bundles, "partial"))-\(n(bundles, "missing"))-\(n(bundles, "noIdentity"))"
    }
}

nonisolated enum PinnedKnowledgeAdapter {
    /// The snapshot from the pinned generation alone, through the same
    /// adapter the live shadow uses -- given only what the generation holds,
    /// as current, so nothing is called stale and nothing is asked for.
    static func snapshot(
        personal: PersonalInputs, deviceLocal: DeviceLocalKnowledge, generation: PinnedGeneration,
        now: Date, use: BackendKnowledgeAdapter.BundleUse = .relationships
    ) -> (KnowledgeSnapshot, PinnedCoverage, [BundleStatus]) {
        let label = BackendKnowledgeCache.generation(at: now)
        let at = ISO8601DateFormatter().date(from: String(generation.manifest.source.cutAt.prefix(19)) + "Z") ?? .distantPast
        let manifest = generation.manifest

        var cache = BackendKnowledgeCache()
        for (id, entry) in manifest.nodes {
            let answer = entry.answer == nil
                ? BackendNodeAnswer(status: entry.status, edges: [], identities: [])
                : generation.nodeAnswer(id)
            if let answer { cache.nodes[id] = .init(answer: answer, generation: label, fetchedAt: at) }
        }
        for (key, entry) in manifest.artists {
            let answer = entry.answer == nil
                ? BackendArtistAnswer(status: entry.status, episodes: [], rosters: [], genres: [])
                : generation.artistAnswer(key)
            if let answer { cache.artists[key] = .init(answer: answer, generation: label, fetchedAt: at) }
        }
        var bundles = BundleCache()
        for entry in manifest.nodes.values {
            for pinned in entry.bundles ?? [] {
                let ref = pinned.digest.map {
                    ArtistBundleRef(artist: pinned.discogsID, digest: $0, key: GenerationKeys.bundle($0),
                                    builtAt: manifest.date, bytes: generation.objects[$0]?.count ?? 0, source: nil)
                }
                bundles.refs[String(pinned.discogsID)] = .init(ref: ref, generation: label, fetchedAt: at)
                if let digest = pinned.digest, let bundle = generation.bundle(digest) { bundles.bundles[digest] = bundle }
            }
        }
        let (snapshot, _, statuses) = BackendKnowledgeAdapter.snapshot(
            personal: personal, deviceLocal: deviceLocal, cache: cache, now: now, bundles: bundles, use: use)
        return (snapshot, coverage(personal: personal, deviceLocal: deviceLocal, manifest: manifest), statuses)
    }

    /// Coverage as the manifest records it, for this listener's wants.
    static func coverage(personal: PersonalInputs, deviceLocal: DeviceLocalKnowledge, manifest: GenerationManifest) -> PinnedCoverage {
        var coverage = PinnedCoverage()
        for origin in ExploreRanker.startingPoints(personal) {
            let entry = manifest.nodes[origin.id]
            coverage.startingPoints[origin.id] = entry?.status ?? "deferred"
            if entry?.ambiguousName == true { coverage.ambiguous.append(origin.id) }
            guard origin.kind == .artist, let entry, entry.status == "found" else { continue }
            let pinned = entry.bundles ?? []
            if pinned.isEmpty { coverage.bundles["noIdentity", default: 0] += 1 }
            for bundle in pinned { coverage.bundles[bundle.status, default: 0] += 1 }
        }
        for key in BackendKnowledgeAdapter.artistsWanted(personal, deviceLocal: deviceLocal) {
            coverage.artists[manifest.artists[key]?.status ?? "deferred", default: 0] += 1
        }
        coverage.ambiguous.sort()
        return coverage
    }
}

/// The pinned generation's For You beside the visible one, for the
/// diagnostics.
nonisolated struct PinnedShadow: Codable, Sendable, Equatable {
    var fetch = PinnedGenerationClient.Report()
    var coverage = PinnedCoverage()
    var stage = ShadowStage()
    var bundles: [BundleStatus] = []
    /// Digests of the shared knowledge and of the ranked ids (every
    /// recommendation, in order), for comparing two devices.
    var shared = ""
    var ranked = ""

    /// The FY code's pinned part: the manifest, and the coverage counts.
    var codePart: String {
        guard let manifest = fetch.manifest else { return "g-.\(fetch.source)" }
        return "g\(manifest.prefix(12)).\(coverage.code)"
    }
}
