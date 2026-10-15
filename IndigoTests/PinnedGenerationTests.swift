//
//  PinnedGenerationTests.swift
//  IndigoTests
//
//  The pinned-generation client against a bucket that lives in the test:
//  generations built here the way the publisher builds them (digests over
//  the exact bytes, a manifest naming them, a day pointer, the list), then
//  read by clean clients with their own caches -- and broken on purpose.
//

import XCTest
@testable import Indigo

/// R2 in memory. Every read is counted; any key can be made to fail, to come
/// back wrong, or the whole bucket to be unreachable.
final class PinnedBucket: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var _reads = 0
    private var _bytes = 0
    var offline = false
    var missing: Set<String> = []
    var corrupt: Set<String> = []
    /// Throws (a dropped connection) once this many objects have been read.
    var dropAfter: Int?

    func put(_ key: String, _ data: Data) { lock.withLock { objects[key] = data } }
    func get(_ key: String) -> Data? { lock.withLock { objects[key] } }
    var reads: Int { lock.withLock { _reads } }
    var bytes: Int { lock.withLock { _bytes } }

    func read(_ key: String) throws -> (status: Int, data: Data?) {
        try lock.withLock {
            if offline { throw URLError(.notConnectedToInternet) }
            if let limit = dropAfter, _reads >= limit { throw URLError(.networkConnectionLost) }
            _reads += 1
            guard !missing.contains(key), var data = objects[key] else { return (404, nil) }
            if corrupt.contains(key) { data.append(contentsOf: Array(" ".utf8)) }
            _bytes += data.count
            return (200, data)
        }
    }

    var reader: PinnedGenerationClient.Read { { [self] key in try self.read(key) } }
}

final class PinnedGenerationTests: XCTestCase {
    static let day12 = ExplorePeriod.containing(ISO8601DateFormatter().date(from: "2026-10-12T15:00:00Z")!)
    let now = ISO8601DateFormatter().date(from: "2026-10-12T15:00:00Z")!

    /// The listener: five starting points, newest first.
    static let personal: PersonalInputs = {
        func met(_ name: String, _ hours: Double) -> PersonalInputs.Met {
            .init(node: .artist(name), weight: 1, lastAt: Date(timeIntervalSince1970: 1_791_500_000 - hours * 3_600))
        }
        return PersonalInputs(
            crate: [], plays: [],
            met: [met("Dean Blunt", 1), met("Speedy J", 2), met("Annika Henderson", 3), met("Inga Copeland", 4),
                  met("Somebody New", 5)].sorted { $0.node.id < $1.node.id },
            artistPlays: ["dean blunt": 3, "speedy j": 2, "inga copeland": 1, "somebody new": 1, "nobody files this": 1],
            haunts: [])
    }()

    // MARK: Building generations, as the publisher does

