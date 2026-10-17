//
//  ListenerProfileTests.swift
//  IndigoTests
//
//  Listener Profile v2: intent outweighs browsing, a skip is no argument,
//  aliases fold, distinct tastes stay apart, a rising one is seen, and the
//  same rows give the same profile in any order.
//

import XCTest
@testable import Indigo

final class ListenerProfileTests: XCTestCase {
    private let vectors: [String: [String: Double]] = [
        "ambient": ["ambient": 0.8, "drone": 0.6], "drone": ["drone": 0.8, "ambient": 0.6],
        "techno": ["techno": 0.8, "house": 0.6], "house": ["house": 0.8, "techno": 0.6],
        "free jazz": ["free jazz": 0.9, "modal": 0.4], "modal": ["modal": 0.9, "free jazz": 0.4],
    ]
    private let asOf = Date(timeIntervalSince1970: 1_800_000_000)

    private func days(_ n: Double) -> Date { asOf.addingTimeInterval(-n * 86_400) }

    private func evidence(_ artist: String, _ signal: ListenerProfile.Signal, daysAgo: Double = 30, title: String = "T",
                          level: ListenerProfile.Level = .recording, tags: [String] = []) -> ListenerProfile.Evidence {
        let unit = level == .artist ? "artist:\(artist)" : "\(level.rawValue):\(title)|\(artist)"
        return ListenerProfile.Evidence(unit: unit, level: level, artist: artist, title: title, at: days(daysAgo), signal: signal, tags: tags)
    }

    private func build(_ evidence: [ListenerProfile.Evidence], artistStyles: [String: [String]]) -> ListenerProfile {
        ListenerProfile.build(evidence: evidence, styles: [:], artistStyles: artistStyles, vectors: vectors, asOf: asOf)
    }

    func testIntentOutweighsBrowsing() {
        let profile = build([evidence("a", .crated), evidence("b", .fullListen), evidence("c", .partialListen), evidence("d", .pageVisit, level: .artist)],
                            artistStyles: ["a": ["ambient"], "b": ["ambient"], "c": ["ambient"], "d": ["ambient"]])
        let weight = Dictionary(uniqueKeysWithValues: profile.units.map { ($0.artist, $0.longTerm) })
        XCTAssertGreaterThan(weight["a"]!, weight["b"]!)
        XCTAssertGreaterThan(weight["b"]!, weight["c"]!)
        XCTAssertGreaterThan(weight["c"]!, weight["d"]!)
    }

    /// A skip is counted, never subtracted; only a dismissal argues against.
    func testASkipIsNoArgumentADismissalIs() {
        let profile = build([evidence("a", .fullListen), evidence("a", .skipped), evidence("a", .skipped), evidence("b", .dismissed)],
                            artistStyles: ["a": ["ambient"], "b": ["techno"]])
        let a = profile.units.first { $0.artist == "a" }!, b = profile.units.first { $0.artist == "b" }!
        XCTAssertEqual(a.longTerm, log2(2), accuracy: 1e-9)
        XCTAssertEqual(a.skips, 2)
        XCTAssertLessThan(b.longTerm, 0)
        XCTAssertEqual(profile.skips, 2)
        XCTAssertEqual(profile.dismissals, 1)
        XCTAssertFalse(profile.clusters.contains { $0.label.contains("techno") }, "dismissed is not a taste")
    }

    /// One person, two projects: each keeps its own weight and sound.
    func testAnAliasStaysItsOwnProject() {
        let profile = build([evidence("alias", .fullListen, level: .artist), evidence("main", .fullListen, level: .artist)],
                            artistStyles: ["main": ["ambient"], "alias": ["techno"]])
        XCTAssertEqual(profile.units.map(\.id).sorted(), ["artist:alias", "artist:main"])
    }

    func testDistinctTastesStayApartAndCarryTheirShares() {
        var items: [ListenerProfile.Evidence] = []
        for i in 0..<6 { items.append(evidence("amb\(i)", .crated, title: "A\(i)")) }
        for i in 0..<3 { items.append(evidence("tek\(i)", .crated, title: "K\(i)")) }
        var styles: [String: [String]] = [:]
        for i in 0..<6 { styles["amb\(i)"] = ["ambient"] }
        for i in 0..<3 { styles["tek\(i)"] = ["techno"] }
        let profile = build(items, artistStyles: styles)
        XCTAssertEqual(profile.clusters.count, 2)
        XCTAssertEqual(profile.clusters[0].label.first, "ambient")
        XCTAssertEqual(profile.clusters[1].label.first, "techno")
        XCTAssertEqual(profile.clusters[0].longTermShare, 6.0 / 9, accuracy: 1e-9)
        // Relevance picks the right cluster.
        XCTAssertEqual(profile.relevance(styles: ["house"], vectors: vectors)?.cluster, 1)
        XCTAssertEqual(profile.relevance(styles: ["drone"], vectors: vectors)?.cluster, 0)
        XCTAssertNil(profile.relevance(styles: ["talk"], vectors: vectors), "a style the space does not know is no evidence")
    }

