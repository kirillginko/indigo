//
//  DigRouteMeasurement.swift
//  IndigoTests
//
//  Dead ends, measured: for every artist in the published catalogue sample
//  (the 300-artist pilot and the 3,000 of batch 1), the routes its page
//  offers from its bundle as DIG makes them today and musician-first.
//
//  Opt-in: set `INDIGO_DIG_MEASURE_DIR` (as `TEST_RUNNER_INDIGO_DIG_MEASURE_DIR`)
//  to a folder holding the bundles as `CataloguePilot` keeps them
//  (`manifest.json`, `<digest>.json`) and `pilot-ids.txt`/`batch1-ids.txt`.
//  Reads nothing else, writes `dig-route-measurement.txt` to the host's
//  temporary directory.
//
//  A meaningful route is a verified connection (by Discogs id) to another
//  musical artist -- a collaborator, a player, a writer or a producer, not a
//  labelmate and not somebody who only appears on the same compilation --
//  from whom there is somewhere further to go: at least one musician route
//  out of them to somebody else, as far as the sample's documents know.
//  That last part is a floor: the app also discovers routes live, which this
//  does not count.
//

import XCTest
import CryptoKit
@testable import Indigo

final class DigRouteMeasurement: XCTestCase {
    override func tearDown() { MusicianFirst.override = nil }

    private struct Manifest: Decodable {
        struct Entry: Decodable { let digest: String }
        let artists: [String: Entry]
    }

    /// One artist's routes to other artists, by Discogs id, with their kinds.
    private struct Routes {
        var byID: [Int: (name: String, kinds: Set<RelationshipKind>, weight: Double, reason: String)] = [:]
    }

    private static let musicianKinds: Set<RelationshipKind> = [.collaborator, .personnel, .producer]

    func testMeasureRoutesInTheCatalogueSample() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["INDIGO_DIG_MEASURE_DIR"] else {
            throw XCTSkip("Set INDIGO_DIG_MEASURE_DIR to the downloaded bundles.")
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        func ids(_ file: String) throws -> [Int] {
            try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").compactMap { Int($0) }.sorted()
        }
        let pilot = try ids("pilot-ids.txt"), batch1 = try ids("batch1-ids.txt")

        // Every bundle, read and checked.
        let readStarted = ContinuousClock.now
        var bundles: [Int: ArtistBundle] = [:]
        for (key, entry) in manifest.artists {
            guard let id = Int(key) else { continue }
            let data = try Data(contentsOf: dir.appendingPathComponent("\(entry.digest).json"))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.digest)
            bundles[id] = try JSONDecoder().decode(ArtistBundle.self, from: data)
        }
        let readTime = ContinuousClock.now - readStarted

        // Routes out of each artist, today's way and musician-first.
        func routes(musicianFirst: Bool) -> ([Int: Routes], Duration) {
            MusicianFirst.override = musicianFirst
            let started = ContinuousClock.now
            var out: [Int: Routes] = [:]
            for (id, bundle) in bundles {
                let origin = MusicNode.artist(bundle.artist.name, discogsID: id)
                var found = Routes()
                for edge in BundleEdges.edges(from: origin, bundle: bundle, ownIdentities: [id], sqlTargets: [])
                where edge.to.kind == .artist {
                    guard let to = edge.to.discogsID, !CataloguePilot.standIns.contains(to), to != id else { continue }
                    var held = found.byID[to] ?? (edge.to.title, [], 0, edge.reason)
                    held.kinds.insert(edge.kind)
                    if edge.weight > held.weight { held.weight = edge.weight; held.reason = edge.reason }
                    found.byID[to] = held
                }
                out[id] = found
            }
            return (out, ContinuousClock.now - started)
        }
        let (before, beforeTime) = routes(musicianFirst: false)
        let (after, afterTime) = routes(musicianFirst: true)

        // Who leads on, as far as the documents know: musician routes in
        // either direction, by id.
        func index(_ all: [Int: Routes]) -> [Int: Set<Int>] {
            var graph: [Int: Set<Int>] = [:]
            for (from, found) in all {
                for (to, route) in found.byID where !route.kinds.isDisjoint(with: Self.musicianKinds) {
                    graph[from, default: []].insert(to)
                    graph[to, default: []].insert(from)
                }
            }
            return graph
        }
        let beforeGraph = index(before), afterGraph = index(after)

