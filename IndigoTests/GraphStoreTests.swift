//
//  GraphStoreTests.swift
//  IndigoTests
//
//  Walking outward from a node. These pin the part of Phase 3A that decides
//  whether DIG can leave the artist page at all: that a label, a release, a
//  catalogue number, a broadcast and a white label are all places the walk
//  can reach, and that an artist's own aliases are a branch rather than a
//  crowd of strangers in the RELATED list.
//

import XCTest
import SwiftData
@testable import Indigo

final class GraphStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        store = RecordingStore(context: context)
    }

    override func tearDown() {
        store = nil
        context = nil
        container = nil
    }

    // MARK: Helpers

    @discardableResult
    private func artist(
        _ name: String,
        id: Int = Int.random(in: 1...100_000),
        aliases: [String] = [],
        groups: [String] = [],
        members: [String] = [],
        labels: [String] = [],
        styles: [String] = [],
        releases: [(String, Int)] = []
    ) -> DiscogsArtist {
        let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
        record.aliasNames = aliases
        record.groupNames = groups
        record.memberNames = members
        record.labelNames = labels
        record.styles = styles
        record.releaseTitles = releases.map(\.0)
        record.releaseDiscogsIDs = releases.map(\.1)
        context.insert(record)
        return record
    }

    @discardableResult
    private func release(_ title: String, id: Int, label: String, catalog: String) -> DiscogsReleaseRecord {
        let record = DiscogsReleaseRecord(discogsID: id, title: title)
        record.labelNames = [label]
        record.catalogNumbers = [catalog]
        context.insert(record)
        return record
    }

    // MARK: Aliases

    /// Discogs states aliases one page at a time, so arriving at the family
    /// from any corner has to recover the whole of it — which is the only way
    /// Prince of Denmark ever leads to DJ Metatron.
    func testAnAliasFamilyIsRecoveredFromWhicheverCornerYouArriveAt() {
        artist("Prince of Denmark", aliases: ["Traumprinz"])
        artist("Traumprinz", aliases: ["DJ Metatron"])
        artist("DJ Metatron")

        let resolver = AliasResolver(context: context)
        for entry in ["Prince of Denmark", "Traumprinz", "DJ Metatron"] {
            let names = Set(resolver.family(of: entry).aliases.map(\.name) + [entry])
            XCTAssertEqual(names, ["Prince of Denmark", "Traumprinz", "DJ Metatron"],
                           "Reached from \(entry)")
        }
    }

    /// The link means the same thing read backwards, even though only one of
    /// the two pages states it.
    func testAnAliasStatedOnlyOnSomeoneElsesPageStillCounts() {
        artist("Traumprinz", aliases: ["Prince of Denmark"])
        artist("Prince of Denmark")

        let family = AliasResolver(context: context).family(of: "Prince of Denmark")
        XCTAssertEqual(family.aliases.map(\.name), ["Traumprinz"])
    }

    /// Being another name for someone and being in a band with them are not
    /// the same claim, so they do not share a branch.
    func testProjectsHangOffTheFamilyRatherThanJoiningIt() {
        artist("Zenker Brothers", members: ["Dario Zenker", "Marco Zenker"], labels: ["Ilian Tape"])

        let family = AliasResolver(context: context).family(of: "Zenker Brothers")
        XCTAssertTrue(family.aliases.isEmpty)
        XCTAssertEqual(family.projects.map(\.name), ["Dario Zenker", "Marco Zenker"])
        XCTAssertTrue(family.projects.allSatisfy { $0.role == .member })
        XCTAssertFalse(AliasResolver(context: context).aliasKeys(of: "Zenker Brothers")
            .contains(RecordingKey.normalizeArtist("Dario Zenker")),
            "A member is not the group under another name")
    }

    /// An artist's other names belong on the alias branch. Listing them as
    /// related artists would tell a digger that Traumprinz is a good way to
    /// broaden out from Traumprinz.
    func testAnArtistsOwnAliasesStayOutOfTheRelatedList() {
        artist("Traumprinz", aliases: ["DJ Metatron"], labels: ["Giegling"], styles: ["Deep House"])
        artist("DJ Metatron", aliases: ["Traumprinz"], labels: ["Giegling"], styles: ["Deep House"])
        artist("Prime Minister of Doom", labels: ["Giegling"], styles: ["Deep House"])

        let related = GraphStore(context: context).relatedArtists(to: .artist("Traumprinz"))
        XCTAssertFalse(related.contains { $0.node.title == "DJ Metatron" })
        XCTAssertTrue(related.contains { $0.node.title == "Prime Minister of Doom" })
    }

    // MARK: Walking

    /// The step the old code could not take: off the artist page and onto
    /// something that is not another artist.
    func testAnArtistWalksOutToLabelsReleasesStylesAndCatalogueNumbers() {
        artist("Skee Mask", labels: ["Ilian Tape"], styles: ["Techno"],
               releases: [("Compro", 12_345)])

        let reached = GraphStore(context: context).neighbors(of: .artist("Skee Mask")).byDestination
        let byKind = Dictionary(grouping: reached, by: \.node.kind)

        XCTAssertEqual(byKind[.label]?.first?.node.title, "Ilian Tape")
        XCTAssertEqual(byKind[.release]?.first?.node.title, "Compro")
        XCTAssertEqual(byKind[.style]?.first?.node.title, "Techno")
        XCTAssertEqual(byKind[.release]?.first?.node.destination, .digRelease(id: 12_345, title: "Compro"))
    }

    func testALabelWalksOutToItsRosterCatalogueAndPressings() {
        artist("Skee Mask", labels: ["Ilian Tape"])
        release("Compro", id: 12_345, label: "Ilian Tape", catalog: "ITLP09")

        let reached = GraphStore(context: context).neighbors(of: .label("Ilian Tape")).byDestination
        XCTAssertTrue(reached.contains { $0.node.kind == .artist && $0.node.title == "Skee Mask" })
        XCTAssertTrue(reached.contains { $0.node.kind == .release && $0.node.title == "Compro" })
        XCTAssertTrue(reached.contains { $0.node.kind == .catalogNumber && $0.node.title == "ITLP09" })
    }

    /// A run of catalogue numbers is a label's spine. Reading along it is how
    /// a promo or a reissue gets stumbled upon rather than searched for.
    func testACatalogueNumberOffersItsNeighboursOnTheShelf() {
        release("Eight", id: 1, label: "Ilian Tape", catalog: "ITLP08")
        release("Nine", id: 2, label: "Ilian Tape", catalog: "ITLP09")
        release("Ten", id: 3, label: "Ilian Tape", catalog: "ITLP10")
        release("Far Away", id: 4, label: "Ilian Tape", catalog: "ITLP40")
        release("Another Label", id: 5, label: "Hyperdub", catalog: "HDB09")

        let reached = GraphStore(context: context).neighbors(of: .catalogNumber("ITLP09")).byDestination
        let titles = Set(reached.map(\.node.title))

        XCTAssertTrue(titles.contains("Nine"), "The record the number names")
        XCTAssertTrue(titles.isSuperset(of: ["Eight", "Ten"]), "Its neighbours in the run")
        XCTAssertFalse(titles.contains("Far Away"), "Thirty-one along is not a neighbour")
        XCTAssertFalse(titles.contains("Another Label"), "A different prefix is a different shelf")
    }

    /// White labels are the point. A show has to hand back the music nobody
    /// could name exactly as it hands back the music somebody could.
    func testABroadcastHandsBackTheMusicNobodyCouldName() throws {
        let named = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let unknown = try store.createUnknown(
            providerID: "nts", showID: "ben-ufo/2026-08-28",
            heardAt: Date(timeIntervalSince1970: 1_788_000_300), offsetSeconds: 330
        )
        for recording in [named, unknown] {
            store.note(appearance: MediaAppearance(
                providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
                showID: "ben-ufo/2026-08-28", heardAt: Date(timeIntervalSince1970: 1_788_000_000),
                offsetSeconds: 300, isLive: false, method: .providerTracklist
            ), on: recording)
        }

        let show = MusicNode.broadcast(providerID: "nts", showID: "ben-ufo/2026-08-28", title: "Ben UFO")
        let reached = GraphStore(context: context).neighbors(of: show).byDestination

        XCTAssertTrue(reached.contains { $0.node.recordingID == named.id })
        let white = try XCTUnwrap(reached.first { $0.node.recordingID == unknown.id })
        XCTAssertEqual(white.node.kind, .unknownRecording)
        XCTAssertTrue(white.node.isUnidentified)
    }

    /// A recording walks back to where it was heard, which is what makes a
    /// discovery navigable rather than merely recorded.
    func testARecordingWalksBackToTheShowThatPlayedIt() throws {
        let recording = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        store.note(appearance: MediaAppearance(
            providerID: "nts", stationName: "NTS 1", showTitle: "Ben UFO",
            showID: "ben-ufo/2026-08-28", heardAt: Date(), offsetSeconds: 300,
            isLive: false, method: .providerTracklist
        ), on: recording)

        let reached = GraphStore(context: context)
            .neighbors(of: .recording(recording)).byDestination
        let show = try XCTUnwrap(reached.first { $0.node.kind == .broadcast })
        XCTAssertEqual(show.node.destination, .ntsEpisode(show: "ben-ufo", episode: "2026-08-28"))
        XCTAssertTrue(reached.contains { $0.node.kind == .artist && $0.node.title == "Skee Mask" })
    }

    /// Sharing eleven broadcasts is a scene; sharing one is a coincidence.
    /// The list has to be able to tell them apart.
    func testRepeatedCoAppearanceOutranksASingleOne() throws {
        let subject = try store.upsert(title: "Rev8617", artistName: "Skee Mask")
        let close = try store.upsert(title: "Consumer's Tool", artistName: "Stenny")
        let distant = try store.upsert(title: "Only Once", artistName: "Passerby")

        func heard(_ recording: Recording, show: String) {
            store.note(appearance: MediaAppearance(
                providerID: "nts", showTitle: show, showID: show,
                heardAt: Date(), offsetSeconds: 100, isLive: false, method: .providerTracklist
            ), on: recording)
        }
        for index in 0..<6 {
            heard(subject, show: "show-\(index)")
            heard(close, show: "show-\(index)")
        }
        heard(distant, show: "show-0")

        let related = GraphStore(context: context).relatedArtists(to: .artist("Skee Mask"))
        let stenny = try XCTUnwrap(related.first { $0.node.title == "Stenny" })
        let passerby = try XCTUnwrap(related.first { $0.node.title == "Passerby" })

        XCTAssertGreaterThan(stenny.confidence, passerby.confidence)
        XCTAssertEqual(stenny.edges.first?.reason, "Played in 6 of the same shows")
        XCTAssertEqual(passerby.edges.first?.reason,
                       "Played in the same broadcast: show-0")
    }

    /// Nothing in the graph is allowed to be a bare assertion.
    func testEveryEdgeCarriesAReasonAndASource() {
        artist("Skee Mask", labels: ["Ilian Tape"], styles: ["Techno"], releases: [("Compro", 1)])
        artist("Stenny", labels: ["Ilian Tape"], styles: ["Techno"])

        let edges = GraphStore(context: context).neighbors(of: .artist("Skee Mask")).all
        XCTAssertFalse(edges.isEmpty)
        for edge in edges {
            XCTAssertFalse(edge.reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(edge.kind) reached \(edge.to.title) without saying why")
            XCTAssertGreaterThan(edge.confidence, 0)
            XCTAssertLessThanOrEqual(edge.weight, 1)
        }
    }
}