    /// Canonical enough: keys sorted, no whitespace. The client never
    /// re-encodes anything, so all that matters is that the digest is over
    /// these bytes.
    static func bytes(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func edge(_ kind: String, _ name: String, discogs: String? = nil, evidence: String? = nil,
                     reason: String = "Both release on World Music", target: String = "artist") -> [String: Any] {
        var to: [String: Any] = ["kind": target, "name": name, "rowID": "row-\(name.lowercased())"]
        if let discogs { to["discogsID"] = discogs }
        if let evidence { to["idEvidence"] = evidence }
        return ["kind": kind, "reason": reason, "confidence": 0.8, "occurrences": 2, "to": to]
    }

    struct Published {
        let date: String
        let manifest: String
        let keys: [String]
    }

    /// One generation for `date`. `variant` changes an answer, so two days
    /// differ. The origins this test's listener has: Dean Blunt found (with a
    /// partial bundle), Speedy J found and ambiguous (bundles missing), Annika
    /// Henderson unknown, Inga Copeland unsupported (as a station would be),
    /// Somebody New not demanded at all.
    @discardableResult
    static func publish(_ bucket: PinnedBucket, date: String, variant: String = "") -> Published {
        var keys: [String] = []
        func store(_ key: String, _ data: Data) { bucket.put(key, data); keys.append(key) }
        func object(kind: String, id: String, answer: [String: Any]) -> String {
            let data = bytes(["format": "indigo.knowledge-answer/1", "kind": kind, "id": id, "answer": answer])
            let digest = GenerationKeys.digest(data)
            store(GenerationKeys.answer(digest), data)
            return digest
        }
        let bundle = ArtistBundle(
            format: "indigo.artist-knowledge/1", artist: .init(discogsID: 2419343, name: "Dean Blunt"),
            releases: [.init(id: 1, masterID: nil, title: "Black Metal", year: 2014, relation: "Main", compilation: false)],
            styles: [.init(name: "Experimental", releases: 3)], genres: [.init(name: "Electronic", releases: 3)],
            stylesAround: [], labels: [],
            collaborators: [.init(artist: .init(discogsID: 777, name: "Joanne Robertson", anv: nil), how: ["joint"], releases: [1])],
            credits: [],
            source: .init(identity: "backend", discography: nil, complete: false, truncated: false, totalReported: 9,
                          pagesReported: 1, pagesFetched: 1, entries: 9, representativeReleases: 9, documentsRead: 3,
                          documentsMissing: 6, documentsTruncated: 0, otherPressingsRead: 0))
        let bundleData = try! JSONEncoder().encode(bundle)
        let bundleDigest = GenerationKeys.digest(bundleData)
        bucket.put(GenerationKeys.bundle(bundleDigest), bundleData)

        let dean = object(kind: "node", id: "artist:dean blunt", answer: [
            "status": "found",
            "identities": [["discogsID": "2419343", "via": "discogs", "catalogued": true]],
            "edges": [edge("sharedLabel", "Inga Copeland", discogs: "1874031", evidence: "discogs-document"),
                      edge("frequentlyPlayedNearby", "Panda Bear" + variant, discogs: "62012", evidence: "adopted-by-name",
                           reason: "Played next to each other on the radio"),
                      edge("sharedLabel", "Rare Name", reason: "Both release on Hyperdub"),
                      edge("sharedLabel", "Hyperdub", reason: "Released on Hyperdub", target: "label")],
            "seeds": [["rowID": "row-dean", "name": "Dean Blunt", "by": ["discogs", "name"], "discogsID": "2419343"]]])
        let speedy = object(kind: "node", id: "artist:speedy j", answer: [
            "status": "found", "ambiguousName": true,
            "identities": [["discogsID": "316464", "via": "discogs", "catalogued": true],
                           ["discogsID": "823", "via": "discogs", "catalogued": true]],
            "edges": [edge("sharedLabel", "Jochem Paap", reason: "Both release on Plus 8")]])
        var artists: [String: Any] = [:]
        for key in ["dean blunt", "speedy j", "inga copeland"] {
            artists[key] = ["status": "found", "answer": object(kind: "artist", id: key, answer: [
                "status": "found", "genres": ["Ambient", "Club"], "rosters": [],
                "episodes": [["providerID": "nts", "showID": "\(key.replacingOccurrences(of: " ", with: "-"))-show",
                              "title": "\(key) on NTS", "genres": ["Ambient"]]]])]
        }
        artists["nobody files this"] = ["status": "unknown"]
        let identity = bytes(["format": "indigo.knowledge-identity/1", "rows": [], "namesakes": [], "starting": [:]])
        let identityDigest = GenerationKeys.digest(identity)
        store(GenerationKeys.identity(identityDigest), identity)

        let manifest = bytes([
            "format": "indigo.knowledge-generation/1", "id": "kg-\(date)", "date": date, "previous": NSNull(),
            "source": ["cutAt": "\(date)T00:41:07.123+00:00", "snapshot": "1:1:", "edges": ["runid": 88841, "endedAt": "\(date)T00:23:18Z"],
                       "statementMs": 900],
            "demand": ["digest": "test", "nodes": 4, "artists": 4],
            "identity": identityDigest,
            "nodes": [
                "artist:dean blunt": ["status": "found", "answer": dean,
                                      "bundles": [["discogsID": 2419343, "status": "partial", "digest": bundleDigest, "read": 3, "of": 9]]],
                "artist:speedy j": ["status": "found", "answer": speedy, "ambiguousName": true,
                                    "bundles": [["discogsID": 316464, "status": "missing"], ["discogsID": 823, "status": "missing"]]],
                "artist:annika henderson": ["status": "unknown"],
                "artist:inga copeland": ["status": "unsupported"]],
            "artists": artists,
            "summary": [:],
            "publication": ["complete": true, "objects": keys.count + 1, "bundlesPinned": 1]] as [String: Any])
        let manifestDigest = GenerationKeys.digest(manifest)
        store(GenerationKeys.manifest(manifestDigest), manifest)
        store(GenerationKeys.day(date), bytes(["format": "indigo.knowledge-day/1", "date": date, "manifest": manifestDigest,
                                               "publishedAt": "\(date)T00:42:00Z"]))
        return Published(date: date, manifest: manifestDigest, keys: keys)
    }

    static func list(_ bucket: PinnedBucket, _ published: [Published], withdrawn: [[String: String]] = []) {
        bucket.put(GenerationKeys.current, bytes([
            "format": "indigo.knowledge-current/1", "updatedAt": "x",
            "generations": published.sorted { $0.date > $1.date }.map { ["date": $0.date, "manifest": $0.manifest] },
            "withdrawn": withdrawn]))
    }

    func freshStore() -> PinnedGenerationStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pinned-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return PinnedGenerationStore(root: url)
    }