        struct PageStats {
            var meaningful = 0, musician = 0, technical = 0, label = 0, coAppearance = 0, twoHop = 0
        }
        func stats(_ id: Int, _ all: [Int: Routes], _ graph: [Int: Set<Int>], technical: Set<Int>) -> PageStats {
            var page = PageStats()
            let found = all[id]?.byID ?? [:]
            for (to, route) in found {
                if !route.kinds.isDisjoint(with: Self.musicianKinds) {
                    page.musician += 1
                    if technical.contains(to) { page.technical += 1; continue }
                    if !(graph[to] ?? []).subtracting([id]).isEmpty { page.meaningful += 1 }
                } else if route.kinds.contains(.sameRelease) || route.kinds.contains(.appearsOnRelease) {
                    page.coAppearance += 1
                }
            }
            page.label = bundles[id]?.labels.filter { !$0.placeholder && !$0.ownName }.count ?? 0
            let first = graph[id] ?? []
            var reach = first
            for next in first { reach.formUnion(graph[next] ?? []) }
            reach.remove(id)
            page.twoHop = reach.count
            return page
        }

        func ordered(_ found: [Int: (name: String, kinds: Set<RelationshipKind>, weight: Double, reason: String)],
                     musicianFirst: Bool, graph: [Int: Set<Int>], from id: Int) -> [(Int, String, String)] {
            found.map { to, route -> (Int, String, String, Double) in
                let kind = route.kinds.sorted { $0.rawValue < $1.rawValue }.first ?? .sameRelease
                // Today: the page's lanes in their order (collaborators,
                // producers, remixers, personnel, same records), then evidence.
                let lane: [RelationshipKind: Double] = [.collaborator: 5, .producer: 4, .personnel: 3, .sameRelease: 2, .appearsOnRelease: 2]
                var value = (lane[kind] ?? 1) * 10 + route.weight
                if musicianFirst {
                    let edge = MusicEdge(from: .artist("x"), to: .artist(route.name), kind: kind, source: .discogs,
                                         reason: route.reason, confidence: 1, occurrences: 1)
                    value = route.weight * MusicianFirstRanker.worth(edge)
                        * MusicianFirstRanker.onwardFactor((graph[to] ?? []).subtracting([id]).count)
                }
                return (to, route.name, route.reason, value)
            }
            .sorted { $0.3 != $1.3 ? $0.3 > $1.3 : $0.1 < $1.1 }
            .map { ($0.0, $0.1, $0.2) }
        }
        var lines: [String] = []
        lines.append("DIG routes in the catalogue sample, \(bundles.count) bundles (manifest read \(readTime))")
        lines.append("routes built: today \(beforeTime), musician-first \(afterTime)")
        lines.append("A meaningful route: a verified musician (collaborator, player, writer, producer) with a musician route on to somebody else, as the sample's documents know it.")
        for (label, set) in [("pilot (300)", pilot), ("batch 1 (3,000)", batch1)] {
            var before0 = 0, before12 = 0, before3 = 0, after0 = 0, after12 = 0, after3 = 0
            var technicalOnly = 0, technicalMostly = 0, labelOnly = 0
            var reachBefore: [Int] = [], reachAfter: [Int] = []
            var crowdedTop = 0, technicalInTop = 0, deadEndsInTopBefore = 0, deadEndsInTopAfter = 0
            var technicalRoutes = 0, musicianRoutesBefore = 0
            for id in set where bundles[id] != nil {
                let technical = Set((before[id]?.byID.keys).map(Array.init) ?? [])
                    .subtracting((after[id]?.byID.keys).map(Array.init) ?? [])
                // One definition for both: onward through musicians only, and
                // a technical credit is never a meaningful route.
                var b = stats(id, before, afterGraph, technical: technical)
                b.twoHop = stats(id, before, beforeGraph, technical: technical).twoHop
                let a = stats(id, after, afterGraph, technical: [])
                switch b.meaningful { case 0: before0 += 1; case 1...2: before12 += 1; default: before3 += 1 }
                switch a.meaningful { case 0: after0 += 1; case 1...2: after12 += 1; default: after3 += 1 }
                if b.musician > 0 && b.technical == b.musician { technicalOnly += 1 }
                if b.musician > 0 && Double(b.technical) / Double(b.musician) > 0.5 { technicalMostly += 1 }
                if b.musician == 0 && b.coAppearance == 0 && b.label > 0 { labelOnly += 1 }
                reachBefore.append(b.twoHop); reachAfter.append(a.twoHop)
                technicalRoutes += b.technical; musicianRoutesBefore += b.musician
                // What the page shows first: today's lanes, musician-first's order.
                let topToday = ordered(before[id]?.byID ?? [:], musicianFirst: false, graph: afterGraph, from: id).prefix(5)
                let topNext = ordered(after[id]?.byID ?? [:], musicianFirst: true, graph: afterGraph, from: id).prefix(5)
                let technicalShown = topToday.filter { technical.contains($0.0) }.count
                technicalInTop += technicalShown
                if technicalShown >= 2 { crowdedTop += 1 }
                deadEndsInTopBefore += topToday.filter { (afterGraph[$0.0] ?? []).subtracting([id]).isEmpty }.count
                deadEndsInTopAfter += topNext.filter { (afterGraph[$0.0] ?? []).subtracting([id]).isEmpty }.count
            }
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            func mean(_ values: [Int]) -> String { String(format: "%.1f", Double(values.reduce(0, +)) / Double(max(1, values.count))) }
            lines.append("")
            lines.append("== \(label): \(set.filter { bundles[$0] != nil }.count) pages")
            lines.append("meaningful musician routes   today: 0 → \(before0), 1–2 → \(before12), 3+ → \(before3)")
            lines.append("                       musician-first: 0 → \(after0), 1–2 → \(after12), 3+ → \(after3)")
            lines.append("pages whose musician routes are all technical (today): \(technicalOnly); more than half technical: \(technicalMostly)")
            lines.append("technical routes removed: \(technicalRoutes) of \(musicianRoutesBefore) musician routes today")
            lines.append("pages with only label routes: \(labelOnly)")
            lines.append("first five routes shown: technical credits today \(technicalInTop) (pages with 2+: \(crowdedTop)), musician-first 0")
            lines.append("first five routes shown that lead nowhere further: today \(deadEndsInTopBefore), musician-first \(deadEndsInTopAfter)")
            lines.append("two-hop reach (today through every route offered; musician-first through musicians only)  today: median \(median(reachBefore)), mean \(mean(reachBefore)); musician-first: median \(median(reachAfter)), mean \(mean(reachAfter))")
        }

