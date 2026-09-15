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
        self.init(
            artists: (try? context.fetch(FetchDescriptor<Artist>())) ?? [],
            labels: (try? context.fetch(FetchDescriptor<MusicLabel>())) ?? []
        )
    }

    /// The same index, from rows somebody has already read.
    ///
    /// `SceneCaches` fetches both of these tables for itself, and building the
    /// index from the context fetched them a second time — 305ms of a 495ms
    /// rebuild, on top of a duplicate build of this very index that the `??`
    /// below it used to make unconditionally.
    init(artists: [Artist], labels: [MusicLabel]) {
        var found = Set(Self.seed)
        for artist in artists {
            for part in Self.components(of: artist.origin) { found.insert(part) }
        }
        for label in labels {
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
    /// The one sound this scene is. Nil where the place has nothing to
    /// distinguish it and is a scene only in the older sense — a city and a
    /// stretch of years.
    ///
    /// One sound, not two. A city holds more than one scene and saying so is
    /// the point: Manchester read "HARD TECHNO, HIP HOP", which is not a scene
    /// but two of them wearing one name, with a membership that was the union
    /// of people who have nothing to do with each other.
    let sound: String?
    /// When the music clustered here was actually made. Nil when nothing in
    /// the cache is dated, which is a real answer rather than a guess.
    let era: ClosedRange<Int>?
    let artists: [String]
    let labels: [String]
    let tags: [String]
    /// The sound this place has that the others do not.
    ///
    /// Not the same list as `tags`, and the difference is the whole point. The
    /// commonest tags in a catalogue of this kind are Experimental, Electronic
    /// and Ambient, and they are the commonest in *every* scene — so naming a
    /// place by its top tag produced New York / Experimental, London /
    /// Electronic and Berlin / Experimental, which is fifty scenes with three
    /// names between them. See `SceneCaches.signature(for:)`.
    let signature: [String]
    let radioAppearances: Int
    let libraryTrackCount: Int
    let crateCount: Int

    var id: String { "\(RecordingKey.normalize(city))|\(soundKey)" }

    /// How the sound is written in an address. Empty for a place with none.
    var soundKey: String { RecordingKey.normalize(sound) }

    /// "BERLIN"
    var title: String { city.uppercased() }

    /// What this scene sounds like, or when it happened when nothing marks it
    /// out. "DUB TECHNO" — or "2010–2016".
    var soundLabel: String { sound?.uppercased() ?? eraLabel }

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
            subtitle: soundLabel,
            // Carried so the node can be reopened: a scene's address is its
            // place and its sound, and a city alone no longer names one.
            providerID: city,
            handle: sound
        )
    }

    /// A place with one artist and nothing else is not a scene. Saying so is
    /// better than a page of headings with one name under each.
    var isSubstantial: Bool { artists.count >= 2 || (!labels.isEmpty && !artists.isEmpty) }

    /// "14 artists · 6 labels · 9 radio plays" — the size of what is waiting,
    /// which is the part that makes a scene worth walking into.
    var sizeLine: String {
        var parts = ["\(artists.count) artists"]
        if !labels.isEmpty { parts.append("\(labels.count) labels") }
        if radioAppearances > 0 { parts.append("\(radioAppearances) radio plays") }
        return parts.joined(separator: " · ")
    }
}

