//
//  ExploreDeterminismTests.swift
//  IndigoTests
//
//  The same rows give the same For You, whatever order they reached the store
//  in and however many times it is asked.
//
//  Two devices holding identical data did not get identical suggestions. The
//  walk inserts edges out of dictionaries, whose order Swift seeds per process;
//  every tie -- two wordings of one edge, two equally good routes, two
//  suggestions of one score and one name, two spellings of one node -- was
//  settled by arrival, and the store hands rows back in the order it filed
//  them. These tests file the same collection in many orders, into fresh stores
//  on disk, and require the ranked answer to be identical to the last bit.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ExploreDeterminismTests: XCTestCase {
    /// A fixed evaluation moment: the answer must not read the clock.
    private static let asOf = Date(timeIntervalSince1970: 1_790_000_000)
    private static let base = asOf.addingTimeInterval(-30 * 24 * 60 * 60)

    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    // MARK: A seeded shuffle

    /// SplitMix64: the same seed is the same order, so a failure can be run
    /// again.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: The collection

    /// Everything one listener has and one device has cached, as separate
    /// writes so they can be made in any order. Built with ties on purpose:
    /// artists sharing labels and styles at equal weight, crate records and
    /// plays at the same moment, two haunts returned to equally, and show
    /// appearances that disagree about the show's name and picture.
    private func fixture() -> [(ModelContext) -> Void] {
        var writes: [(ModelContext) -> Void] = []

        let artists: [(String, Int, [String], [String], [String], [String])] = [
            ("Dean Blunt", 1, ["World Music", "Hippos In Tanks"], ["Experimental", "Lo-Fi"], ["2012", "2014"], ["Inga Copeland", "Mica Levi"]),
            ("Inga Copeland", 2, ["World Music", "Hyperdub"], ["Experimental", "Ambient"], ["2013"], []),
            ("Mica Levi", 3, ["Hippos In Tanks"], ["Experimental"], ["2014"], []),
            ("Tirzah", 4, ["Domino"], ["Lo-Fi", "Ambient"], ["2018"], ["Mica Levi"]),
            ("Klein", 5, ["Hyperdub"], ["Ambient", "Experimental"], ["2019"], []),
            ("Laurel Halo", 6, ["Hyperdub", "Latency"], ["Ambient", "Techno"], ["2013", "2017"], []),
            ("Kode9", 7, ["Hyperdub"], ["Dubstep"], ["2006"], []),
            ("Burial", 8, ["Hyperdub"], ["Dubstep", "Ambient"], ["2007"], []),
            ("Actress", 9, ["Werkdiscs", "Ninja Tune"], ["Techno", "Experimental"], ["2010"], []),
            ("Lee Gamble", 10, ["Hyperdub", "PAN"], ["Techno", "Experimental"], ["2014"], []),
            ("Jlin", 11, ["Planet Mu"], ["Footwork", "Experimental"], ["2015"], []),
            ("Rian Treanor", 12, ["Planet Mu"], ["Footwork", "Experimental"], ["2017"], []),
            ("Visionist", 13, ["PAN", "Lit City Trax"], ["Grime", "Experimental"], ["2015"], []),
            ("Huerco S.", 14, ["Proibito", "Latency"], ["Ambient", "Techno"], ["2016"], []),
        ]
        for (name, id, labels, styles, years, collaborators) in artists {
            writes.append { context in
                let record = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(name), discogsID: id, name: name)
                record.labelNames = labels
                record.styles = styles
                record.genres = ["Electronic"]
                record.releaseYears = years
                record.collaboratorNames = collaborators
                context.insert(record)
            }
        }

        // Two kept at the same moment.
        for (name, offset) in [("Dean Blunt", 0.0), ("Laurel Halo", 0.0), ("Jlin", 60.0)] {
            writes.append { context in
                let item = CrateItem(
                    digKind: .artist, providerID: "dig.artist.name",
                    entityID: RecordingKey.normalizeArtist(name), title: name,
                    subtitle: "Artist", artworkURL: nil
                )
                item.addedAt = Self.base.addingTimeInterval(offset)
                context.insert(item)
            }
        }

        // Plays, two at the same moment. The ids are fixed because they are
        // what an event carries between devices.
        let plays: [(String, Double, [String], String)] = [
            ("Actress", 3_600, ["techno", "experimental"], "00000000-0000-0000-0000-000000000001"),
            ("Burial", 3_600, ["dubstep", "ambient"], "00000000-0000-0000-0000-000000000002"),
            ("Burial", 7_200, ["dubstep"], "00000000-0000-0000-0000-000000000003"),
            ("Huerco S.", 86_400, ["ambient"], "00000000-0000-0000-0000-000000000004"),
        ]
        for (name, offset, tags, id) in plays {
            writes.append { context in
                let event = ListeningEvent(
                    node: .artist(name), action: .played, at: Self.base.addingTimeInterval(offset),
                    seconds: 1_200, completion: 0.9, tags: tags, source: nil
                )
                event.id = UUID(uuidString: id)!
                context.insert(event)
            }
        }

        // Two places returned to equally, at the same moment.
        for node in [MusicNode.label("Hyperdub"), MusicNode.artist("Visionist")] {
            writes.append { context in
                let visit = DigVisit(node: node)
                visit.visits = 3
                visit.lastVisitedAt = Self.base.addingTimeInterval(120)
                context.insert(visit)
            }
        }

        // Shows whose appearances disagree about name and picture.
        let shows: [(String, [String?], [String])] = [
            ("hdb", ["Hyperdub Radio", nil, "Hyperdub Radio w/ Kode9"], ["Burial", "Kode9", "Laurel Halo", "Klein"]),
            ("lat", [nil, "Latency Hour"], ["Huerco S.", "Laurel Halo", "Dean Blunt"]),
            ("mu", ["Planet Mu Show"], ["Jlin", "Rian Treanor", "Visionist"]),
        ]
        for (slug, titles, played) in shows {
            for (index, name) in played.enumerated() {
                writes.append { context in
                    let recording = try? RecordingStore(context: context).upsert(title: "\(name) track", artistName: name)
                    let appearance = MediaAppearance(
                        providerID: "nts", showTitle: titles[index % titles.count],
                        showID: "\(slug)/\(slug)-episode",
                        artworkURL: URL(string: "https://media.example/\(slug)/\(index).jpg"),
                        heardAt: Self.base, isLive: false, method: .providerTracklist
                    )
                    context.insert(appearance)
                    appearance.recording = recording
                }
            }
        }
        return writes
    }

    /// A fresh store on disk with the collection written in a shuffled order,
    /// saved at shuffled points, so the rows are filed differently each time.
    private func store(seed: UInt64) throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreDeterminism-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        var generator = SeededGenerator(state: seed)
        for write in fixture().shuffled(using: &generator) {
            write(context)
            if Int.random(in: 0..<4, using: &generator) == 0 { try context.save() }
        }
        try context.save()
        return container
    }

    /// The answer, written out in full: every field the page draws or ranks
    /// on, scores to the bit.
    private func answer(_ container: ModelContainer) -> [String] {
        let offers = ExploreSuggestionEngine(context: ModelContext(container)).offers(asOf: Self.asOf)
        func line(_ block: String, _ suggestion: ExploreSuggestion) -> String {
            let node = suggestion.node
            return [block, suggestion.id, node.title, suggestion.reason, suggestion.via,
                    suggestion.kind.rawValue, String(suggestion.corroboration),
                    String(suggestion.score.bitPattern), node.artworkURL?.absoluteString ?? "-",
                    node.mbid ?? "-", node.discogsID.map { String($0) } ?? "-", node.handle ?? "-"]
                .joined(separator: " | ")
        }
        return offers.next.map { line("next", $0) }
            + offers.shows.map { line("show", $0) }
            + offers.artists.map { line("artist", $0) }
            + [offers.movingToward.map { "toward | \($0.city) | \($0.sound) | \($0.size)" } ?? "toward | -"]
    }

    // MARK: The guarantee

    func testTheSameCollectionFiledInAnyOrderGivesTheSameRankedOffers() throws {
        let first = answer(try store(seed: 1))
        // Swift seeds dictionary order per process, which one run cannot vary.
        // Given a file name, the answer is written to it in the test host's
        // temporary directory (the host is sandboxed), so separate runs -- and
        // a Mac and an iOS simulator -- can be compared byte for byte.
        if let name = ProcessInfo.processInfo.environment["INDIGO_EXPLORE_ANSWER_OUT"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try first.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(first.contains { $0.hasPrefix("next |") }, "a fixture that offers nothing proves nothing")
        XCTAssertTrue(first.contains { $0.hasPrefix("show |") }, "the shows' path must be exercised too")
        for seed in UInt64(2)...16 {
            let other = answer(try store(seed: seed))
            XCTAssertEqual(other, first, "filing order \(seed) changed the answer")
            if other != first { break }
        }
    }

    /// Asked again and again of one store: the first walk works neighbours
    /// out and keeps them, the later ones read what was kept. Both must give
    /// the same answer.
    func testAskingAgainGivesTheSameAnswer() throws {
        let container = try store(seed: 42)
        let first = answer(container)
        for _ in 0..<4 { XCTAssertEqual(answer(container), first) }
    }

    // MARK: The pieces

    private func edge(
        to node: MusicNode, _ reason: String, kind: RelationshipKind = .sharedLabel,
        confidence: Double, source: RelationshipSource = .discogs
    ) -> MusicEdge {
        MusicEdge(from: .artist("Dean Blunt"), to: node, kind: kind, source: source,
                  reason: reason, confidence: confidence)
    }

    /// Two wordings of one edge at equal weight, the same wording with and
    /// without a picture or an MBID, and a weaker wording repeated until it
    /// outweighs a stronger one. Each was settled by arrival.
    func testAnEdgeSetIsTheSameWhateverOrderItsEdgesArrive() {
        var pictured = MusicNode.artist("Inga Copeland")
        pictured.artworkURL = URL(string: "https://img.example/inga.jpg")
        let identified = MusicNode.artist("Inga Copeland", mbid: "mbid-inga")
        let edges = [
            edge(to: .artist("Inga Copeland"), "Releases on World Music", confidence: 0.7),
            edge(to: pictured, "Releases on World Music", confidence: 0.7),
            edge(to: identified, "Also on Hyperdub", confidence: 0.7, source: .musicBrainz),
            edge(to: .artist("Mica Levi"), "Also on Hippos In Tanks", confidence: 0.7),
            edge(to: .artist("Mica Levi"), "Same label: Hippos In Tanks", confidence: 0.6),
            edge(to: .artist("Mica Levi"), "Same label: Hippos In Tanks", confidence: 0.6),
            edge(to: .artist("Mica Levi"), "Same label: Hippos In Tanks", confidence: 0.6),
            edge(to: .artist("Mica Levi"), "Credited together", kind: .collaborator, confidence: 0.85),
            edge(to: .artist("Tirzah"), "Shared sound: Lo-Fi", kind: .sharedStyle, confidence: 0.58),
            edge(to: .artist("Tirzah"), "Shared sound: Ambient", kind: .sharedStyle, confidence: 0.58),
        ]
        func written(_ set: EdgeSet) -> [String] {
            set.all.map { "\($0.id) \($0.reason) \($0.source.rawValue) \($0.occurrences) \($0.confidence) \($0.to.artworkURL?.absoluteString ?? "-") \($0.to.mbid ?? "-")" }
                + set.byDestination.map { "\($0.node.id) \($0.node.artworkURL?.absoluteString ?? "-") \($0.node.mbid ?? "-") \($0.confidence.bitPattern) \($0.edges.map(\.reason))" }
        }
        var reference = EdgeSet()
        reference.insert(contentsOf: edges)
        let expected = written(reference)

        var generator = SeededGenerator(state: 7)
        for _ in 0..<300 {
            var set = EdgeSet()
            set.insert(contentsOf: edges.shuffled(using: &generator))
            XCTAssertEqual(written(set), expected)
        }

        // And the ties went to content. The repeated wording counted every
        // sighting (0.6 seen three times is 0.706) -- it used to lose the ones
        // that arrived after a stronger wording had taken its place. Inga's
        // edge is the wording seen twice, drawn with the spelling that has a
        // picture.
        let mica = reference.edges.values.first { $0.to.title == "Mica Levi" && $0.kind == .sharedLabel }
        XCTAssertEqual(mica?.reason, "Same label: Hippos In Tanks", "three sightings outweigh one stronger one")
        XCTAssertEqual(mica?.occurrences, 3)
        let inga = reference.byDestination.first { $0.node.title == "Inga Copeland" }
        XCTAssertEqual(inga?.edges.first?.reason, "Releases on World Music")
        XCTAssertEqual(inga?.node.artworkURL, pictured.artworkURL)
    }

    func testTheEvaluationPeriodIsTheUTCDay() {
        let morning = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 86_400) + 60)
        let evening = morning.addingTimeInterval(23 * 60 * 60)
        let tomorrow = morning.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(ExplorePeriod.containing(morning), ExplorePeriod.containing(evening))
        XCTAssertNotEqual(ExplorePeriod.containing(morning), ExplorePeriod.containing(tomorrow))

        // `asOf` is the end of the day, so nothing played in it is in its
        // future, and it is the same however late in the day it is asked.
        XCTAssertEqual(ExplorePeriod.asOf(ExplorePeriod.containing(morning)), morning.addingTimeInterval(24 * 60 * 60 - 60))
        XCTAssertEqual(ExplorePeriod.asOf(ExplorePeriod.containing(evening)), ExplorePeriod.asOf(ExplorePeriod.containing(morning)))

        // And the day is part of the stamp, so a new one is a new answer.
        let one = ExploreStamp(period: ExplorePeriod.containing(morning), personal: .empty, knowledge: .empty)
        let two = ExploreStamp(period: ExplorePeriod.containing(tomorrow), personal: .empty, knowledge: .empty)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one.personal, two.personal)
    }

    /// Plays are weighed from `asOf`, not from the moment of asking.
    func testTasteIsWeighedFromAsOf() throws {
        let container = try store(seed: 3)
        let one = TasteProfile.collected(context: ModelContext(container), now: Self.asOf)
        let two = TasteProfile.collected(context: ModelContext(container), now: Self.asOf)
        XCTAssertEqual(one.top(20).map { "\($0.interest)=\($0.weight.bitPattern)" },
                       two.top(20).map { "\($0.interest)=\($0.weight.bitPattern)" })
        let later = TasteProfile.collected(context: ModelContext(container), now: Self.asOf.addingTimeInterval(90 * 24 * 60 * 60))
        XCTAssertNotEqual(one.top(20).map(\.weight), later.top(20).map(\.weight),
                          "moving asOf moves the weights: it is the only clock in here")
    }
    // MARK: Where they are heading

    /// Scenes with a foot in the crate, three of them scoring exactly alike:
    /// one artist kept in each, each kept artist sounding like their city,
    /// every city the same size. Which comes first, and so which is named on
    /// a given day, is then settled by the tie-break alone.
    private func sceneFixture() -> [(ModelContext) -> Void] {
        var writes: [(ModelContext) -> Void] = []
        let places: [(String, String, Int)] = [
            ("Cologne", "Kosmische", 6), ("Rome", "Library Music", 6),
            ("Bristol", "Trip Hop", 6), ("Detroit", "Electro", 9),
        ]
        var discogsID = 500
        for (city, sound, size) in places {
            for index in 0..<size {
                let name = "\(city) \(index)"
                writes.append { context in
                    let record = Artist(mbid: "mbid-\(name)", name: name)
                    record.origin = city
                    context.insert(record)
                    let release = BandcampRelease(
                        urlString: "https://\(name.filter { !$0.isWhitespace }).bandcamp.com/album/x",
                        title: "\(name) album", artistName: name
                    )
                    release.keywords = [sound, "Ambient", "Experimental"]
                    context.insert(release)
                }
            }
            // One kept from each, with the city's sound in the catalogue.
            discogsID += 1
            let kept = "\(city) 0"
            let id = discogsID
            writes.append { context in
                let item = CrateItem(
                    digKind: .artist, providerID: "dig.artist.name",
                    entityID: RecordingKey.normalizeArtist(kept), title: kept,
                    subtitle: "Artist", artworkURL: nil
                )
                item.addedAt = Self.base
                context.insert(item)
                let discogs = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(kept), discogsID: id, name: kept)
                discogs.styles = [sound]
                context.insert(discogs)
            }
        }
        return writes
    }

    private func sceneStore(seed: UInt64) throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreDeterminism-scenes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        var generator = SeededGenerator(state: seed)
        for write in sceneFixture().shuffled(using: &generator) {
            write(context)
            if Int.random(in: 0..<4, using: &generator) == 0 { try context.save() }
        }
        try context.save()
        return container
    }

    /// Every direction in order, all of what each says, and which one each
    /// of a week of days names -- the selection EXPLORE makes.
    private func directions(_ container: ModelContainer) -> [String] {
        let context = ModelContext(container)
        let found = SceneEngine(context: context)
            .directions(taste: TasteProfile.collected(context: context, now: Self.asOf))
        let described = found.map { scene in
            [scene.id, scene.city, scene.title, scene.soundLabel, scene.sizeLine,
             scene.signature.joined(separator: ","), scene.tags.joined(separator: ","),
             scene.artists.joined(separator: ","), scene.labels.joined(separator: ","),
             "\(scene.crateCount)/\(scene.libraryTrackCount)/\(scene.radioAppearances)"]
                .joined(separator: " | ")
        }
        let period = ExplorePeriod.containing(Self.asOf)
        let picked = (period..<(period + 7)).map {
            "day \($0 - period): " + (SceneEngine.pickDirection(found, turn: $0)?.id ?? "-")
        }
        return described + picked
    }

    /// The city a described direction is in: its id is `city|sound`.
    private func cityKey(_ line: String) -> String {
        String(line.prefix { $0 != "|" }).trimmingCharacters(in: .whitespaces)
    }

    func testTheDirectionNamedIsTheSameWhateverOrderTheCollectionWasFiledIn() throws {
        let first = directions(try sceneStore(seed: 1))
        let scenes = first.filter { !$0.hasPrefix("day ") }
        let days = first.filter { $0.hasPrefix("day ") }
        XCTAssertGreaterThanOrEqual(scenes.count, 3, "the tie has to be there to be settled")
        XCTAssertEqual(Set(days.map { $0.split(separator: " ").last! }).count, scenes.count,
                       "a week of days walks through every direction")
        // The three that tie come out in order of id, not of filing.
        let tied = scenes.map(cityKey).filter { ["bristol", "cologne", "rome"].contains($0) }
        XCTAssertEqual(tied.count, 3)
        XCTAssertEqual(tied, tied.sorted())

        for seed in UInt64(2)...12 {
            let other = directions(try sceneStore(seed: seed))
            XCTAssertEqual(other, first, "filing order \(seed) changed the directions")
            if other != first { break }
        }

        // And the page's own path names the first of them.
        let offer = ExploreSuggestionEngine(context: ModelContext(try sceneStore(seed: 99))).direction(asOf: Self.asOf)
        XCTAssertEqual(offer.map { RecordingKey.normalize($0.city) }, scenes.first.map(cityKey))
    }
}
