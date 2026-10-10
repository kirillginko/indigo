//
//  CreditEdgeIdentityTests.swift
//  IndigoTests
//
//  Credit edges carrying the entries their credits named, and the rule for
//  which artists a listener already knows — safe for namesakes.
//

import XCTest
import SwiftData
@testable import Indigo

private func credit(_ filing: String, _ credited: String? = nil, id: Int?, role: String = "Producer",
                    category: ReleaseCredit.Category = .credit) -> ReleaseCredit {
    ReleaseCredit(category: category, order: 0, creditedName: credited ?? filing, filingName: filing,
                  discogsID: id, role: role, tracks: "")
}

private func edge(_ from: MusicNode, _ to: MusicNode, _ kind: RelationshipKind) -> MusicEdge {
    MusicEdge(from: from, to: to, kind: kind, source: .discogs, reason: "Producer on One Nation", confidence: 0.8)
}

final class CreditEdgeIdentityTests: XCTestCase {
    func testACreditedSpellingCarriesItsEntry() {
        let entries = CreditEdgeIdentity.entries(in: [credit("Dean Blunt", "Blunt", id: 2419343)])
        let attached = CreditEdgeIdentity.attach([edge(.artist("Hype Williams"), .artist("Blunt"), .producer)], entries: entries)

        XCTAssertEqual(attached[0].to.discogsID, 2419343)
        XCTAssertEqual(attached[0].to.title, "Blunt", "The credited spelling stays the reference")
        XCTAssertEqual(attached[0].reason, "Producer on One Nation", "And the role stays in the reason")
    }

    /// Two credits spelled alike naming two entries are namesakes; the edge
    /// keeps its name rather than guess.
    func testASpellingNamingTwoEntriesStaysAName() {
        let entries = CreditEdgeIdentity.entries(in: [
            credit("Hype Williams (2)", id: 1874027, category: .artist),
            credit("Hype Williams", id: 82, category: .artist)
        ])
        XCTAssertNil(entries["hype williams"])
        let attached = CreditEdgeIdentity.attach([edge(.release("Split", discogsID: 1), .artist("Hype Williams"), .sameRelease)], entries: entries)
        XCTAssertNil(attached[0].to.discogsID)
    }

    func testOnlyCreditBackedEdgesAreTouched() {
        let entries = CreditEdgeIdentity.entries(in: [credit("Dean Blunt", id: 2419343)])
        let edges = CreditEdgeIdentity.attach([
            edge(.artist("A"), .artist("Dean Blunt"), .sharedStyle),
            edge(.artist("A"), .artist("Dean Blunt"), .playedInShow),
            edge(.artist("A"), .artist("Dean Blunt", discogsID: 7), .producer)
        ], entries: entries)

        XCTAssertNil(edges[0].to.discogsID, "Sounding alike is not a credit")
        XCTAssertNil(edges[1].to.discogsID, "Nor is a radio play")
        XCTAssertEqual(edges[2].to.discogsID, 7, "An id already there is not replaced")
    }

    func testTheSameEntryFromSeveralReleasesIsOneAnswer() {
        let entries = CreditEdgeIdentity.entries(in: [
            credit("Dean Blunt", "Blunt", id: 2419343), credit("Dean Blunt", id: 2419343, role: "Written-By")
        ])
        XCTAssertEqual(entries["blunt"]?.discogsID, 2419343)
        XCTAssertEqual(entries["dean blunt"]?.discogsID, 2419343)
    }
}

final class KnownArtistPolicyTests: XCTestCase {
    private let duo = GraphIdentityKey.discogs(1874027)
    private let director = GraphIdentityKey.discogs(82)
    private let deanBlunt = GraphIdentityKey.discogs(2419343)
    private let joanne = GraphIdentityKey.discogs(1053396)

    private func names(_ map: [GraphIdentityKey: Set<String>]) -> (MusicNode) -> Set<String> {
        { node in GraphIdentityKey(nodeKey: node.key).flatMap { map[$0] } ?? [node.key] }
    }

    /// Kept as "Dean Blunt" and "Joanne Robertson"; reached by credits as their
    /// entries. Neither is offered back.
    func testAnArtistKeptByNameIsKnownUnderTheirOnlyIdentity() {
        let known = KnownArtistPolicy.alsoKnown(
            history: [.artist("Dean Blunt"), .artist("Joanne Robertson")],
            owners: ["dean blunt": [deanBlunt], "blunt": [deanBlunt], "joanne robertson": [joanne]],
            namesOf: names([:])
        )
        XCTAssertEqual(known, [deanBlunt.nodeID, joanne.nodeID])
    }

    /// Listening to "Hype Williams" by name says nothing about which.
    func testAnAmbiguousNameKnowsNoNamesake() {
        let known = KnownArtistPolicy.alsoKnown(
            history: [.artist("Hype Williams")],
            owners: ["hype williams": [duo, director]],
            namesOf: names([:])
        )
        XCTAssertTrue(known.isEmpty)
    }

    /// Keeping the duo by id knows the duo — and not the director, nor the
    /// shared name, which could be either.
    func testAVerifiedIdentityKnowsOnlyItself() {
        let known = KnownArtistPolicy.alsoKnown(
            history: [MusicNode(kind: .artist, key: duo.nodeKey, title: "Hype Williams")],
            owners: ["hype williams": [duo, director]],
            namesOf: names([duo: ["hype williams"]])
        )
        XCTAssertEqual(known, [duo.nodeID])
    }

