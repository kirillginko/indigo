//
//  PortraitIdentityTests.swift
//  IndigoTests
//
//  Portraits by identity, not by name (DIG-REMEDIATION-PLAN.md §9, 0081): a
//  row that knows its Discogs artist never wears a namesake's face; a name two
//  Discogs artists share gets no face rather than a stranger's; a face the old
//  first-match rule cached here is withheld or replaced when the catalogue
//  says so. The real cases: the Hype Williams duo and the film director,
//  Speedy J's two entries, Prefuse 73 and its radio spelling, Mica Levi and
//  her alias Micachu.
//

import XCTest
import SwiftData
@testable import Indigo

/// Real Discogs image addresses (decoded paths in the comments).
enum Faces {
    /// s3://discogs-database-images/A-398459-1256391322.jpeg -- the director
    static let director = "https://i.discogs.com/gF3UcIDXVLHrrOyr2NC1Eqc9SfLQ4TukYpInFcDDDok/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9BLTM5ODQ1/OS0xMjU2MzkxMzIy/LmpwZWc.jpeg"
    /// s3://discogs-database-images/A-823-1777548001-5282.jpeg -- Speedy J (Jochem Paap)
    static let speedyJ = "https://i.discogs.com/kmPB8IPC_2VvKewUf0uIhjUhha8OgPJ-NWIuQ9Z3Dko/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9BLTgyMy0x/Nzc3NTQ4MDAxLTUy/ODIuanBlZw.jpeg"
    /// s3://discogs-database-images/A-65619-001.jpg -- Tom Zé's own picture on
    /// his entry, 465904; 65619 is an entry Discogs merged away, and the file
    /// kept its path.
    static let tomZe = "https://i.discogs.com/A3xw-7WhYaD9Q-OiJ5yOr_4uVuZg3c0UnVemgvgBqpg/rs:fit/g:sm/q:40/h:150/w:150/czM6Ly9kaXNjb2dz/LWRhdGFiYXNlLWlt/YWdlcy9BLTY1NjE5/LTAwMS5qcGc.jpeg"
    static let duo = "https://img.test/hype-williams-duo.jpg"
    static let prefuse = "https://img.test/prefuse-73.jpg"
}

/// Discogs search, answered from a table, counting requests.
final class SearchTransport: DiscogsTransport, @unchecked Sendable {
    let results: [[String: Any]]
    private(set) var asked = 0
    init(_ results: [[String: Any]]) { self.results = results }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        asked += 1
        let body = try JSONSerialization.data(withJSONObject: ["results": results])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Answers the artist-detail request and records whether a name search was used.
private final class PortraitDetailTransport: DiscogsTransport, @unchecked Sendable {
    let body: [String: Any]
    private(set) var paths: [String] = []

    init(_ body: [String: Any]) { self.body = body }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class PortraitAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [[String]] = []
    func record(_ keys: [String]) { lock.withLock { asks.append(keys) } }
    var count: Int { lock.withLock { asks.count } }
    var keys: [[String]] { lock.withLock { asks } }
    var last: [String]? { lock.withLock { asks.last } }
}

@MainActor
final class PortraitIdentityTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUp() async throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func store(defaults: String = UUID().uuidString) -> DigStore {
        let dig = DigStore(context: context)
        dig.portraitDefaults = UserDefaults(suiteName: "indigo.tests.\(defaults)")!
        return dig
    }

    private func cache(_ name: String, _ address: String?, key: String? = nil) {
        let portrait = ArtistPortrait(nameKey: key ?? RecordingKey.normalizeArtist(name), name: name)
        portrait.imageURLString = address
        context.insert(portrait)
        try? context.save()
    }

    // MARK: Whose face an address is

    func testAnAddressSaysWhoseFaceItIs() {
        XCTAssertEqual(DiscogsClient.picturedArtist(in: Faces.director), 398459)
        XCTAssertEqual(DiscogsClient.picturedArtist(in: Faces.speedyJ), 823)
        XCTAssertNil(DiscogsClient.picturedArtist(in: Faces.duo), "Not a Discogs address")
        XCTAssertNil(DiscogsClient.picturedArtist(in: nil))
    }

