//
//  GraphCanonicalizerTests.swift
//  IndigoTests
//
//  The graph keyed by identity, in memory: defensible merges, separable
//  namesakes, recoverable uncertainty.
//

import XCTest
import SwiftData
@testable import Indigo

private func identity(_ identity: ArtistIdentity, _ provenance: ArtistNodeIdentity.Provenance,
                      carried: Int? = nil, basis: IdentityBasis? = nil) -> ArtistNodeIdentity {
    ArtistNodeIdentity(identity: identity, provenance: provenance, carriedDiscogsID: carried, basis: basis)
}

/// A stand-in for `ArtistNodeIdentifier`: Prefuse 73 under both spellings,
/// both Hype Williams by their credits, Mica Levi and Micachu as two entries,
/// a record filed under "Anika", and everyone else a name.
private func stub(_ node: MusicNode) -> ArtistNodeIdentity {
    switch (node.key, node.discogsID) {
    case ("prefuse 73", _): return identity(.discogs(3722), .resolver, basis: .canonicalName)
    case ("prefuse73", _): return identity(.discogs(3722), .resolver, basis: .nameVariation)
    case ("hype williams", 1874027?): return identity(.discogs(1874027), .credit, carried: 1874027)
    case ("hype williams", 82?): return identity(.discogs(82), .credit, carried: 82)
    case ("mica levi", _): return identity(.discogs(2576890), .credit, carried: node.discogsID)
    case ("micachu", _): return identity(.discogs(1172814), .credit, carried: node.discogsID)
    case ("anika", _): return identity(.discogs(1982320), .filedRecord, basis: .filedRecord)
    case ("walton", _): return identity(.name("walton"), .inferred, carried: node.discogsID)
    case ("aphex twin", _) where node.mbid != nil: return identity(.musicBrainz(node.mbid!), .resolver, basis: .musicBrainzID)
    default: return identity(.name(node.key), .nameOnly)
    }
}

private func edge(_ from: MusicNode, _ to: MusicNode, _ kind: RelationshipKind = .collaborator,
                  reason: String = "Credited together") -> MusicEdge {
    MusicEdge(from: from, to: to, kind: kind, source: .discogs, reason: reason, confidence: 0.8)
}

final class GraphCanonicalizerTests: XCTestCase {
    private func canonicalizer() -> GraphCanonicalizer { GraphCanonicalizer(identify: stub) }

    func testVerifiedSpellingsShareOneIdentityKey() {
        let graph = canonicalizer()
        XCTAssertEqual(graph.canonical(.artist("Prefuse73")).id, "artist:discogs:3722")
        XCTAssertEqual(graph.canonical(.artist("Prefuse 73")).id, "artist:discogs:3722")
        XCTAssertEqual(graph.canonical(.artist("Prefuse73")).discogsID, 3722)
    }

    func testCanonicalizingTwiceChangesNothing() {
        let graph = canonicalizer()
        for node in [MusicNode.artist("Prefuse73"), .artist("Hype Williams"), .artist("Somebody"), .label("Warp")] {
            let once = graph.canonical(node)
            XCTAssertEqual(graph.canonical(once), once)
            XCTAssertEqual(GraphCanonicalizer(identify: stub).canonical(once), once, "Even for a fresh canonicalizer")
        }
    }

    func testNamesakesAreSeparateAndAnAmbiguousReferenceStaysOnItsName() {
        let graph = canonicalizer()
        let duo = graph.canonical(.artist("Hype Williams", discogsID: 1874027))
        let director = graph.canonical(.artist("Hype Williams", discogsID: 82))
        let plain = graph.canonical(.artist("Hype Williams"))

        XCTAssertEqual(duo.id, "artist:discogs:1874027")
        XCTAssertEqual(director.id, "artist:discogs:82")
        XCTAssertEqual(plain.id, "artist:hype williams", "Not given to either namesake: the name it always had")
        XCTAssertEqual(Set([duo.title, director.title, plain.title]), ["Hype Williams"], "Same display name")
    }