nonisolated struct SceneEngine {
    let context: ModelContext

    /// Built once for the life of this engine — see `DigEngine` for why.
    private let shared = CacheBox()

    /// What the engine this one replaced had already worked out.
    ///
    /// `DigWorker.refresh` makes a new engine every time a write moves the
    /// generation, and a new engine used to mean rebuilding every index here
    /// from seven whole tables. `GraphStore` has taken its tables from its
    /// predecessor since the same problem was found there; this is that,
    /// for scenes.
    private let inherited: SceneCaches?

    private final class CacheBox {
        var caches: SceneCaches?
        /// A place's distinctive sounds, worked out once per generation.
        ///
        /// `signature(for:)` folds the tags of every artist in a place, and an
        /// artist page asks for it once per city the artist is placed in,
        /// twice over — once before the catalogue answers and once after,
        /// because enrichment changes the tags.
        ///
        /// Worth keeping rather than worth much: measured on the benchmark's
        /// seed it saves about 6% of ten repeated lookups, because that seed
        /// gives each artist a single style to fold. It is not where an artist
        /// page's CPU goes — that is the whole of `SceneCaches(context:)`,
        /// rebuilt from nothing every time a write moves the generation. See
        /// `testCostOfRebuildingTheSceneCaches`.
        ///
        /// Safe to hold because the caches beside it are: both are thrown away
        /// together when a write moves the generation. See `DigEngine`.
        var signatures: [String: [String]] = [:]
    }

    private var caches: SceneCaches {
        if let existing = shared.caches { return existing }
        // Nothing has moved since the build this engine replaced, so its
        // answers are this engine's answers.
        if let inherited, inherited.stillDescribes(context) {
            shared.caches = inherited
            return inherited
        }
        let fresh = Trace.step("scene.tables") {
            SceneCaches(context: context, reusing: inherited)
        }
        shared.caches = fresh
        return fresh
    }

    init(context: ModelContext, inheriting previous: SceneEngine? = nil) {
        self.context = context
        self.inherited = previous?.shared.caches
    }

    /// How many artists a place needs before it can be somewhere to head into.
    ///
    /// Four, back when a scene was a whole city and held nineteen people.
    /// Splitting them by sound made every scene smaller — most hold two or
    /// three — and the threshold went on measuring the old shape. On a real
    /// collection exactly one place could clear it, so the page named
    /// Manchester's hip hop every time it was opened, for weeks.
    ///
    /// Two, which is what `isSubstantial` already asks of a scene at all. A
    /// scene somebody has a foot in and two names they have not heard is a
    /// direction; refusing it and repeating yesterday's answer is not.
    static let directionMinimum = 2

    /// How many scenes one place can hold.
    ///
    /// A city is not a scene, it is where several of them happen. Manchester
    /// has a hard techno one and a hip hop one, and folding them together
    /// produced a name that was two names and a membership that was the union
    /// of people with nothing to do with each other.
    static let scenesPerPlace = 3

    /// Every scene the cache can evidence, busiest first.
    func scenes() -> [MusicScene] {
        let caches = self.caches
        return caches.cities.keys
            .flatMap { scenes(cityKey: $0, caches: caches) }
            .filter(\.isSubstantial)
            .sorted {
                $0.artists.count == $1.artists.count
                    ? $0.city < $1.city
                    : $0.artists.count > $1.artists.count
            }
    }

    /// The scene this listener is heading into.
    ///
    /// Not the one they know best — that is where they already are, and being
    /// told about it is being told what they did. What "moving toward" means
    /// is a place they have a foot in and most of which they have not heard:
    /// a few of its artists in the crate, a sound that matches what they play,
    /// and a dozen names still in front of them.
    ///
    /// Nil is a real answer. Somebody whose collection sits squarely in one
    /// place is not moving anywhere, and inventing a direction for them would
    /// be the app talking rather than reading.
    func movingToward(taste: TasteProfile) -> MusicScene? {
        directions(taste: taste).first
    }

    /// Every scene this listener could be said to be heading into, best first.
    ///
    /// Plural because the singular was always the same answer. Scoring already
    /// ranks every candidate and then threw all but one away, so a collection
    /// that changes slowly named one place for weeks — the page made a claim
    /// about somebody's direction and then repeated it until they stopped
    /// reading it. Several are worked out for the price of the one, and which
    /// gets shown moves on.
    func directions(taste: TasteProfile, limit: Int = 6) -> [MusicScene] {
        guard !taste.isEmpty else { return [] }
        let caches = self.caches
        // Only the places this listener has a foot in, decided before any
        // scene is built. A direction requires a foothold, so assembling the
        // forty-odd cities where there is none — each one a signature, a
        // membership and a merge — is work whose answer is known in advance.
        let candidates = caches.cities.keys.filter { cityKey in
            guard !caches.countries.contains(cityKey) else { return false }
            let members = caches.artistsForCity[cityKey] ?? []
            guard members.count >= Self.directionMinimum else { return false }
            return members.contains {
                (caches.crateForArtist[$0] ?? 0) + (caches.libraryForArtist[$0] ?? 0) > 0
            }
        }
        guard !candidates.isEmpty else { return [] }

        let found: [MusicScene] = candidates
            .flatMap { scenes(cityKey: $0, caches: caches) }
            .filter(\.isSubstantial)
        return found
            .compactMap { scene -> (scene: MusicScene, score: Double)? in
                let foothold = scene.crateCount + scene.libraryTrackCount
                // No foot in it at all is not a direction, it is a stranger.
                guard foothold > 0, scene.artists.count >= Self.directionMinimum else { return nil }
                let affinity = taste.affinity(for: scene.signature + scene.tags)
                guard affinity > 0.15 else { return nil }
                // Enough of a start to mean something, and enough left to be
                // worth going. A scene they have already worked through is
                // somewhere they have been.
                let started = min(1, Double(foothold) / 3)
                let room = 1 - min(1, Double(foothold) / Double(scene.artists.count))
                let score = affinity * started * room
                return score > 0 ? (scene, score) : nil
            }
            .sorted {
                $0.score == $1.score ? $0.scene.id < $1.scene.id : $0.score > $1.score
            }
            .prefix(limit)
            .map(\.scene)
    }

    /// One named scene: a place and a sound. Without a sound, the place's
    /// strongest — so an older link that only knows a city still lands
    /// somewhere real.
    func scene(city: String, sound: String? = nil) -> MusicScene? {
        let found = scenes(cityKey: RecordingKey.normalize(city), caches: caches)
        guard let sound, !sound.isEmpty else { return found.first }
        let wanted = RecordingKey.normalize(sound)
        return found.first { $0.soundKey == wanted } ?? found.first
    }

    /// Which scenes an artist belongs to. An artist can be in more than one —
    /// people move, and a Berlin record made by somebody from Manchester
    /// belongs to both stories.
    /// Which scenes an artist belongs to. Only the ones they are actually in:
    /// living in Manchester does not put somebody in its hip hop scene.
    func scenes(forArtist name: String) -> [MusicScene] {
        let caches = self.caches
        let key = RecordingKey.normalizeArtist(name)
        // Folded once, not once per scene. This artist's tags do not change
        // between the scenes being filtered, and re-folding them inside the
        // closure did the same work for every place-and-sound the artist is
        // in.
        let tags = Set((caches.tagsForArtist[key] ?? []).flatMap { ListeningLog.foldTags([$0]) })
        return caches.citiesForArtist[key, default: []]
            .flatMap { scenes(cityKey: $0, caches: caches) }
            .filter { scene in
                guard let sound = scene.sound else { return true }
                return !tags.isDisjoint(with: Set(ListeningLog.foldTags([sound])))
            }
            .sorted { $0.city == $1.city ? $0.soundKey < $1.soundKey : $0.city < $1.city }
    }

    /// `SceneCaches.signature(for:)`, remembered for this generation.
    private func signature(for cityKey: String, caches: SceneCaches) -> [String] {
        if let known = shared.signatures[cityKey] { return known }
        let worked = caches.signature(for: cityKey, limit: Self.scenesPerPlace)
        shared.signatures[cityKey] = worked
        return worked
    }

    /// Every scene one place holds, strongest sound first.
    private func scenes(cityKey: String, caches: SceneCaches) -> [MusicScene] {
        let signature = self.signature(for: cityKey, caches: caches)
        guard !signature.isEmpty else {
            // Nowhere in particular. Then it is a place and a stretch of
            // years, which is what a scene was before it had a sound, and
            // everybody who lives there is in it.
            return [scene(cityKey: cityKey, sound: nil, caches: caches)].compactMap { $0 }
        }
        return Self.merged(
            signature.compactMap { scene(cityKey: cityKey, sound: $0, caches: caches) }
        )
    }

    /// Folds scenes that are the same people under different words.
    ///
    /// A place's distinctive sounds are often several names for one thing: New
    /// York came out as jazz, avantgarde and free jazz, each with the same
    /// five musicians in it, and London as balearic, jazz and trance with an
    /// identical membership. Three entries for one scene is not three scenes,
    /// it is the same page printed three times.
    ///
    /// The first survives, because the signature is already ordered by how
    /// much the sound belongs to the place.
    static func merged(_ scenes: [MusicScene]) -> [MusicScene] {
        var kept: [MusicScene] = []
        for scene in scenes {
            let members = Set(scene.artists)
            let isDuplicate = kept.contains { existing in
                let theirs = Set(existing.artists)
                guard !members.isEmpty, !theirs.isEmpty else { return false }
                let shared = members.intersection(theirs).count
                // Most of one inside the other. Two scenes that share a few
                // people are two scenes; two that share nearly everybody are
                // one under two names.
                return Double(shared) / Double(min(members.count, theirs.count)) >= 0.8
            }
            if !isDuplicate { kept.append(scene) }
        }
        return kept
    }

    private func scene(cityKey: String, sound: String?, caches: SceneCaches) -> MusicScene? {
        guard let city = caches.cities[cityKey] else { return nil }
        // A scene is a place *and* a sound, and its members are the people who
        // make that sound there — not everybody who happens to live in the
        // city. A page that says jazz and lists a noise band is worse than one
        // that says New York, because it makes a claim and contradicts it.
        let artistKeys = caches.members(of: cityKey, sounding: sound.map { [$0] } ?? [])
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
            sound: sound,
            era: Self.era(from: years),
            artists: artistKeys.compactMap { caches.artistNames[$0] }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            labels: labels.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(12).map(\.key),
            tags: tags.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(10).map(\.key),
            signature: caches.signature(for: cityKey),

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

extension SceneCaches {
    /// The sound this place has that the others do not.
    ///
    /// Frequency alone is useless here. In a catalogue of this kind the
    /// commonest tags are Experimental, Electronic and Ambient, and they are
    /// the commonest in every single scene — so a name taken from the top tag
    /// gives New York / Experimental, London / Electronic and Berlin /
    /// Experimental, which is fifty places wearing three names. What
    /// distinguishes a scene is a sound that is ordinary *here* and unusual
    /// everywhere else: Detroit's minimal, Los Angeles' glitch, Manchester's
    /// hard techno.
    ///
    /// So a tag is weighed by how much of this place carries it against how
    /// many other places do — the same shape as the term weighting a search
    /// index uses, for the same reason. A tag in half the scenes says almost
    /// nothing; a tag in two says a great deal.
    func signature(for cityKey: String, limit: Int = 3) -> [String] {
        let artistKeys = artistsForCity[cityKey] ?? []
        guard artistKeys.count > 1 else { return [] }

        // Folded, or "Ambient" and "ambient" are counted as two sounds and
        // each gets half the evidence of the one sound they are.
        var here: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for key in artistKeys {
            // Counted once per artist, not once per tag. A record tagged both
            // "Sonae" and "sonae" folds to one sound twice, which let a word
            // on a single artist clear the two-artist bar — and named a whole
            // city after her.
            var seenForArtist = Set<String>()
            for tag in tagsForArtist[key] ?? [] {
                for folded in ListeningLog.foldTags([tag]) {
                    spelling[folded] = spelling[folded] ?? tag
                    guard seenForArtist.insert(folded).inserted else { continue }
                    here[folded, default: 0] += 1
                }
            }
        }
        guard !here.isEmpty else { return [] }

        let cityWords = Set(ListeningLog.foldTags([cities[cityKey] ?? ""]))
        let placeCount = Double(max(1, cities.count))
        let members = Double(artistKeys.count)

        var scored: [(tag: String, weight: Double)] = []
        for (tag, count) in here {
            guard isSound(tag, avoiding: cityWords) else { continue }
            // Two artists at the least, and enough of the place to be the
            // place's rather than one member's. Without the share, a keyword
            // on two of nineteen names the whole scene after them.
            guard count > 1 else { continue }
            let share = Double(count) / members
            guard share >= 0.2 else { continue }
            let elsewhere = Double(max(1, placesPerTag[tag] ?? 1))
            let rarity = log(placeCount / elsewhere)
            guard rarity > 0 else { continue }
            scored.append((tag, share * rarity))
        }
        return scored
            .sorted { $0.weight == $1.weight ? $0.tag < $1.tag : $0.weight > $1.weight }
            .prefix(limit)
            .map { spelling[$0.tag] ?? $0.tag }
    }

    /// Who in this place actually belongs to its scene.
    ///
    /// Everybody, when the place has no sound of its own — then it is a scene
    /// in the older sense, a city and a stretch of years, and there is nothing
    /// to be a member of. Otherwise only the artists who carry the sound the
    /// scene is named after. A signature needs two artists and a fifth of the
    /// place to exist at all, so this never empties a scene it named.
    func members(of cityKey: String, sounding signature: [String]) -> Set<String> {
        let everyone = artistsForCity[cityKey] ?? []
        guard !signature.isEmpty else { return everyone }
        let wanted = Set(signature.flatMap { ListeningLog.foldTags([$0]) })
        guard !wanted.isEmpty else { return everyone }
        let found = everyone.filter { key in
            let tags = Set((tagsForArtist[key] ?? []).flatMap { ListeningLog.foldTags([$0]) })
            return !tags.isDisjoint(with: wanted)
        }
        return found.isEmpty ? everyone : found
    }

    /// Whether a tag describes a sound rather than a person or a place.
    ///
    /// Both are maximally distinctive — a name appears in exactly one place by
    /// definition — which is precisely why they rise to the top of a rarity
    /// measure and have to be refused by hand. Left in, they produced BERLIN /
    /// SONAE, DETROIT / ROBERT HOOD and NEW ZEALAND / SPIRITUAL JAZZ,
    /// AUCKLAND.
    private func isSound(_ tag: String, avoiding cityWords: Set<String>) -> Bool {
        guard !artistWords.contains(tag) else { return false }
        guard !cityWords.contains(tag) else { return false }
        guard placeIndex?.isPlace(tag) != true else { return false }
        return true
    }
}

extension SceneCaches {
    /// Gives each half of a collaboration what the collaboration knows.
    ///
    /// A duo filed as "Andrew Cyrille - Anthony Braxton" is placed as two
    /// people, and everything the catalogue said about it — its tags, its
    /// years, its labels — is filed under the pair. Left there, the two
    /// members are placed in a city carrying nothing, so the sound that made
    /// the scene belongs to a name that is not in it, and both of them fall
    /// out of the very scene they define. New York went from Braxton, Cyrille
    /// and George Lewis to Elephants Memory and Phase Tomorrow in one step,
    /// which is how this was found.
    ///
    /// The pair keeps its own entry too. It is a real credit and other things
    /// look it up; what it stops being is a member of anywhere.
    mutating func distributeCredits() {
        for (key, name) in artistNames {
            let members = ArtistName.split(name)
            guard members.count > 1 else { continue }
            for member in members {
                let memberKey = RecordingKey.normalizeArtist(member)
                guard !memberKey.isEmpty, memberKey != key else { continue }
                artistNames[memberKey] = artistNames[memberKey] ?? member
                if let tags = tagsForArtist[key] {
                    tagsForArtist[memberKey, default: []].formUnion(tags)
                }
                if let labels = labelsForArtist[key] {
                    labelsForArtist[memberKey, default: []].formUnion(labels)
                }
                if let years = yearsForArtist[key] {
                    yearsForArtist[memberKey, default: []] += years
                }
                // A record by both of them is a record for both of them.
                radioForArtist[memberKey, default: 0] += radioForArtist[key] ?? 0
                libraryForArtist[memberKey, default: 0] += libraryForArtist[key] ?? 0
                crateForArtist[memberKey, default: 0] += crateForArtist[key] ?? 0
            }
        }
    }

    /// Everything after the first part of an origin — which is where the
    /// catalogue puts the country.
    static func countryParts(of origin: String?) -> [String] {
        guard let origin else { return [] }
        return origin.split(separator: "/")
            .dropFirst()
            .map { RecordingKey.normalize(String($0)) }
            .filter { !$0.isEmpty }
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
    /// How many places each folded tag turns up in. The denominator of a
    /// scene's signature — see `signature(for:)`.
    var placesPerTag: [String: Int] = [:]
    /// Every artist's name the app knows, folded — not only the ones placed in
    /// a scene. Bandcamp keywords carry artists' names, and a name appears in
    /// exactly one place, which makes it the most distinctive word there is
    /// and the least useful: it produced BERLIN / SONAE and DETROIT / ROBERT
    /// HOOD.
    ///
    /// A genre word that is also somebody's name is lost with them. That is
    /// the right way round to be wrong — a scene named after a person reads
    /// as a mistake, and one missing a sound reads as a scene.
    var artistWords: Set<String> = []
    /// Places that are countries.
    ///
    /// MusicBrainz writes an origin as "Munich / Germany", so anything
    /// appearing after the first slash somewhere is a country by the
    /// catalogue's own reckoning — no list to maintain. Artists whose entry
    /// names only their country land in one of these, and the result is a bag
    /// of unrelated people: UNITED STATES / HORROR, EXPERIMENTAL POP, offered
    /// as somewhere a listener was heading.
    var countries: Set<String> = []
    /// The place index, kept so a signature can refuse a city. A tag that is
    /// somewhere is not a sound: NEW ZEALAND / SPIRITUAL JAZZ, AUCKLAND.
    var placeIndex: PlaceIndex?

    /// The tables this cache is derived from, counted.
    ///
    /// Same device as `GraphStore.Caches.rowCounts`, and for the same reason:
    /// a cache is only stale if something it reads has changed. Counting is
    /// six index reads against a rebuild that fetches all seven tables whole
    /// and folds every artist's tags — measured at 5,009ms cold against 32ms
    /// warm on the benchmark's store. See `testCostOfRebuildingTheSceneCaches`.
    ///
    /// A count is a complete answer here because nothing this reads is edited
    /// in place without a row being added: origins arrive with the artist,
    /// keywords with the Bandcamp release.
    var rowCounts: [Int] = []

    static func rowCounts(in context: ModelContext) -> [Int] {
        [
            (try? context.fetchCount(FetchDescriptor<Artist>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<MusicLabel>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<BandcampRelease>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<DiscogsArtist>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<Recording>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<Track>())) ?? -1,
            (try? context.fetchCount(FetchDescriptor<CrateItem>())) ?? -1
        ]
    }

    /// The rows every index here is derived from, kept so they can be
    /// inherited one table at a time.
    ///
    /// This began as whole-cache inheritance and that was the wrong shape.
    /// Browsing inserts a `DiscogsArtist` for every artist opened, so the one
    /// table that always changes discarded the six that had not — and the
    /// trace showed `scene.tables` rebuilding fifteen times in a few minutes
    /// at 495ms each, which is what the inheritance was added to stop.
    ///
    /// `GraphStore.Caches` solved this first and this is the same device:
    /// re-read the table that moved, take the rest from the build before.
    /// Deriving the indexes again from rows already in hand is the cheap half;
    /// the fetch and the faulting are what cost.
    nonisolated struct Rows: Sendable {
        var artists: [Artist] = []
        var labels: [MusicLabel] = []
        var bandcamp: [BandcampRelease] = []
        var discogs: [DiscogsArtist] = []
        var recordings: [Recording] = []
        var tracks: [Track] = []
        var crate: [CrateItem] = []
    }

    var rows = Rows()

    /// Whether this build still describes the store exactly.
    ///
    /// The shortcut above per-table inheritance, and it earns its place: when
    /// nothing has changed there is no reason to derive the indexes again, and
    /// deriving them is a second of work on a real store. Re-reading one table
    /// and re-deriving is the answer when something *has* moved; handing the
    /// whole build back is the answer when nothing has.
    func stillDescribes(_ context: ModelContext) -> Bool {
        let counts = SceneCaches.rowCounts(in: context)
        return !counts.contains(-1) && counts == rowCounts
    }

    /// Reads each table, or takes it from the build before when its count and
    /// newest stamp are unchanged.
    ///
    /// Stamps as well as counts, for the reason `BandcampByArtist` needs them:
    /// `BandcampEnricher` rewrites a release it already holds — `artistKey`
    /// included — and that changes no count at all.
    static func rows(in context: ModelContext, reusing previous: SceneCaches?) -> (Rows, [Int]) {
        let counts = Self.rowCounts(in: context)
        var found = Rows()

        func kept<T>(_ index: Int, _ value: (SceneCaches) -> [T]) -> [T]? {
            guard let previous, previous.rowCounts.count == counts.count,
                  previous.rowCounts[index] == counts[index], counts[index] >= 0
            else { return nil }
            return value(previous)
        }

        found.artists = kept(0, \.rows.artists)
            ?? Trace.step("sc.f.artists") { (try? context.fetch(FetchDescriptor<Artist>())) ?? [] }
        found.labels = kept(1, \.rows.labels)
            ?? ((try? context.fetch(FetchDescriptor<MusicLabel>())) ?? [])
        found.bandcamp = kept(2, \.rows.bandcamp)
            ?? Trace.step("sc.f.bandcamp") {
                (try? context.fetch(FetchDescriptor<BandcampRelease>())) ?? []
            }
        found.discogs = kept(3, \.rows.discogs)
            ?? Trace.step("sc.f.discogs") {
                (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []
            }
        found.recordings = kept(4, \.rows.recordings)
            ?? ((try? context.fetch(FetchDescriptor<Recording>())) ?? [])
        found.tracks = kept(5, \.rows.tracks)
            ?? ((try? context.fetch(FetchDescriptor<Track>())) ?? [])
        found.crate = kept(6, \.rows.crate)
            ?? ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? [])

        return (found, counts)
    }

    init(context: ModelContext, reusing previous: SceneCaches? = nil) {
        let (fetched, counts) = Self.rows(in: context, reusing: previous)
        rows = fetched
        rowCounts = counts

        // The place index is derived from two of those tables, so it is
        // inherited on the same terms rather than rebuilt beside them.
        let places: PlaceIndex
        if let previous, let held = previous.placeIndex,
           previous.rowCounts.count == counts.count,
           previous.rowCounts[0] == counts[0], previous.rowCounts[1] == counts[1] {
            places = held
        } else {
            places = Trace.step("sc.places") { PlaceIndex(artists: fetched.artists, labels: fetched.labels) }
        }

        func place(_ city: String, artist key: String, named name: String) {
            let cityKey = RecordingKey.normalize(city)
            guard !cityKey.isEmpty, !key.isEmpty, ArtistName.isRealArtist(name) else { return }
            cities[cityKey] = cities[cityKey] ?? city
            artistsForCity[cityKey, default: []].insert(key)
            citiesForArtist[key, default: []].insert(cityKey)
            artistNames[key] = artistNames[key] ?? name
        }

        /// Places each person named in a credit, rather than the credit.
        ///
        /// A duo filed as "Andrew Cyrille - Anthony Braxton" is two people, and
        /// filing it whole put a third name in the scene that is nobody —
        /// New York listed Braxton three times, as himself and as two spellings
        /// of the same pair.
        func placeCredit(_ city: String, credit: String) {
            let names = ArtistName.split(credit)
            guard names.count > 1 else {
                place(city, artist: RecordingKey.normalizeArtist(credit), named: credit)
                return
            }
            for name in names {
                place(city, artist: RecordingKey.normalizeArtist(name), named: name)
            }
        }

        // Every name the app knows, collected as the tables go past.
        //
        // `artistWords` needs the name of everybody, placed or not — and it
        // used to get them by fetching `Artist`, `DiscogsArtist` and
        // `Recording` a second time, after the loops below had already read
        // all three. That re-read measured 1,476ms of a 4,429ms rebuild, the
        // largest single piece of it, for rows sitting in hand.
        var everyName: [String] = []

        // Where MusicBrainz says they began.
        Trace.step("sc.mbArtists") {
        for artist in fetched.artists {
            everyName.append(artist.name)
            let key = RecordingKey.normalizeArtist(artist.name)
            guard !key.isEmpty else { continue }
            artistNames[key] = artist.name
            if let city = PlaceIndex.city(from: artist.origin) {
                placeCredit(city, credit: artist.name)
            }
            yearsForArtist[key, default: []] += artist.releaseDates.compactMap { Int($0.prefix(4)) }
        }
        }

        // What the artist tagged their own records with. Bandcamp mixes place
        // and genre in one list, which is why the split matters.
        Trace.step("sc.bandcamp") {
        for release in fetched.bandcamp {
            let key = release.artistKey
            guard !key.isEmpty else { continue }
            artistNames[key] = artistNames[key] ?? release.artistName
            let split = places.split(keywords: release.keywords)
            for city in split.places { placeCredit(city, credit: release.artistName) }
            for tag in split.tags { tagsForArtist[key, default: []].insert(tag) }
            if let label = release.imprint, !label.isEmpty {
                labelsForArtist[key, default: []].insert(label)
            }
            if let year = release.year.flatMap(Int.init) { yearsForArtist[key, default: []].append(year) }
        }
        }

        Trace.step("sc.discogsArtists") {
        for artist in fetched.discogs {
            everyName.append(artist.name)
            let key = artist.nameKey
            guard !key.isEmpty else { continue }
            artistNames[key] = artistNames[key] ?? artist.name
            for label in artist.labelNames { labelsForArtist[key, default: []].insert(label) }
            for style in artist.styles { tagsForArtist[key, default: []].insert(style) }
            yearsForArtist[key, default: []] += artist.releaseYears.compactMap { Int($0.prefix(4)) }
        }
        }

        Trace.step("sc.recordings") {
        for recording in fetched.recordings {
            if let credited = recording.artistName { everyName.append(credited) }
            let key = RecordingKey.normalizeArtist(recording.artistName)
            guard !key.isEmpty else { continue }
            radioForArtist[key, default: 0] += recording.appearances.count
        }
        }
        Trace.step("sc.tracks") {
        for track in fetched.tracks {
            for key in DigEngine.artistKeys(for: track) { libraryForArtist[key, default: 0] += 1 }
        }
        }
        for item in fetched.crate {
            let name = item.recording?.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            guard let name, !name.isEmpty else { continue }
            crateForArtist[RecordingKey.normalizeArtist(name), default: 0] += 1
        }

        // Having listened to somebody is a foot in their scene as much as
        // having kept them is. Counted here so a direction can be read from
        // what a person plays and not only from what they filed — which on a
        // collection whose crate is small is most of what there is to go on.
        Trace.step("sc.listening") {
        for event in ListeningLog(context: context).all()
        where event.kind == .artist && event.weight > 0 {
            crateForArtist[event.nodeKey, default: 0] += 1
        }
        }

        // Every artist the app knows of, not only the ones with a place. Sonae
        // has no origin on file and so was never in `artistNames`, but her
        // name is a keyword on a Berlin collective's record — which is how the
        // scene came to be called BERLIN / SONAE.
        let names = Trace.step("sc.nameList") { Array(artistNames.values) + everyName }
        Trace.step("sc.credits") { distributeCredits() }

        artistWords = Trace.step("sc.words") { Set(names.flatMap { ListeningLog.foldTags([$0]) }) }

        for artist in fetched.artists {
            countries.formUnion(Self.countryParts(of: artist.origin))
        }
        for label in fetched.labels {
            countries.formUnion(Self.countryParts(of: label.origin))
        }
        // The index built at the top of this initialiser, not a second one.
        //
        // `placeIndex` is never assigned before here, so the `??` always took
        // its right-hand side and every scene rebuild constructed the same
        // index twice — 305ms of the two and a half seconds, spent deriving an
        // answer already sitting in `places`.
        placeIndex = places

        // Last, because it reads what everything above built: how widespread
        // each sound is across all the places at once. A scene's signature is
        // measured against this — see `signature(for:)`.
        Trace.step("sc.placesPerTag") {
        for (cityKey, artistKeys) in artistsForCity {
            guard !cityKey.isEmpty else { continue }
            var seenHere = Set<String>()
            for key in artistKeys {
                for tag in tagsForArtist[key] ?? [] {
                    for folded in ListeningLog.foldTags([tag]) where seenHere.insert(folded).inserted {
                        placesPerTag[folded, default: 0] += 1
                    }
                }
            }
        }
        }
    }
}
