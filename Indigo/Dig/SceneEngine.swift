//
//  SceneEngine.swift
//  Indigo
//
//  A scene is a place and a stretch of time — Berlin 2010–2016, Manchester
//  now — and the labels, artists and tags that cluster there.
//
//  Nothing here is a genre classifier. The clustering is done on facts the
//  app already holds: where MusicBrainz says an artist began, what Bandcamp
//  tagged a record with, when their releases came out, whose imprints they
//  came out on. A scene Indigo can't point at evidence for is one it doesn't
//  draw.
//
//  The hard part is telling a place from a tag, because Bandcamp puts both in
//  one list — "Electronic, ambient, dub, Manchester". See `PlaceIndex`.
//

import Foundation
import SwiftData

// MARK: - Places

/// Decides which words are places.
///
/// Built mostly from the catalogue itself: every city MusicBrainz has named as
/// an artist's or a label's origin is, by definition, a place — so the index
/// grows with the listener's own digging rather than out of a gazetteer
/// somebody has to maintain.
///
/// The seed exists only so the first Bandcamp tag read on a fresh install is
/// still classified. It is a short list of cities this kind of music actually
/// comes out of, not an attempt at world geography.
nonisolated struct PlaceIndex: Sendable {
    private let known: Set<String>

    private static let seed = [
        "berlin", "london", "manchester", "bristol", "glasgow", "leeds",
        "munich", "cologne", "frankfurt", "hamburg", "amsterdam", "rotterdam",
        "detroit", "chicago", "new york", "brooklyn", "los angeles", "oakland",
        "paris", "lisbon", "madrid", "barcelona", "milan", "rome",
        "copenhagen", "stockholm", "oslo", "helsinki", "reykjavik",
        "tokyo", "osaka", "seoul", "shanghai", "melbourne", "sydney",
        "montreal", "toronto", "mexico city", "são paulo", "bogotá",
        "johannesburg", "lagos", "cairo", "beirut", "ramallah", "tel aviv",
        "kyiv", "moscow", "warsaw", "prague", "budapest", "athens", "istanbul",
        "dublin", "belfast", "cardiff", "brussels", "antwerp", "zurich", "vienna"
    ]

    init(context: ModelContext) {
        var found = Set(Self.seed)
        for artist in (try? context.fetch(FetchDescriptor<Artist>())) ?? [] {
            for part in Self.components(of: artist.origin) { found.insert(part) }
        }
        for label in (try? context.fetch(FetchDescriptor<MusicLabel>())) ?? [] {
            for part in Self.components(of: label.origin) { found.insert(part) }
        }
        known = found
    }

    /// Test seam: an index over exactly these names.
    init(known: [String]) {
        self.known = Set(known.map { RecordingKey.normalize($0) })
    }

    func isPlace(_ value: String) -> Bool {
        let key = RecordingKey.normalize(value)
        return !key.isEmpty && known.contains(key)
    }

    /// The city an artist is from, as the catalogue states it. MusicBrainz
    /// writes "Munich / Germany" — the first part is the city and the second
    /// is the country, and a scene is a city.
    static func city(from origin: String?) -> String? {
        guard let origin, !origin.isEmpty else { return nil }
        let parts = origin.split(separator: "/").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return parts.first
    }

    /// Splits the tags Bandcamp mixes together into places and everything else.
    func split(keywords: [String]) -> (places: [String], tags: [String]) {
        var places: [String] = []
        var tags: [String] = []
        for keyword in keywords {
            if isPlace(keyword) { places.append(keyword) } else { tags.append(keyword) }
        }
        return (places, tags)
    }

    private static func components(of origin: String?) -> [String] {
        guard let origin else { return [] }
        return origin.split(separator: "/")
            .map { RecordingKey.normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Scenes

/// Named `MusicScene` rather than `Scene` for the same reason `MusicLabel`
/// is not `Label`: SwiftUI owns that name, and a type that shadows it makes
/// every `var body: some Scene` in the app ambiguous.
nonisolated struct MusicScene: Identifiable, Sendable {
    let city: String
    /// When the music clustered here was actually made. Nil when nothing in
    /// the cache is dated, which is a real answer rather than a guess.
    let era: ClosedRange<Int>?
    let artists: [String]
    let labels: [String]
    let tags: [String]
    let radioAppearances: Int
    let libraryTrackCount: Int
    let crateCount: Int

    var id: String { "\(RecordingKey.normalize(city))|\(era?.lowerBound ?? 0)" }

    /// "BERLIN / 2010–2016"
    var title: String { city.uppercased() }

    var eraLabel: String {
        guard let era else { return "UNDATED" }
        return era.lowerBound == era.upperBound
            ? "\(era.lowerBound)"
            : "\(era.lowerBound)–\(era.upperBound)"
    }

    var node: MusicNode {
        MusicNode(
            kind: .scene,
            key: id,
            title: city.uppercased(),
            subtitle: eraLabel
        )
    }

    /// A place with one artist and nothing else is not a scene. Saying so is
    /// better than a page of headings with one name under each.
    var isSubstantial: Bool { artists.count >= 2 || (!labels.isEmpty && !artists.isEmpty) }
}

nonisolated struct SceneEngine {
    let context: ModelContext

    /// Built once for the life of this engine — see `DigEngine` for why.
    private let shared = CacheBox()

    private final class CacheBox {
        var caches: SceneCaches?
    }

    private var caches: SceneCaches {
        if let existing = shared.caches { return existing }
        let fresh = SceneCaches(context: context)
        shared.caches = fresh
        return fresh
    }

    init(context: ModelContext) {
        self.context = context
    }

    /// Every scene the cache can evidence, busiest first.
    func scenes() -> [MusicScene] {
        let caches = self.caches
        return caches.cities.keys
            .compactMap { scene(cityKey: $0, caches: caches) }
            .filter(\.isSubstantial)
            .sorted {
                $0.artists.count == $1.artists.count
                    ? $0.city < $1.city
                    : $0.artists.count > $1.artists.count
            }
    }

    func scene(city: String) -> MusicScene? {
        scene(cityKey: RecordingKey.normalize(city), caches: caches)
    }

    /// Which scenes an artist belongs to. An artist can be in more than one —
    /// people move, and a Berlin record made by somebody from Manchester
    /// belongs to both stories.
    func scenes(forArtist name: String) -> [MusicScene] {
        let caches = self.caches
        let key = RecordingKey.normalizeArtist(name)
        return caches.citiesForArtist[key, default: []]
            .compactMap { scene(cityKey: $0, caches: caches) }
            .sorted { $0.city < $1.city }
    }

    private func scene(cityKey: String, caches: SceneCaches) -> MusicScene? {
        guard let city = caches.cities[cityKey] else { return nil }
        let artistKeys = caches.artistsForCity[cityKey] ?? []
        guard !artistKeys.isEmpty else { return nil }

        var labels: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var years: [Int] = []
        var radio = 0
        var library = 0
        var crate = 0

        for key in artistKeys {
            for name in caches.labelsForArtist[key] ?? [] { labels[name, default: 0] += 1 }
            for tag in caches.tagsForArtist[key] ?? [] { tags[tag, default: 0] += 1 }
            years.append(contentsOf: caches.yearsForArtist[key] ?? [])
            radio += caches.radioForArtist[key] ?? 0
            library += caches.libraryForArtist[key] ?? 0
            crate += caches.crateForArtist[key] ?? 0
        }

        return MusicScene(
            city: city,
            era: Self.era(from: years),
            artists: artistKeys.compactMap { caches.artistNames[$0] }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            labels: labels.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(12).map(\.key),
            tags: tags.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(10).map(\.key),
            radioAppearances: radio,
            libraryTrackCount: library,
            crateCount: crate
        )
    }

    /// The window the music actually sits in.
    ///
    /// Trimmed at both ends rather than taken as min…max: one reissue of a
    /// 1994 record would otherwise stretch a scene across thirty years and
    /// say nothing true about any of them.
    static func era(from years: [Int]) -> ClosedRange<Int>? {
        let valid = years.filter { $0 > 1900 && $0 < 2200 }.sorted()
        guard let first = valid.first, let last = valid.last else { return nil }
        guard valid.count >= 5 else { return first...last }
        let trim = max(1, valid.count / 10)
        let low = valid[trim]
        let high = valid[valid.count - 1 - trim]
        return low <= high ? low...high : first...last
    }
}

// MARK: - Caches

/// One pass over the caches, arranged by artist so a scene can be assembled
/// without going back to the store per member.
nonisolated struct SceneCaches {
    /// Normalised city key to the spelling worth showing.
    var cities: [String: String] = [:]
    var artistsForCity: [String: Set<String>] = [:]
    var citiesForArtist: [String: Set<String>] = [:]
    var artistNames: [String: String] = [:]
    var labelsForArtist: [String: Set<String>] = [:]
    var tagsForArtist: [String: Set<String>] = [:]
    var yearsForArtist: [String: [Int]] = [:]
    var radioForArtist: [String: Int] = [:]
    var libraryForArtist: [String: Int] = [:]
    var crateForArtist: [String: Int] = [:]

    init(context: ModelContext) {
        let places = PlaceIndex(context: context)

        func place(_ city: String, artist key: String, named name: String) {
            let cityKey = RecordingKey.normalize(city)
            guard !cityKey.isEmpty, !key.isEmpty, ArtistName.isRealArtist(name) else { return }
            cities[cityKey] = cities[cityKey] ?? city
            artistsForCity[cityKey, default: []].insert(key)
            citiesForArtist[key, default: []].insert(cityKey)
            artistNames[key] = artistNames[key] ?? name
        }

        // Where MusicBrainz says they began.
        for artist in (try? context.fetch(FetchDescriptor<Artist>())) ?? [] {
            let key = RecordingKey.normalizeArtist(artist.name)
            guard !key.isEmpty else { continue }
            artistNames[key] = artist.name
            if let city = PlaceIndex.city(from: artist.origin) {
                place(city, artist: key, named: artist.name)
            }
            yearsForArtist[key, default: []] += artist.releaseDates.compactMap { Int($0.prefix(4)) }
        }

        // What the artist tagged their own records with. Bandcamp mixes place
        // and genre in one list, which is why the split matters.
        for release in (try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? [] {
            let key = release.artistKey
            guard !key.isEmpty else { continue }
            artistNames[key] = artistNames[key] ?? release.artistName
            let split = places.split(keywords: release.keywords)
            for city in split.places { place(city, artist: key, named: release.artistName) }
            for tag in split.tags { tagsForArtist[key, default: []].insert(tag) }
            if let label = release.labelName, !label.isEmpty {
                labelsForArtist[key, default: []].insert(label)
            }
            if let year = release.year.flatMap(Int.init) { yearsForArtist[key, default: []].append(year) }
        }

        for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] {
            let key = artist.nameKey
            guard !key.isEmpty else { continue }
            artistNames[key] = artistNames[key] ?? artist.name
            for label in artist.labelNames { labelsForArtist[key, default: []].insert(label) }
            for style in artist.styles { tagsForArtist[key, default: []].insert(style) }
            yearsForArtist[key, default: []] += artist.releaseYears.compactMap { Int($0.prefix(4)) }
        }

        for recording in (try? context.fetch(FetchDescriptor<Recording>())) ?? [] {
            let key = RecordingKey.normalizeArtist(recording.artistName)
            guard !key.isEmpty else { continue }
            radioForArtist[key, default: 0] += recording.appearances.count
        }
        for track in (try? context.fetch(FetchDescriptor<Track>())) ?? [] {
            for key in DigEngine.artistKeys(for: track) { libraryForArtist[key, default: 0] += 1 }
        }
        for item in (try? context.fetch(FetchDescriptor<CrateItem>())) ?? [] {
            let name = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let name, !name.isEmpty else { continue }
            crateForArtist[RecordingKey.normalizeArtist(name), default: 0] += 1
        }
    }
}