    /// A verified spelling is the same artist under either name.
    func testPrefuse73KnownUnderEitherSpelling() {
        let prefuse = GraphIdentityKey.discogs(3722)
        let known = KnownArtistPolicy.alsoKnown(
            history: [MusicNode(kind: .artist, key: prefuse.nodeKey, title: "Prefuse 73")],
            owners: ["prefuse73": [prefuse], "prefuse 73": [prefuse]],
            namesOf: names([prefuse: ["prefuse73", "prefuse 73"]])
        )
        XCTAssertEqual(known, [prefuse.nodeID, "artist:prefuse73", "artist:prefuse 73"])
    }
}

/// The ranker's exclusion is applied before anything is cut, and with nothing
/// to exclude the answer is exactly what it was.
final class RankerKnownArtistTests: XCTestCase {
    private func knowledge(origin: MusicNode, targets: [String]) -> (PersonalInputs, KnowledgeSnapshot) {
        let personal = PersonalInputs(
            crate: [PersonalInputs.Kept(node: origin, addedAt: Date(timeIntervalSince1970: 0), genreTags: [],
                                        tasteArtistKeys: [origin.key], sceneArtistKey: nil)],
            plays: [], met: [], artistPlays: [:], haunts: [])
        let edges = targets.enumerated().map { index, name in
            MusicEdge(from: origin, to: .artist(name), kind: .collaborator, source: .discogs,
                      reason: "Credited together", confidence: 0.9 - Double(index) * 0.01)
        }
        let knowledge = LocalKnowledgeAdapter.assemble(
            origins: [origin], walked: [origin: .init(shared: edges, deviceLocal: [])],
            shows: [], artistTags: [:], scenes: nil, libraryCounts: [:])
        return (personal, knowledge)
    }

    func testNothingKnownIsExactlyTheOldAnswer() {
        let (personal, knowledge) = knowledge(origin: .artist("Hype Williams"), targets: (0..<20).map { "Peer \($0)" })
        let asOf = Date(timeIntervalSince1970: 1_000_000)
        let before = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf)
        let after = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf, alsoKnown: [])
        XCTAssertEqual(before.next.map(\.id), after.next.map(\.id))
        XCTAssertEqual(before.artists.map(\.id), after.artists.map(\.id))
    }

    func testAKnownArtistMakesRoomForTheNext() {
        let (personal, knowledge) = knowledge(origin: .artist("Hype Williams"), targets: (0..<20).map { "Peer \($0)" })
        let asOf = Date(timeIntervalSince1970: 1_000_000)
        let all = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf)
        let first = try! XCTUnwrap(all.next.first)
        let without = ExploreRanker.offers(personal: personal, knowledge: knowledge, asOf: asOf, alsoKnown: [first.id])

        XCTAssertFalse((without.next + without.artists).contains { $0.id == first.id })
        XCTAssertEqual(without.next.count + without.artists.count, all.next.count + all.artists.count,
                       "Excluded before the lists are cut, so the next candidate takes its place")
    }
}

/// Through the real graph and store: Dean Blunt reached as "Blunt", the
/// producer credit on a Hype Williams record, and as the artist on his own
/// release, is one node.
@MainActor
final class CreditEdgeGraphTests: XCTestCase {
    func testOneArtistReachedTwoWaysIsOneNode() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        let context = ModelContext(container)
        let enricher = DiscogsEnricher(context: context, client: DiscogsClient())
        func store(_ json: String, _ id: Int) throws {
            enricher.store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id)
        }
        try store(#"{"id":1,"title":"One Nation","artists":[{"id":1874027,"name":"Hype Williams (2)"}],"extraartists":[{"id":2419343,"name":"Dean Blunt","anv":"Blunt","role":"Producer"}]}"#, 1)
        try store(#"{"id":2,"title":"Black Metal","artists":[{"id":2419343,"name":"Dean Blunt"}]}"#, 2)
        let duo = DiscogsArtist(nameKey: "hype williams", discogsID: 1874027, name: "Hype Williams (2)")
        duo.releaseTitles = ["One Nation"]; duo.releaseYears = ["2010"]; duo.releaseDiscogsIDs = [1]
        duo.releaseImageURLStrings = [""]; duo.releaseLabels = [""]
        context.insert(duo)
        try context.save()

        let graph = GraphStore(context: context)
        let scope = CreditEdgeScope(context: context, graph: graph)
        let artist = MusicNode.artist("Hype Williams")
        let release = MusicNode.release("Black Metal", discogsID: 2)
        func attached(_ origin: MusicNode) -> [MusicEdge] {
            CreditEdgeIdentity.attach(graph.neighbors(of: origin).all,
                                      entries: CreditEdgeIdentity.entries(in: scope.credits(behind: origin)))
        }
        let canonicalizer = GraphCanonicalizer(identify: ArtistNodeIdentifier(store: DigStore(context: context)).identify)

        let viaCredit = try XCTUnwrap(canonicalizer.canonical(attached(artist)).first { $0.kind == .producer }).to
        let viaRelease = try XCTUnwrap(canonicalizer.canonical(attached(release)).first { $0.to.kind == .artist }).to

        XCTAssertEqual(viaCredit.id, "artist:discogs:2419343")
        XCTAssertEqual(viaRelease.id, viaCredit.id, "One artist, however he was reached")
        XCTAssertEqual(viaCredit.title, "Dean Blunt", "Called what his entry is called, not \"Blunt\"")
    }
}