    func testARisingTasteIsEmerging() {
        var items: [ListenerProfile.Evidence] = []
        for i in 0..<10 { items.append(evidence("amb\(i)", .crated, daysAgo: 60, title: "A\(i)")) }
        for i in 0..<3 { items.append(evidence("jaz\(i)", .fullListen, daysAgo: 2, title: "J\(i)")) }
        var styles: [String: [String]] = [:]
        for i in 0..<10 { styles["amb\(i)"] = ["ambient"] }
        for i in 0..<3 { styles["jaz\(i)"] = ["free jazz"] }
        let profile = build(items, artistStyles: styles)
        XCTAssertEqual(profile.emerging, ["free jazz"])
        XCTAssertTrue(profile.clusters.first { $0.label.first == "free jazz" }?.emerging ?? false)
        XCTAssertFalse(profile.clusters.first { $0.label.first == "ambient" }?.emerging ?? true)
    }

    /// Only tags the style space knows place a unit; a station's "talk" does not.
    func testOnlyKnownTagsPlaceAUnit() {
        let profile = build([evidence("x", .fullListen, tags: ["talk"]), evidence("y", .fullListen, tags: ["talk", "drone"])], artistStyles: [:])
        XCTAssertEqual(profile.units.first { $0.artist == "x" }?.styleSource, "none")
        XCTAssertEqual(profile.units.first { $0.artist == "y" }?.styles, ["drone"])
    }

    func testTheSameRowsInAnyOrderGiveTheSameProfile() {
        var items: [ListenerProfile.Evidence] = []
        for i in 0..<8 { items.append(evidence("a\(i)", i % 2 == 0 ? .crated : .fullListen, daysAgo: Double(i * 3), title: "T\(i)")) }
        let styles = Dictionary(uniqueKeysWithValues: (0..<8).map { ("a\($0)", [["ambient"], ["techno"], ["modal"], ["drone"]][$0 % 4]) })
        XCTAssertEqual(build(items, artistStyles: styles), build(items.reversed(), artistStyles: styles))
    }

    /// Slots go round the clusters, so the larger taste cannot take them all.
    func testSpreadGivesEachClusterSlots() {
        var items: [ListenerProfile.Evidence] = []
        for i in 0..<6 { items.append(evidence("amb\(i)", .crated, title: "A\(i)")) }
        for i in 0..<3 { items.append(evidence("tek\(i)", .crated, title: "K\(i)")) }
        var styles: [String: [String]] = [:]
        for i in 0..<6 { styles["amb\(i)"] = ["ambient"] }
        for i in 0..<3 { styles["tek\(i)"] = ["techno"] }
        let profile = build(items, artistStyles: styles)
        let ranked = ["d1", "d2", "d3", "d4", "d5", "h1", "h2"]
        let tag = { (s: String) in s.hasPrefix("d") ? ["drone"] : ["house"] }
        let spread = profile.spread(ranked, limit: 4, styles: tag, vectors: vectors)
        XCTAssertEqual(spread.count, 4)
        XCTAssertTrue(spread.contains("h1"))
        XCTAssertEqual(spread.filter { $0.hasPrefix("d") }, ["d1", "d2", "d3"], "within a cluster, the list's order holds")
    }

    /// A length that could not have been heard is read by its completion;
    /// an ordinary one is read as before.
    func testAnImplausibleLengthIsReadByItsCompletion() {
        XCTAssertEqual(ListenerProfile.plausibleWeight(seconds: 22_010, completion: 0.134), 0.134, accuracy: 1e-9,
                       "the overnight row: 45 hours long by its own numbers")
        XCTAssertEqual(ListenerProfile.plausibleWeight(seconds: 5 * 3600, completion: 0), 0, "five hours with no playhead: nothing")
        XCTAssertEqual(ListenerProfile.plausibleWeight(seconds: 600, completion: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ListenerProfile.plausibleWeight(seconds: 2400, completion: 0), 1, accuracy: 1e-9, "a long radio mix is still a full listen")
        XCTAssertEqual(ListenerProfile.plausibleWeight(seconds: 10, completion: 0), 0)
    }
}