    func resolve(_ store: PinnedGenerationStore, _ bucket: PinnedBucket, period: Int = day12) async
        -> (PinnedGeneration?, PinnedGenerationClient.Report) {
        await PinnedGenerationClient.resolve(period: period, store: store, read: bucket.reader, now: now)
    }

    // MARK: Two clean clients

    func testTwoCleanClientsHoldTheSameKnowledgeAndRankTheSame() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])

        var results: [(shared: String, candidates: Set<String>, ranked: [String], next: [String], code: String)] = []
        for _ in 0..<2 {
            let (generation, report) = await resolve(freshStore(), bucket)
            let pinned = try XCTUnwrap(generation, report.errors.joined(separator: "; "))
            XCTAssertEqual(report.source, "downloaded")
            XCTAssertEqual(pinned.manifestDigest, published.manifest)
            let (snapshot, coverage, _) = PinnedKnowledgeAdapter.snapshot(
                personal: Self.personal, deviceLocal: .empty, generation: pinned, now: now)
            let ranking = ShadowComparison.ranking(personal: Self.personal, knowledge: snapshot,
                                                   asOf: ExplorePeriod.asOf(Self.day12), turn: Self.day12)
            results.append((CanonicalDigest.of(snapshot.shared), Set(ranking.all.map(\.id)), ranking.all.map(\.id),
                            ranking.next.map(\.id), coverage.code))
        }
        XCTAssertFalse(results[0].ranked.isEmpty, "Something to rank, or the comparison says nothing")
        XCTAssertEqual(results[0].shared, results[1].shared, "Knowledge digest")
        XCTAssertEqual(results[0].candidates, results[1].candidates, "Candidate set")
        XCTAssertEqual(results[0].ranked, results[1].ranked, "Ranked recommendations")
        XCTAssertEqual(results[0].next, results[1].next)
        XCTAssertEqual(results[0].code, results[1].code)
    }

    // MARK: Verification

    func testDigestsAreCheckedOverTheExactBytesBeforeDecoding() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])
        // The same manifest, re-encoded with whitespace: equal as JSON, not as bytes.
        let key = GenerationKeys.manifest(published.manifest)
        let pretty = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: bucket.get(key)!), options: [.prettyPrinted, .sortedKeys])
        bucket.put(key, pretty)
        let (generation, report) = await resolve(freshStore(), bucket)
        XCTAssertNil(generation)
        XCTAssertTrue(report.errors.contains { $0.contains("digest mismatch") }, "\(report.errors)")

        // An answer with one name decomposed (NFD): the same string to Swift,
        // other bytes -- refused, never normalised into acceptance.
        let other = PinnedBucket()
        let again = Self.publish(other, date: "2026-10-11", variant: "\u{00E9}")
        Self.list(other, [again])
        let answerKey = again.keys.first { $0.contains("/objects/") && String(data: other.get($0)!, encoding: .utf8)!.contains("Panda") }!
        let nfd = String(data: other.get(answerKey)!, encoding: .utf8)!.replacingOccurrences(of: "\u{00E9}", with: "e\u{0301}")
        other.put(answerKey, Data(nfd.utf8))
        let (none, failed) = await resolve(freshStore(), other)
        XCTAssertNil(none)
        XCTAssertTrue(failed.errors.contains { $0.contains("digest mismatch") }, "\(failed.errors)")
    }

    func testAMissingObjectMakesTheGenerationUnusableAndFallsBack() async throws {
        let bucket = PinnedBucket()
        let older = Self.publish(bucket, date: "2026-10-10")
        Self.list(bucket, [older])
        let store = freshStore()
        let (first, _) = await resolve(store, bucket, period: Self.day12 - 1)
        XCTAssertEqual(first?.date, "2026-10-10")

        let newer = Self.publish(bucket, date: "2026-10-11", variant: " II")
        Self.list(bucket, [older, newer])
        bucket.missing = [newer.keys.first { $0.contains("/objects/") }!]
        let (generation, report) = await resolve(store, bucket)
        XCTAssertEqual(report.source, "fallback")
        XCTAssertEqual(report.selected?.hasPrefix("2026-10-11"), true)
        XCTAssertEqual(generation?.date, "2026-10-10", "The last generation kept whole, never part of the new one")
        XCTAssertTrue(report.errors.contains { $0.contains("missing") })

        let (none, cold) = await resolve(freshStore(), bucket)
        XCTAssertNil(none, "A clean client with nothing kept has nothing to fall back on")
        XCTAssertEqual(cold.source, "none")
    }

    func testACorruptObjectIsNeverKept() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])
        let victim = published.keys.first { $0.contains("/identity/") }!
        bucket.corrupt = [victim]
        let store = freshStore()
        let (generation, report) = await resolve(store, bucket)
        XCTAssertNil(generation)
        XCTAssertTrue(report.errors.contains { $0.contains("digest mismatch") })
        XCTAssertTrue(store.markers().isEmpty)
        let digest = String(victim.split(separator: "/").last!.dropLast(5))
        XCTAssertNil(store.object(digest), "Nothing wrong is ever written to the cache")
    }

    func testAnInterruptedDownloadNeverReplacesTheKeptGenerationAndResumes() async throws {
        let bucket = PinnedBucket()
        let older = Self.publish(bucket, date: "2026-10-10")
        Self.list(bucket, [older])
        let store = freshStore()
        _ = await resolve(store, bucket, period: Self.day12 - 1)

        let newer = Self.publish(bucket, date: "2026-10-11", variant: " II")
        Self.list(bucket, [older, newer])
        bucket.dropAfter = bucket.reads + 4   // the list, the day, the manifest, one object
        let (interrupted, report) = await resolve(store, bucket)
        XCTAssertEqual(report.source, "fallback")
        XCTAssertEqual(interrupted?.manifestDigest, older.manifest)
        XCTAssertEqual(store.markers().map(\.date), ["2026-10-10"], "No marker for a generation not had whole")
        XCTAssertNotNil(store.load(older.manifest), "The kept generation is untouched")

        bucket.dropAfter = nil
        let (resumed, again) = await resolve(store, bucket)
        XCTAssertEqual(again.source, "downloaded")
        XCTAssertEqual(resumed?.manifestDigest, newer.manifest)
        XCTAssertGreaterThan(again.objectsReused, 0, "What arrived before the drop is reused")
    }

    // MARK: Offline, stale, revoked

    func testOfflineStartupServesTheKeptGenerationAndDownloadsNothing() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])
        let root = freshStore().root
        let (online, _) = await resolve(PinnedGenerationStore(root: root), bucket)
        bucket.offline = true
        // A new process: a new client over the same folder.
        let (offline, report) = await resolve(PinnedGenerationStore(root: root), bucket)
        XCTAssertEqual(report.source, "offline-cache")
        XCTAssertEqual(report.bytesDownloaded, 0)
        XCTAssertEqual(offline?.manifestDigest, online?.manifestDigest)
        let a = PinnedKnowledgeAdapter.snapshot(personal: Self.personal, deviceLocal: .empty, generation: online!, now: now).0
        let b = PinnedKnowledgeAdapter.snapshot(personal: Self.personal, deviceLocal: .empty, generation: offline!, now: now).0
        XCTAssertEqual(CanonicalDigest.of(a.shared), CanonicalDigest.of(b.shared))
    }

    func testAStaleKeptGenerationIsServedAndSaidToBe() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])
        let store = freshStore()
        _ = await resolve(store, bucket)
        bucket.offline = true
        let (generation, report) = await resolve(store, bucket, period: Self.day12 + 20)
        XCTAssertEqual(generation?.date, "2026-10-11")
        XCTAssertEqual(report.source, "offline-cache")
        XCTAssertEqual(report.evaluationDay, GenerationKeys.date(ofPeriod: Self.day12 + 20))
    }

    func testARevokedGenerationIsReportedAndNeverServed() async throws {
        let bucket = PinnedBucket()
        let older = Self.publish(bucket, date: "2026-10-10")
        let newer = Self.publish(bucket, date: "2026-10-11", variant: " II")
        Self.list(bucket, [older, newer])
        let store = freshStore()
        let (first, _) = await resolve(store, bucket)
        XCTAssertEqual(first?.date, "2026-10-11")
        _ = await resolve(store, bucket, period: Self.day12 - 1)   // keeps 10-10 too

        Self.list(bucket, [older, newer], withdrawn: [["date": "2026-10-11", "reason": "bad edges"]])
        let (generation, report) = await resolve(store, bucket)
        XCTAssertEqual(generation?.date, "2026-10-10", "The newest one not withdrawn")
        XCTAssertEqual(report.revoked, ["2026-10-11 \(newer.manifest.prefix(12))"])

        // Offline afterwards: the withdrawal read last still holds.
        bucket.offline = true
        let (offline, offlineReport) = await resolve(store, bucket)
        XCTAssertEqual(offline?.date, "2026-10-10")
        XCTAssertEqual(offlineReport.revoked.count, 1)

        // Withdrawn and nothing else kept: nothing, and said.
        bucket.offline = false
        Self.list(bucket, [newer], withdrawn: [["date": "2026-10-11"]])
        let (none, cold) = await resolve(freshStore(), bucket)
        XCTAssertNil(none)
        XCTAssertEqual(cold.source, "none")
    }

    func testSelectionIsTheSameWheneverTheDayIsLookedAt() async throws {
        let bucket = PinnedBucket()
        let yesterday = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [yesterday])
        let (early, _) = await resolve(freshStore(), bucket)
        // Later the same day, the day's own generation is published.
        let today = Self.publish(bucket, date: "2026-10-12", variant: " III")
        Self.list(bucket, [yesterday, today])
        let (late, _) = await resolve(freshStore(), bucket)
        XCTAssertEqual(early?.manifestDigest, yesterday.manifest)
        XCTAssertEqual(late?.manifestDigest, yesterday.manifest, "The evaluation day ranks from the day before, all day")
        let (tomorrow, _) = await resolve(freshStore(), bucket, period: Self.day12 + 1)
        XCTAssertEqual(tomorrow?.manifestDigest, today.manifest)
    }

    func testCorruptionOnDiskIsCaughtAndRepaired() async throws {
        let bucket = PinnedBucket()
        let published = Self.publish(bucket, date: "2026-10-11")
        Self.list(bucket, [published])
        let store = freshStore()
        _ = await resolve(store, bucket)
        let victim = String(published.keys.first { $0.contains("/objects/") }!.split(separator: "/").last!.dropLast(5))
        try Data("garbage".utf8).write(to: store.objectURL(victim))
        XCTAssertNil(store.load(published.manifest), "A kept generation is checked again when read")
        let (generation, report) = await resolve(store, bucket)
        XCTAssertEqual(report.source, "downloaded")
        XCTAssertEqual(report.objectsDownloaded, 1, "Only the damaged object")
        XCTAssertEqual(generation?.manifestDigest, published.manifest)
    }

    // MARK: Coverage and the code

    func testCoverageStatesArePreservedAndNothingIsFilledIn() async throws {
        let bucket = PinnedBucket()
        Self.list(bucket, [Self.publish(bucket, date: "2026-10-11")])
        let (generation, _) = await resolve(freshStore(), bucket)
        let pinned = try XCTUnwrap(generation)
        let (snapshot, coverage, statuses) = PinnedKnowledgeAdapter.snapshot(
            personal: Self.personal, deviceLocal: .empty, generation: pinned, now: now)
        XCTAssertEqual(coverage.startingPoints, [
            "artist:dean blunt": "found", "artist:speedy j": "found", "artist:annika henderson": "unknown",
            "artist:inga copeland": "unsupported", "artist:somebody new": "deferred"])
        XCTAssertEqual(coverage.artists, ["found": 3, "unknown": 1, "deferred": 2], "Annika Henderson and Somebody New are not in the demand")
        XCTAssertEqual(coverage.bundles, ["partial": 1, "missing": 2])
        XCTAssertEqual(coverage.ambiguous, ["artist:speedy j"])
        XCTAssertEqual(coverage.code, "s2-1-1-1a3-1-2b0-1-2-0")
        XCTAssertEqual(statuses.first { $0.discogsID == 2419343 }?.status, "partial")
        XCTAssertEqual(statuses.filter { $0.discogsID != nil && $0.discogsID != 2419343 }.map(\.status), ["missing", "missing"])
        XCTAssertEqual(statuses.filter { $0.discogsID == nil }.map(\.detail).sorted(),
                       ["no catalogued Discogs artist (unknown)", "no catalogued Discogs artist (unsupported)"])

        // A deferred or unknown starting point has no neighbourhood at all.
        let origins = snapshot.shared.nodes
        for id in ["artist:somebody new", "artist:annika henderson", "artist:inga copeland"] {
            let index = origins.firstIndex { $0.id == id }
            let edges = snapshot.shared.neighbourhoods.first { index != nil && $0.origin == index }?.edges ?? []
            XCTAssertTrue(edges.isEmpty, id)
        }
        // And the partial bundle's collaboration is there, with the SQL's edges.
        let dean = try XCTUnwrap(origins.firstIndex { $0.id == "artist:dean blunt" })
        let kinds = Set(snapshot.shared.neighbourhoods.first { $0.origin == dean }?.edges.map(\.kind) ?? [])
        XCTAssertTrue(kinds.isSuperset(of: [.collaborator, .sharedLabel, .frequentlyPlayedNearby]), "\(kinds)")
    }

    func testTheFYCodeCarriesTheGenerationAndItsCoverage() {
        var entry = ExploreDiagnostics.Entry(
            stamp: ExploreStamp(format: 2, period: 20738, personal: "p", shared: "s", deviceLocal: "d"),
            ranked: ["a"], report: ExploreBuildReport())
        let before = entry.code
        var shadow = PinnedShadow()
        shadow.fetch.manifest = String(repeating: "d", count: 64)
        shadow.coverage.startingPoints = ["artist:a": "found", "artist:b": "deferred"]
        entry.pinned = shadow.codePart
        XCTAssertEqual(entry.code, before + ".gdddddddddddd.s1-0-0-1a0-0-0b0-0-0-0")
        let rows = ExploreDiagnostics.compare(entry.code, before)
        XCTAssertEqual(rows?.count, 10)
        XCTAssertEqual(rows?.suffix(2).map(\.there), ["—", "—"])
        XCTAssertEqual(ExploreDiagnostics.compare(before, before)?.count, 8, "Codes without it compare as before")
        XCTAssertEqual(PinnedShadow().codePart, "g-.none")
    }
}