        // Journeys: the first five routes out of a representative artist in
        // each family, today's order (by evidence) beside musician-first's
        // (worth × evidence × onward), and one two-hop walk.
        func family(_ bundle: ArtistBundle) -> String? {
            let tags = Set((bundle.genres + bundle.styles).map { $0.name.lowercased() })
            if !tags.isDisjoint(with: ["free jazz", "hard bop", "post bop", "contemporary jazz", "modal", "free improvisation", "avant-garde jazz"]) { return "jazz" }
            if !tags.isDisjoint(with: ["hip hop", "boom bap", "conscious", "instrumental"]) && tags.contains("hip hop") { return "hip-hop" }
            if !tags.isDisjoint(with: ["experimental", "idm", "noise", "drone", "musique concrète", "abstract"]) && tags.contains("electronic") { return "experimental electronic" }
            if !tags.isDisjoint(with: ["indie rock", "indie pop", "lo-fi", "shoegaze", "post-punk"]) { return "indie" }
            return nil
        }
        var names: [Int: String] = [:]
        for (id, bundle) in bundles { names[id] = bundle.artist.name }
        for found in after.values { for (to, route) in found.byID where names[to] == nil { names[to] = route.name } }
        var shown: [String: Int] = [:]
        lines.append("")
        lines.append("== journeys")
        for id in (pilot + batch1).sorted() {
            guard let bundle = bundles[id], let kind = family(bundle), shown[kind, default: 0] < 2,
                  let b = before[id], b.byID.count >= 3,
                  b.byID.count != after[id]?.byID.count || kind == "jazz" else { continue }
            shown[kind, default: 0] += 1
            let today = ordered(b.byID, musicianFirst: false, graph: beforeGraph, from: id).prefix(5)
            let next = ordered(after[id]?.byID ?? [:], musicianFirst: true, graph: afterGraph, from: id).prefix(5)
            lines.append("")
            lines.append("\(bundle.artist.name) [\(id)] — \(kind)")
            lines.append("  today:          " + today.map { "\($0.1) (\($0.2))" }.joined(separator: "; "))
            lines.append("  musician-first: " + next.map { "\($0.1) (\($0.2))" }.joined(separator: "; "))
            if let hop = next.first(where: { !(afterGraph[$0.0] ?? []).subtracting([id]).isEmpty }),
               let onward = (afterGraph[hop.0] ?? []).subtracting([id]).sorted().first {
                lines.append("  two hops:       \(bundle.artist.name) → \(hop.1) → \(names[onward] ?? String(onward))")
            }
        }

        let body = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.components(separatedBy: "\n").filter { !$0.hasPrefix("DIG routes") && !$0.hasPrefix("routes built") }.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dig-route-measurement.txt")
        try (body + "\n\ncontent digest (timings excluded): \(digest)\n").write(to: url, atomically: true, encoding: .utf8)
        print("DIG-ROUTE-MEASUREMENT \(url.path) \(digest)")
    }
}
