//
//  CataloguePilot.swift
//  Indigo
//
//  The DIG catalogue pilot (DIG-REMEDIATION-PLAN.md §7 step 3): for the 300
//  approved dead-end artists, a bundle the worker built from the documents the
//  catalogue already holds -- who they made records with, who is credited on
//  them, which labels released them, every one by Discogs id. Read here so an
//  artist page DIG otherwise has nothing to offer for can lead somewhere.
//
//  Behind the remote switch (`DigEnrichmentSwitch`, 0084): off unless it is
//  on for this device's cohort, and then only the manifest it pins. A
//  development build can force it on (`-INDIGO_DIG_CATALOGUE_PILOT YES`).
//  Off, DIG is exactly as it was.
//
//  What is read: a small pointer (asked once a launch, never from a cache),
//  the manifest it names, and for a page being opened the one bundle that
//  page's entry has -- each addressed object checked against its digest
//  before anything is read from it, and kept on disk by digest, because an
//  addressed object never changes. An artist the manifest does not list, or a
//  bundle that fails its check, is no edges at all, never a guess.
//

import Foundation

nonisolated final class CataloguePilot: @unchecked Sendable {
    static let shared = CataloguePilot()

    static let switchKey = "INDIGO_DIG_CATALOGUE_PILOT"
    static let pointerKey = "knowledge/v1/catalogue/pilot.json"

    /// Discogs entries that stand for nobody in particular: Various, Unknown
    /// Artist, Traditional, Anonymous. A credit to one is not a route.
    static let standIns: Set<Int> = [194, 118760, 151641, 967691]

    /// What a route from a bundle is worth beside the same kind of route the
    /// device found itself: a little less, so where the page has room for only
    /// so many, what this device read for itself is never pushed out by what
    /// the catalogue says. One both found combines, and outranks either.
    static let confidenceShare = 0.95

    /// Whether the pilot is on. Never in a release build.
    /// Whether DIG reads the pilot: what the remote switch decides for this
    /// device (`DigEnrichmentSwitch`), asked at every read -- network, disk or
    /// memory alike. A development build can still force it on with the
    /// launch argument; nothing can in a release build.
    var isEnabled: Bool {
        if let enabledOverride { return enabledOverride }
        if isForcedLocally { return true }
        return remote.isOn
    }

    private var isForcedLocally: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: Self.switchKey)
        #else
        false
        #endif
    }

    /// The manifest the switch allows, when the switch is what decides: the
    /// approved pilot, and nothing a later publication adds.
    var requiredManifest: String? {
        enabledOverride != nil || isForcedLocally ? nil : remote.pinnedManifest
    }

    var remote: DigEnrichmentSwitch = .shared

    /// For tests: on or off whatever the defaults say.
    var enabledOverride: Bool?

    struct Entry: Codable, Sendable, Equatable {
        let digest: String
        let key: String
        let bytes: Int
    }

    private struct Pointer: Decodable {
        let manifest: String
        let digest: String
    }

    private struct Manifest: Decodable {
        let artists: [String: Entry]
        let missing: [Int]
    }

    /// How a page's bundle stood when it was asked for, for the trace.
    enum Outcome: Equatable, Sendable {
        case off
        case notInPilot
        /// Read from the network this launch: the page must walk again.
        case fetched
        /// Already in memory, or on disk from an earlier launch.
        case held
        case failed(String)
    }

    /// Reads one object by key. Replaced in tests.
    var read: @Sendable (_ key: String, _ fresh: Bool) async throws -> (status: Int, data: Data?) = CataloguePilot.live

    var directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("catalogue-pilot", isDirectory: true)

    private let lock = NSLock()
    private var manifest: [Int: Entry]?
    private var manifestDigest: String?
    private var bundles: [Int: ArtistBundle] = [:]

    /// Whether the catalogue has a bundle for an entry, from the manifest
    /// already read. Never a network read: before the manifest, no.
    func hasBundle(_ discogsID: Int) -> Bool {
        guard isEnabled else { return false }
        return lock.withLock { manifest?[discogsID] != nil }
    }

    /// The people an entry's bundle names, by Discogs id: who it leads to.
    func people(in discogsID: Int) -> Set<Int> {
        guard let bundle = bundle(for: discogsID) else { return [] }
        let ids = (bundle.collaborators.map(\.artist.discogsID) + bundle.credits.map(\.artist.discogsID)).compactMap { $0 }
        return Set(ids.filter { $0 > 0 && $0 != discogsID && !Self.standIns.contains($0) })
    }

    /// Reads the bundles of some of the artists a page leads to, so their rows
    /// can say where they go next and DEEP can walk on through them. Only
    /// those the manifest lists, at most `limit`, one at a time; never in
    /// front of a page.
    func prefetch(_ ids: [Int], limit: Int = 12) async -> Int {
        guard isEnabled else { return 0 }
        var read = 0
        for id in ids where read < limit && hasBundle(id) && bundle(for: id) == nil {
            if await ensure(id) == .fetched { read += 1 }
        }
        return read
    }

    /// The labels an entry's bundle names, by Discogs id, when it has been read.
    func labels(for discogsID: Int) -> [ArtistBundle.Label] {
        bundle(for: discogsID)?.labels.filter { !$0.placeholder && !$0.ownName && $0.discogsID != nil } ?? []
    }

    /// The bundle for an entry, if the pilot is on and it has been read.
    /// Synchronous: the graph walk asks, and never waits on the network.
    func bundle(for discogsID: Int) -> ArtistBundle? {
        guard isEnabled else { return nil }
        return lock.withLock { bundles[discogsID] }
    }

    /// Reads a page's bundle into memory. The page does not wait on it.
    func ensure(_ discogsID: Int) async -> Outcome {
        guard isEnabled else { return .off }
        if lock.withLock({ bundles[discogsID] != nil }) { return .held }
        let started = ContinuousClock.now
        let outcome = await load(discogsID)
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        Trace.note("catalogue.bundle \(discogsID) \(outcome) \(ms)ms")
        return outcome
    }

    /// Forgets what is in memory (not what is on disk). Tests.
    func reset() {
        lock.withLock { manifest = nil; manifestDigest = nil; bundles = [:]; manifestFailedAt = nil }
    }

    private func load(_ discogsID: Int) async -> Outcome {
        guard let entries = await manifestEntries() else { return .failed("manifest") }
        guard let entry = entries[discogsID] else { return .notInPilot }
        if let kept = fromDisk(entry) {
            lock.withLock { bundles[discogsID] = kept }
            return .held
        }
        do {
            let (status, data) = try await readTwice(entry.key, fresh: false)
            guard status == 200, let data else { return .failed("bundle HTTP \(status)") }
            // A body that is not its digest is wrong, not late.
            guard BundleFetcher.digest(data) == entry.digest else { return .failed("bundle digest") }
            let bundle = try JSONDecoder().decode(ArtistBundle.self, from: data)
            toDisk(data, entry)
            lock.withLock { bundles[discogsID] = bundle }
            return .fetched
        } catch {
            return .failed("bundle \((error as? URLError).map { "URLError \($0.code.rawValue)" } ?? error.localizedDescription)")
        }
    }

    /// When the manifest last failed. An unreachable host is asked once a
    /// minute, not once a page.
    private var manifestFailedAt: ContinuousClock.Instant?
    static let failureCooldown: Duration = .seconds(60)

    private func manifestEntries() async -> [Int: Entry]? {
        let required = requiredManifest
        if let held = lock.withLock({ manifest }), required == nil || required == lock.withLock({ manifestDigest }) { return held }
        if let failed = lock.withLock({ manifestFailedAt }), ContinuousClock.now - failed < Self.failureCooldown {
            return keptManifest()
        }
        if let entries = await readManifest() { return entries }
        lock.withLock { manifestFailedAt = .now }
        // The last manifest this device checked, when the host cannot be
        // reached: its bundles are addressed, so what it names is still exact.
        return keptManifest()
    }

    /// The pointer and the manifest it names.
    private func readManifest() async -> [Int: Entry]? { await readManifestOnce() }

    /// One read, tried again once after a short pause when it fails or is
    /// refused: a first read on a cold network often fails where the second
    /// does not. A 404 is an answer, not a failure.
    private func readTwice(_ key: String, fresh: Bool) async throws -> (status: Int, data: Data?) {
        do {
            let first = try await read(key, fresh)
            if first.status == 200 || first.status == 404 { return first }
        } catch {}
        try? await Task.sleep(for: Self.retryPause)
        return try await read(key, fresh)
    }

    static let retryPause: Duration = .milliseconds(800)

    private func readManifestOnce() async -> [Int: Entry]? {
        do {
            let (status, data) = try await readTwice(Self.pointerKey, fresh: true)
            guard status == 200, let data else { return nil }
            let pointer = try JSONDecoder().decode(Pointer.self, from: data)
            let (manifestStatus, body) = try await readTwice(pointer.manifest, fresh: false)
            // Only the manifest the switch pins, when it is the switch deciding.
            if let required = requiredManifest, pointer.digest != required { return nil }
            guard manifestStatus == 200, let body, BundleFetcher.digest(body) == pointer.digest,
                  let entries = Self.entries(body) else { return nil }
            keep(manifest: body)
            lock.withLock { manifest = entries; manifestDigest = pointer.digest }
            return entries
        } catch {
            return nil
        }
    }

    private static func entries(_ body: Data) -> [Int: Entry]? {
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: body) else { return nil }
        var entries: [Int: Entry] = [:]
        for (id, entry) in decoded.artists { if let id = Int(id) { entries[id] = entry } }
        return entries
    }

    /// The last manifest checked, with its digest, so it can be checked again.
    private var keptManifestURL: URL? { directory?.appendingPathComponent("manifest.json") }
    private var keptDigestURL: URL? { directory?.appendingPathComponent("manifest.digest") }

    private func keep(manifest body: Data) {
        guard let directory, let url = keptManifestURL, let digestURL = keptDigestURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: url, options: .atomic)
        try? Data(BundleFetcher.digest(body).utf8).write(to: digestURL, options: .atomic)
    }

    private func keptManifest() -> [Int: Entry]? {
        guard let url = keptManifestURL, let digestURL = keptDigestURL,
              let body = try? Data(contentsOf: url), let digest = try? Data(contentsOf: digestURL),
              BundleFetcher.digest(body) == String(decoding: digest, as: UTF8.self) else { return nil }
        if let required = requiredManifest, BundleFetcher.digest(body) != required { return nil }
        return Self.entries(body)
    }

    private func file(_ entry: Entry) -> URL? { directory?.appendingPathComponent("\(entry.digest).json") }

    private func fromDisk(_ entry: Entry) -> ArtistBundle? {
        guard let url = file(entry), let data = try? Data(contentsOf: url),
              BundleFetcher.digest(data) == entry.digest else { return nil }
        return try? JSONDecoder().decode(ArtistBundle.self, from: data)
    }

    private func toDisk(_ data: Data, _ entry: Entry) {
        guard let directory, let url = file(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    @Sendable static func live(_ key: String, _ fresh: Bool) async throws -> (status: Int, data: Data?) {
        guard let host = SupabaseConfiguration.catalogCacheHost, !host.contains("/"),
              let url = URL(string: "https://\(host)/\(key)") else { throw URLError(.badURL) }
        let policy: URLRequest.CachePolicy = fresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, cachePolicy: policy, timeoutInterval: 10))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, status == 200 ? data : nil)
    }
}