    func testAliasesAreTwoIdentitiesAndStayLinked() {
        let graph = canonicalizer()
        let edges = graph.canonical([edge(.artist("Mica Levi"), .artist("Micachu"), .sameAlias, reason: "Alias")])

        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].from.id, "artist:discogs:2576890")
        XCTAssertEqual(edges[0].to.id, "artist:discogs:1172814")
    }

    /// A record DIG filed under a name is not enough to give the node an
    /// identity, but where it pointed is kept.
    func testAFiledRecordAloneDoesNotPlaceIdentity() {
        let graph = canonicalizer()
        let placement = graph.placement(of: .artist("Anika"))

        XCTAssertEqual(placement?.key, .name("anika"))
        XCTAssertEqual(placement?.evidence, .filedRecord)
        XCTAssertEqual(placement?.resolvedIdentity, .discogs(1982320), "Kept, so it can be promoted when evidence comes")
        XCTAssertEqual(placement?.reference, .artist("Anika"), "And the original reference with it")
    }

    func testACarriedMBIDIsNotAuthority() {
        let placement = canonicalizer().placement(of: .artist("Aphex Twin", mbid: "f22942a1-6f70-4f48-866e-238cb2308fbd"))
        XCTAssertEqual(placement?.key, .name("aphex twin"))
        XCTAssertEqual(placement?.evidence, .consistentRecord)
    }

    func testAnUnsupportedIDIsDropped() {
        let canonical = canonicalizer().canonical(.artist("walton", discogsID: 77829))
        XCTAssertEqual(canonical.id, "artist:walton")
        XCTAssertNil(canonical.discogsID, "An inferred id does not ride along on the identity node")
    }

    func testDuplicateEdgesFoldAndSelfLoopsGo() {
        let origin = MusicNode.artist("Scott Herren")
        let edges = canonicalizer().canonical([
            edge(origin, .artist("Prefuse73")),
            edge(origin, .artist("Prefuse 73")),
            edge(.artist("Prefuse 73"), .artist("Prefuse73"), .sameAlias, reason: "Same entry")
        ])

        XCTAssertEqual(edges.count, 1, "Two spellings of one entry are one edge; an entry beside itself is none")
        XCTAssertEqual(edges[0].to.id, "artist:discogs:3722")
        XCTAssertEqual(edges[0].occurrences, 2)
    }

    func testOrderDoesNotMatter() {
        let origin = MusicNode.artist("Scott Herren")
        let input = [
            edge(origin, .artist("Prefuse73")), edge(origin, .artist("Hype Williams", discogsID: 82)),
            edge(origin, .artist("Prefuse 73")), edge(origin, .artist("Hype Williams")),
            edge(origin, .artist("Hype Williams", discogsID: 1874027)), edge(origin, .artist("Mica Levi"))
        ]
        let expected = canonicalizer().canonical(input).map(\.id)
        for seed in 0..<12 {
            var generator = CanonicalShuffle(seed: UInt64(seed))
            XCTAssertEqual(canonicalizer().canonical(input.shuffled(using: &generator)).map(\.id), expected)
        }
    }

    /// The listener's history goes through the same map, so it meets the graph
    /// where the graph now is — and an ambiguous visit stays ambiguous.
    func testHistoryIsReadTheSameWay() {
        let graph = canonicalizer()
        let personal = PersonalInputs(
            crate: [PersonalInputs.Kept(node: .artist("Prefuse73"), addedAt: Date(timeIntervalSince1970: 0),
                                        genreTags: [], tasteArtistKeys: ["prefuse73"], sceneArtistKey: nil)],
            plays: [],
            met: [PersonalInputs.Met(node: .artist("Hype Williams"), weight: 1, lastAt: Date(timeIntervalSince1970: 0))],
            artistPlays: [:], haunts: []
        )
        let read = graph.canonical(personal)

        XCTAssertEqual(read.crate[0].node?.id, "artist:discogs:3722")
        XCTAssertEqual(read.met[0].node.id, "artist:hype williams")
        XCTAssertEqual(personal.crate[0].node?.id, "artist:prefuse73", "The original is untouched")
    }
}

extension GraphCanonicalizerTests {
    /// A name links an unresolved reference to the identity it was placed
    /// under — for "does the listener know this artist?", never for identity.
    func testANameLinksWithoutMerging() {
        let graph = canonicalizer()
        let verified = graph.canonical(.artist("Hype Williams", discogsID: 1874027))
        let unresolved = graph.canonical(.artist("Hype Williams"))

        XCTAssertNotEqual(verified.id, unresolved.id)
        XCTAssertEqual(graph.legacyKeys(of: verified), ["hype williams"])
        XCTAssertEqual(graph.legacyKeys(of: unresolved), ["hype williams"])
        XCTAssertEqual(graph.ownersByLegacyKey["hype williams"], [.discogs(1874027)])
    }

    func testANameTwoVerifiedEntriesShareHasTwoOwners() {
        let graph = canonicalizer()
        _ = graph.canonical(.artist("Hype Williams", discogsID: 1874027))
        _ = graph.canonical(.artist("Hype Williams", discogsID: 82))
        _ = graph.canonical(.artist("Hype Williams"))

        XCTAssertEqual(graph.ownersByLegacyKey["hype williams"], [.discogs(1874027), .discogs(82)])
    }

    func testAVerifiedSpellingIsReachedUnderBothNames() {
        let graph = canonicalizer()
        let node = graph.canonical(.artist("Prefuse73"))
        _ = graph.canonical(.artist("Prefuse 73"))
        XCTAssertEqual(graph.legacyKeys(of: node), ["prefuse73", "prefuse 73"])
    }
}

/// Deterministic shuffles.
private struct CanonicalShuffle: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// The same, through the real identifier and evidence.
@MainActor
final class GraphCanonicalizerEvidenceTests: XCTestCase {
    func testTheLiveIdentifierPlacesOnlyWhatEvidenceSupports() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        ArtistIdentityStore(context: context).record(DiscogsSpellingCheck(
            spelling: "Prefuse73", verdict: .variation(3722), resultCount: 1,
            results: [], facts: [try ArtistIdentityFixtures.facts(3722)]))
        context.insert(DiscogsArtist(nameKey: "duenn nyantora", discogsID: 3328071, name: "Duenn"))
        context.insert(DiscogsArtist(nameKey: "duenn", discogsID: 3328071, name: "Duenn"))
        let identifier = ArtistNodeIdentifier(store: DigStore(context: context))
        let graph = GraphCanonicalizer(identify: identifier.identify)

        XCTAssertEqual(graph.canonical(.artist("Prefuse73")).id, "artist:discogs:3722")
        XCTAssertEqual(graph.canonical(.artist("Duenn")).id, "artist:duenn", "A filed record is not proof")
        XCTAssertEqual(graph.canonical(.artist("Duenn", key: "duenn nyantora")).id, "artist:duenn nyantora")
    }
}