    // MARK: Searching by name

    func testNamesakesGetNoFaceAndAUniqueNameIsAPictureNotAnIdentity() {
        let hype: [DiscogsSearchResult] = [
            .init(id: 398459, title: "Hype Williams", coverImage: Faces.director, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
            .init(id: 1874027, title: "Hype Williams (2)", coverImage: Faces.duo, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
        ]
        XCTAssertEqual(DiscogsClient.portraitPick(name: "Hype Williams", results: hype), .ambiguous([398459, 1874027]))
        let prefuse: [DiscogsSearchResult] = [
            .init(id: 3722, title: "Prefuse 73", coverImage: Faces.prefuse, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
            .init(id: 5, title: "Prefuse 73 Tribute", coverImage: nil, thumbnail: nil, genre: nil, style: nil, label: nil, year: nil),
        ]
        XCTAssertEqual(DiscogsClient.portraitPick(name: "Prefuse 73", results: prefuse), .unique(address: Faces.prefuse, discogsID: 3722))
        XCTAssertEqual(DiscogsClient.portraitPick(name: "Nobody", results: prefuse), .none)
    }

    func testTheFillWithholdsAFaceANameCannotChooseAndReplacesTheOneCachedBefore() async throws {
        // What the old first-match rule left here: the director, under the duo's name.
        cache("Hype Williams", Faces.director)
        let transport = SearchTransport([
            ["id": 398459, "title": "Hype Williams", "cover_image": Faces.director],
            ["id": 1874027, "title": "Hype Williams (2)", "cover_image": Faces.duo],
        ])
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: transport, token: "test"))
        let outcome = await worker.fillPortrait(named: "Hype Williams")
        guard case .missing = outcome else { return XCTFail("\(outcome)") }
        let key = RecordingKey.normalizeArtist("Hype Williams")
        let kept = try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == key }))
        XCTAssertNil(kept.first?.imageURLString, "The stranger's face is gone")
        XCTAssertEqual(kept.first?.lookupFailed, true)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>()).allSatisfy { !$0.nameKey.hasPrefix("#") },
                      "No identity was made up from a name")
    }

    func testAFaceFoundForAKnownArtistIsKeptUnderTheirIdentity() async throws {
        let duo = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Hype Williams"), discogsID: 1874027, name: "Hype Williams")
        duo.imageURLString = Faces.duo
        context.insert(duo)
        try context.save()
        let transport = SearchTransport([])
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: transport, token: "test"))
        guard case .found(let url) = await worker.fillPortrait(named: "Hype Williams") else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, Faces.duo)
        XCTAssertEqual(transport.asked, 0, "Known: no search")
        let identity = ArtistPortrait.identityKey(1874027)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == identity })).first?.imageURLString, Faces.duo)
    }

    // MARK: Reading a face for a row

    func testARowThatKnowsWhoItIsNeverWearsANamesakesFace() async throws {
        let dig = store()
        dig.cataloguePortraits = { _ in [
            "hype williams": .init(state: "unresolved", url: Faces.director),
            "speedy j": .init(state: "verified", url: Faces.speedyJ, discogsID: 823),
        ] }
        await dig.revalidateCachedPortraits()   // nothing cached yet: a no-op
        dig.wantPortraits(for: ["Hype Williams", "Speedy J"])
        for _ in 0..<300 where dig.portraitURL(for: "Speedy J") == nil { try await Task.sleep(for: .milliseconds(10)) }

        // The duo (1874027) is not the director (398459) the name-keyed face shows.
        XCTAssertNil(dig.portraitURL(for: "Hype Williams", discogsID: 1874027))
        XCTAssertEqual(dig.portraitURL(for: "Hype Williams", discogsID: 398459)?.absoluteString, Faces.director)
        // Speedy J: 823's verified face is 823's, never 316464's.
        XCTAssertEqual(dig.portraitURL(for: "Speedy J", discogsID: 823)?.absoluteString, Faces.speedyJ)
        XCTAssertNil(dig.portraitURL(for: "Speedy J", discogsID: 316464))
        // A row with no identity reads the name's, as before.
        XCTAssertEqual(dig.portraitURL(for: "Speedy J")?.absoluteString, Faces.speedyJ)
    }

    func testAVerifiedFaceReachesEverySpellingOfTheSameArtist() async throws {
        // prefuse73's radio row is 3722 through MusicBrainz (0076); its verified
        // face is 3722's, wherever the row is spelled "Prefuse 73".
        let dig = store()
        dig.cataloguePortraits = { _ in ["prefuse73": .init(state: "verified", url: Faces.prefuse, discogsID: 3722)] }
        dig.wantPortraits(for: ["Prefuse73"])
        for _ in 0..<300 where dig.portraitURL(for: "Prefuse73") == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dig.portraitURL(for: "Prefuse 73", discogsID: 3722)?.absoluteString, Faces.prefuse)
        // Aliases stay apart: Mica Levi (2576890) does not take Micachu's (1172814) identity key.
        XCTAssertNil(dig.portraitURL(for: "Mica Levi", discogsID: 2576890))
    }

    func testAnUnresolvedFaceIsShownButNeverMadeAnIdentity() async throws {
        let dig = store()
        dig.cataloguePortraits = { _ in ["purelink": .init(state: "unresolved", url: "https://img.test/purelink.jpg", discogsID: 77)] }
        dig.wantPortraits(for: ["Purelink"])
        for _ in 0..<300 where dig.portraitURL(for: "Purelink") == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dig.portraitURL(for: "Purelink")?.absoluteString, "https://img.test/purelink.jpg")
        let identity = ArtistPortrait.identityKey(77)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == identity })).isEmpty)
    }

    // MARK: What the old rule cached

    func testCachedFacesAreCheckedOnceAgainstTheCatalogue() async throws {
        // Cached by the old rule: a face for Nez (a namesake's), a face for Logic.
        cache("Nez", "https://img.test/nez-13.jpg")
        cache("Logic", "https://img.test/logic-old.jpg")
        cache("Untouched", "https://img.test/untouched.jpg")
        // A stored edge already wearing the stranger's face.
        let edge = StoredEdge(
            from: .artist("Somebody"), edge: MusicEdge(from: .artist("Somebody"), to: .artist("Nez"), kind: .frequentlyPlayedNearby,
                                                       source: .radio, reason: "r", confidence: 0.6, occurrences: 1))
        edge.toArtworkURLString = "https://img.test/nez-13.jpg"
        context.insert(edge)
        try context.save()

        let suite = UUID().uuidString
        let dig = store(defaults: suite)
        let asked = PortraitAsks()
        dig.cataloguePortraits = { keys in
            asked.record(keys)
            return ["nez": .init(state: "withheld"), "logic": .init(state: "verified", url: "https://img.test/logic.jpg", discogsID: 15177)]
        }
        await dig.revalidateCachedPortraits()

        XCTAssertNil(dig.portraitURL(for: "Nez"), "Withheld: no face")
        XCTAssertEqual(dig.portraitURL(for: "Logic")?.absoluteString, "https://img.test/logic.jpg", "Replaced by the verified one")
        let fresh = ModelContext(container)
        let nezKey = RecordingKey.normalizeArtist("Nez"), untouchedKey = RecordingKey.normalizeArtist("Untouched")
        XCTAssertNil(try fresh.fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == nezKey })).first?.imageURLString)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == untouchedKey })).first?.imageURLString,
                       "https://img.test/untouched.jpg", "A name the catalogue did not answer keeps its face")
        XCTAssertNil(try context.fetch(FetchDescriptor<StoredEdge>(predicate: #Predicate { $0.toKey == nezKey })).first?.toArtworkURLString,
                     "The stored edge no longer wears it")

        // Once only.
        let before = asked.count
        await dig.revalidateCachedPortraits()
        XCTAssertEqual(asked.count, before)
    }

    // MARK: Merged entries

    /// Discogs keeps an image's path when entries merge, so a verified picture
    /// can name a retired id. Whose it is comes from the verification, not the
    /// path: 4 of the 121 audited rows were this, and were never wrong.
    func testAVerifiedFaceIsKeptWhenItsPathNamesAMergedEntry() async throws {
        XCTAssertEqual(DiscogsClient.picturedArtist(in: Faces.tomZe), 65619)
        func edge(to id: Int) -> StoredEdge {
            var target = MusicNode.artist("Tom Zé")
            target.discogsID = id
            let row = StoredEdge(from: .artist("Os Mutantes"), edge: MusicEdge(
                from: .artist("Os Mutantes"), to: target, kind: .collaborator,
                source: .discogs, reason: "Recorded with", confidence: 0.9, occurrences: 1))
            context.insert(row)
            return row
        }
        let his = edge(to: 465904), namesake = edge(to: 999)
        let key = RecordingKey.normalizeArtist("Tom Zé")

        StoredEdge.repaint(artistKey: key, with: Faces.tomZe, in: context)
        XCTAssertNil(his.toArtworkURLString, "Unverified, the path is all there is to go on")

        StoredEdge.repaint(artistKey: key, with: Faces.tomZe, owner: 465904, in: context)
        XCTAssertEqual(his.toArtworkURLString, Faces.tomZe, "Verified for 465904: his")
        XCTAssertNil(namesake.toArtworkURLString, "And still nobody else's")

        let dig = store()
        dig.cataloguePortraits = { _ in [key: .init(state: "verified", url: Faces.tomZe, discogsID: 465904)] }
        dig.wantPortraits(for: ["Tom Zé"])
        for _ in 0..<300 where dig.portraitURL(for: "Tom Zé") == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(dig.portraitURL(for: "Tom Zé", discogsID: 465904)?.absoluteString, Faces.tomZe)
        XCTAssertNil(dig.portraitURL(for: "Tom Zé", discogsID: 999))
    }

    // MARK: Following the catalogue's changes (0083)

    func testOnlyCachedNamesTheCatalogueChangedAreAskedAgain() async throws {
        cache("Logic", "https://img.test/logic-old.jpg")
        cache("Untouched", "https://img.test/untouched.jpg")
        let dig = store()
        let asked = PortraitAsks()
        let feeds = PortraitAsks()
        dig.cataloguePortraits = { keys in
            asked.record(keys)
            return ["logic": .init(state: "withheld")]
        }
        dig.portraitChanges = { since in
            feeds.record([since])
            return .init(names: ["logic", "somebody-not-cached"], until: "2026-10-13T16:00:00Z", more: false)
        }

        // The first run starts the watermark and asks nothing: the full pass covered it.
        await dig.followPortraitChanges()
        XCTAssertEqual(feeds.count, 0)
        XCTAssertEqual(asked.count, 0)

        await dig.followPortraitChanges()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(asked.keys, [["logic"]], "Only the cached name the feed named")
        XCTAssertNil(dig.portraitURL(for: "Logic"), "Withheld since: its face is dropped")
        let untouchedKey = RecordingKey.normalizeArtist("Untouched")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ArtistPortrait>(predicate: #Predicate { $0.nameKey == untouchedKey })).first?.imageURLString,
                       "https://img.test/untouched.jpg")

        // The next launch starts where the answer ended.
        await dig.followPortraitChanges()
        XCTAssertEqual(feeds.last, ["2026-10-13T16:00:00Z"])
    }

    // MARK: Sharp, not the 150-pixel cut

    func testAKnownArtistsPortraitIsTheFullImage() async throws {
        let duo = DiscogsArtist(nameKey: RecordingKey.normalizeArtist("Hype Williams"), discogsID: 1874027, name: "Hype Williams")
        duo.thumbnailURLString = "https://i.discogs.com/x/rs:fit/g:sm/q:40/h:150/w:150/duo.jpeg"
        duo.imageURLString = "https://i.discogs.com/x/rs:fit/g:sm/q:90/h:600/w:600/duo.jpeg"
        context.insert(duo)
        try context.save()
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: SearchTransport([]), token: "test"))
        guard case .found(let url) = await worker.fillPortrait(named: "Hype Williams") else { return XCTFail() }
        XCTAssertFalse(DiscogsClient.isSmallCut(url.absoluteString), url.absoluteString)
    }

    func testAVerifiedThumbnailIsUpgradedByIdentityWithoutSearchingItsName() async throws {
        cache("Hype Williams", Faces.director)
        let full = "https://img.test/director-full.jpg"
        let transport = PortraitDetailTransport([
            "id": 398459, "name": "Hype Williams",
            "images": [["type": "primary", "uri": full, "uri150": Faces.director]]
        ])
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: transport, token: "test"))
        guard case .found(let url) = await worker.fillPortrait(named: "Hype Williams", verifiedDiscogsID: 398459) else {
            return XCTFail("Expected the full portrait of the verified artist")
        }
        XCTAssertEqual(url.absoluteString, full)
        XCTAssertEqual(transport.paths, ["/artists/398459"])
        let dig = store()
        await dig.loadPortraitIndex()
        XCTAssertEqual(dig.portraitURL(for: "Hype Williams", discogsID: 398459)?.absoluteString, full)
        XCTAssertFalse(dig.wantsPortraitRequest(for: "Hype Williams"))
    }

    func testAnUnavailableFullPortraitKeepsTheVerifiedThumbnail() async throws {
        cache("Hype Williams", Faces.director)
        let transport = PortraitDetailTransport(["id": 398459, "name": "Hype Williams", "images": []])
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: transport, token: "test"))
        guard case .unreachable = await worker.fillPortrait(named: "Hype Williams", verifiedDiscogsID: 398459) else {
            return XCTFail("A missing full image must not erase the verified thumbnail")
        }
        XCTAssertEqual(transport.paths, ["/artists/398459"])
        let dig = store()
        await dig.loadPortraitIndex()
        XCTAssertEqual(dig.portraitURL(for: "Hype Williams")?.absoluteString, Faces.director)
    }

    func testAnUpgradedFaceIsNotAskedForAgainOnTheNextLaunch() async throws {
        // A face the old rule left at 150 pixels.
        cache("Purelink", "https://i.discogs.com/x/rs:fit/g:sm/q:40/h:150/w:150/purelink.jpeg")
        let firstLaunch = store()
        await firstLaunch.loadPortraitIndex()
        XCTAssertTrue(firstLaunch.wantsPortraitRequest(for: "Purelink"), "A small cut on screen is asked for once")

        // The request finds the cover, and it is written down.
        let transport = SearchTransport([["id": 77, "title": "Purelink", "cover_image": "https://i.discogs.com/x/rs:fit/g:sm/q:90/h:600/w:600/purelink.jpeg"]])
        let worker = DigWorker(modelContainer: container, discogs: DiscogsClient(transport: transport, token: "test"))
        guard case .found(let url) = await worker.fillPortrait(named: "Purelink") else { return XCTFail() }
        XCTAssertFalse(DiscogsClient.isSmallCut(url.absoluteString))

        // The next launch starts from what was written: nothing to ask.
        let nextLaunch = store()
        await nextLaunch.loadPortraitIndex()
        XCTAssertEqual(nextLaunch.portraitURL(for: "Purelink"), url)
        XCTAssertFalse(nextLaunch.wantsPortraitRequest(for: "Purelink"), "Sharp now: no request on this launch or any after")
        XCTAssertEqual(transport.asked, 1)
    }
}
