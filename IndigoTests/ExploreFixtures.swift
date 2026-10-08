//
//  ExploreFixtures.swift
//  IndigoTests
//
//  Collections For You is tested against, as separate writes so they can be
//  filed in any order, and the stores they are filed into.
//
//  Three of them. `walk`: artists, labels, plays, haunts and tracklists, full of
//  ties. `scenes`: places with a foot in the crate, three scoring alike.
//  `library`: the walk plus a music library, so the suggestions and the scenes
//  that only a library reaches are in it -- the knowledge that stays on the
//  device that has the files.
//

import Foundation
import SwiftData
@testable import Indigo

@MainActor
enum ExploreFixtures {
    /// A fixed evaluation moment: the answer must not read the clock.
    static let asOf = Date(timeIntervalSince1970: 1_790_000_000)
    static let base = asOf.addingTimeInterval(-30 * 24 * 60 * 60)

    typealias Write = (ModelContext) -> Void

    // MARK: A seeded shuffle

    /// SplitMix64: the same seed is the same order, so a failure can be run
    /// again.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A fresh store on disk with a collection written in a shuffled order,
    /// saved at shuffled points, so the rows are filed differently each time.
    /// The directory is added to `directories` for the caller to remove.
    static func store(_ writes: [Write], seed: UInt64, directories: inout [URL]) throws -> ModelContainer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let container = try Persistence.makeSplitContainer(
            userData: directory.appendingPathComponent("UserData.store"),
            local: directory.appendingPathComponent("Local.store"))
        let context = ModelContext(container)
        var generator = SeededGenerator(state: seed)
        for write in writes.shuffled(using: &generator) {
            write(context)
            if Int.random(in: 0..<4, using: &generator) == 0 { try context.save() }
        }
        try context.save()
        return container
    }

    // MARK: The walk

    /// Everything one listener has and one device has cached. Built with ties
    /// on purpose: artists sharing labels and styles at equal weight, crate
    /// records and plays at the same moment, two haunts returned to equally,
    /// and show appearances that disagree about the show's name and picture.
    static func walk() -> [Write] {
        var writes: [Write] = []

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
                item.addedAt = base.addingTimeInterval(offset)
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
                    node: .artist(name), action: .played, at: base.addingTimeInterval(offset),
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
                visit.lastVisitedAt = base.addingTimeInterval(120)
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
                        heardAt: base, isLive: false, method: .providerTracklist
                    )
                    context.insert(appearance)
                    appearance.recording = recording
                }
            }
        }
        return writes
    }

    // MARK: Scenes

    /// Scenes with a foot in the crate, three of them scoring exactly alike:
    /// one artist kept in each, each kept artist sounding like their city,
    /// every city the same size. Which comes first, and so which is named on
    /// a given day, is then settled by the tie-break alone.
    static func scenes() -> [Write] {
        var writes: [Write] = []
        let places: [(String, String, Int)] = [
            ("Cologne", "Kosmische", 6), ("Rome", "Library Music", 6),
            ("Bristol", "Trip Hop", 6), ("Detroit", "Electro", 9),
        ]
        var discogsID = 500
        for (city, sound, size) in places {
            for index in 0..<size {
                writes.append(placedArtist("\(city) \(index)", in: city, keywords: [sound, "Ambient", "Experimental"]))
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
                item.addedAt = base
                context.insert(item)
                let discogs = DiscogsArtist(nameKey: RecordingKey.normalizeArtist(kept), discogsID: id, name: kept)
                discogs.styles = [sound]
                context.insert(discogs)
            }
        }
        return writes
    }

    /// An artist from somewhere, with a Bandcamp record carrying keywords.
    static func placedArtist(_ name: String, in city: String, keywords: [String]) -> Write {
        { context in
            let record = Artist(mbid: "mbid-\(name)", name: name)
            record.origin = city
            context.insert(record)
            let release = BandcampRelease(
                urlString: "https://\(name.filter { !$0.isWhitespace }).bandcamp.com/album/x",
                title: "\(name) album", artistName: name
            )
            release.keywords = keywords
            context.insert(release)
        }
    }

    // MARK: A library

    /// The walk, plus files on this device. Two albums put people together
    /// that nothing else connects (Arca with Dean Blunt; Ikonika with Burial),
    /// and one connects Kode9 to Burial a second way, so a library changes a
    /// suggestion the catalogue already makes as well as adding new ones.
    /// Caracas is a scene this listener has a foot in only through the files.
    static func library() -> [Write] {
        var writes = walk()
        let files: [(String, String, String)] = [
            ("Dean Blunt", "Dean Blunt", "Black Is Beautiful"),
            ("Arca", "Dean Blunt", "Black Is Beautiful"),
            ("Burial", "Various", "Hyperdub 10"),
            ("Kode9", "Various", "Hyperdub 10"),
            ("Ikonika", "Various", "Hyperdub 10"),
            ("Arca", "Arca", "Xen"),
            ("Arca", "Arca", "Mutant"),
        ]
        for (index, (artist, albumArtist, album)) in files.enumerated() {
            writes.append { context in
                context.insert(Track(
                    path: "/Music/\(index).flac", relativePath: "\(index).flac",
                    title: "Track \(index)", artist: artist, albumArtist: albumArtist, album: album,
                    genre: "Electronic", trackNumber: index + 1, discNumber: 1, year: 2014,
                    duration: 240, fileModified: base, fileSize: 1_000, artworkKey: nil,
                    scanGeneration: 1
                ))
            }
        }
        for name in ["Arca", "Lechuga Zafiro", "Kelman Duran", "Cardopusher", "Rawar", "Ana Paula", "Mariana Bo", "Pacheco"] {
            writes.append(placedArtist(name, in: "Caracas", keywords: ["Deconstructed Club", "Experimental", "Ambient"]))
        }
        return writes
    }
}
