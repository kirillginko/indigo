//
//  ExploreKnowledge.swift
//  Indigo
//
//  What For You is worked out from, as plain values: the listener's own rows,
//  and what is known about music around them.
//
//  The engine used to read both straight out of the store as it went, so what
//  it was given and what it decided could not be told apart -- two devices
//  disagreed and there was no saying whether they had been given different
//  things or had done something different with the same things. Now there are
//  three steps. `PersonalInputs` is read from the synced rows. A
//  `KnowledgeSnapshot` is built around them -- for now from this device's
//  caches, by `LocalKnowledgeAdapter`, later from Indigo's backend. And
//  `ExploreRanker` turns the two into offers without touching anything else.
//
//  Each part is digested (`CanonicalDigest`), and the four digests with the
//  evaluation day are the answer's stamp (`ExploreStamp`). Equal stamps give
//  equal offers; unequal ones say which part differs.
//

import CryptoKit
import Foundation
import SwiftData

// MARK: - The listener's own rows

/// Everything For You reads from the synced store, and nothing else, in an
/// order of its own content.
nonisolated struct PersonalInputs: Codable, Equatable, Sendable {
    /// A crated record, as the ranker reads it.
    struct Kept: Codable, Equatable, Sendable {
        var node: MusicNode?
        var addedAt: Date
        var genreTags: [String]
        /// The artists it says something about the taste of: its own name for
        /// an artist, and the credited artist of anything else.
        var tasteArtistKeys: [String]
        /// The artist it gives a foothold in a scene, if any.
        var sceneArtistKey: String?
    }

    /// A play inside the taste profile's horizon of `asOf`.
    struct Play: Codable, Equatable, Sendable {
        var id: String
        var at: Date
        var weight: Double
        var tags: [String]
    }

    /// Something met, ever: what "already heard" is decided against, and what
    /// the recent half of the starting points is chosen from.
    struct Met: Codable, Equatable, Sendable {
        var node: MusicNode
        var weight: Double
        var lastAt: Date
    }

    /// A place returned to.
    struct Haunt: Codable, Equatable, Sendable {
        var node: MusicNode
        var visits: Int
        var lastVisitedAt: Date
    }

    /// Newest first, then by node.
    var crate: [Kept]
    /// Oldest first, then by id: the order the profile adds them in.
    var plays: [Play]
    /// By node id.
    var met: [Met]
    /// How many times each artist was played to some purpose, by artist key.
    var artistPlays: [String: Int]
    /// In the order the engine starts from them.
    var haunts: [Haunt]

    static let empty = PersonalInputs(crate: [], plays: [], met: [], artistPlays: [:], haunts: [])

    /// Read from the store. `asOf` bounds the plays the taste profile weighs;
    /// everything else is all of it.
    static func read(context: ModelContext, asOf: Date) -> PersonalInputs {
        let crate = CrateService(context: context).items().map { item -> Kept in
            var taste = Set<String>()
            if let node = item.node, node.kind == .artist { taste.insert(RecordingKey.normalizeArtist(node.title)) }
            if let name = item.artistName { taste.insert(RecordingKey.normalizeArtist(name)) }
            let sceneName = item.artistName ?? (item.kind == .artist ? item.displayTitle : nil)
            return Kept(
                node: item.node, addedAt: item.addedAt, genreTags: item.genreTags,
                tasteArtistKeys: taste.sorted(),
                sceneArtistKey: sceneName.flatMap { $0.isEmpty ? nil : RecordingKey.normalizeArtist($0) }
            )
        }
        // The log read once: the plays inside the horizon are a filter over
        // it, not a second fetch of the same rows.
        let every = ListeningLog(context: context).all()
        let horizon = asOf.addingTimeInterval(-TasteProfile.horizon)
        let plays = every.filter { $0.at >= horizon }.map {
            Play(id: $0.id.uuidString, at: $0.at, weight: $0.weight, tags: $0.tags)
        }
        var artistPlays: [String: Int] = [:]
        for event in every where event.kind == .artist && event.weight > 0 {
            artistPlays[event.nodeKey, default: 0] += 1
        }
        let haunts = DigHistory(context: context)
            .haunts(kinds: ExploreSuggestionEngine.hauntKinds, limit: ExploreSuggestionEngine.hauntLimit)
            .map { Haunt(node: $0.node, visits: $0.visits, lastVisitedAt: $0.lastVisitedAt) }
        return PersonalInputs(
            crate: crate.sorted(by: Self.newestFirst),
            plays: plays.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at },
            met: ListeningLog.gather(every)
                .map { Met(node: $0.node, weight: $0.weight, lastAt: $0.lastAt) }
                .sorted { $0.node.id < $1.node.id },
            artistPlays: artistPlays,
            haunts: haunts
        )
    }

    /// The crate's order: newest first, then by what each record is.
    static func newestFirst(_ left: Kept, _ right: Kept) -> Bool {
        if left.addedAt != right.addedAt { return left.addedAt > right.addedAt }
        let l = left.node?.id ?? "", r = right.node?.id ?? ""
        if l != r { return l < r }
        return left.genreTags.lexicographicallyPrecedes(right.genreTags)
    }

    /// Every artist the crate says something about the taste of.
    var tasteArtistKeys: Set<String> { Set(crate.flatMap(\.tasteArtistKeys)) }
}

// MARK: - What is known around them

/// What is known about music around one listener's starting points: the
/// shared part, which any device with the same catalogue builds the same way,
/// and the part only this device can know.
nonisolated struct KnowledgeSnapshot: Codable, Equatable, Sendable {
    /// The shape of this and the rules it was built by. Changing either
    /// changes every digest.
    ///
    /// 2: artists are keyed by who they are (`IdentityGraph`) — a verified
    ///    artist by their Discogs entry, everyone else by name as before — and
    ///    the listener's history is read the same way.
    static let currentFormat = 2

    var format = KnowledgeSnapshot.currentFormat
    var shared: SharedKnowledge
    var deviceLocal: DeviceLocalKnowledge

    static let empty = KnowledgeSnapshot(shared: .empty, deviceLocal: .empty)
}

/// One edge out of a starting point, its ends given as places in the
/// snapshot's node table so a node reached forty times is written once.
nonisolated struct KnownEdge: Codable, Equatable, Sendable {
    var from: Int
    var to: Int
    var kind: RelationshipKind
    var source: String
    var reason: String
    var confidence: Double
    var occurrences: Int
}

/// Everything one step from a starting point.
nonisolated struct Neighbourhood: Codable, Equatable, Sendable {
    /// The starting point, in the node table.
    var origin: Int
    var edges: [KnownEdge]
}

/// A broadcast with a tracklist, folded to what show suggestions read.
nonisolated struct ShowProfile: Codable, Equatable, Sendable {
    var providerID: String
    var showID: String
    var title: String
    var artworkURL: URL?
    /// Everybody named on the tracklist, sorted.
    var artists: [String]
    /// What the catalogue says they sound like, folded, deduplicated, sorted.
    var tags: [String]

    var key: String { "\(providerID)|\(showID)" }
}

/// A scene, without anything about the listener: who is in it is knowledge,
/// how much of it they keep is theirs.
nonisolated struct SceneCandidate: Codable, Equatable, Sendable {
    var city: String
    var sound: String?
    var eraLow: Int?
    var eraHigh: Int?
    /// Every artist key in it, sorted.
    var members: [String]
    /// How many of them have a name to show.
    var artistCount: Int
    var labelCount: Int
    var radioAppearances: Int
    var signature: [String]
    var tags: [String]

    var id: String { "\(RecordingKey.normalize(city))|\(RecordingKey.normalize(sound))" }

    /// What `MusicScene` says of the same scene.
    var soundLabel: String {
        if let sound { return sound.uppercased() }
        guard let eraLow, let eraHigh else { return "UNDATED" }
        return eraLow == eraHigh ? "\(eraLow)" : "\(eraLow)–\(eraHigh)"
    }

    var sizeLine: String {
        var parts = ["\(artistCount) artists"]
        if labelCount > 0 { parts.append("\(labelCount) labels") }
        if radioAppearances > 0 { parts.append("\(radioAppearances) radio plays") }
        return parts.joined(separator: " · ")
    }
}

/// A place that could be a direction, with everybody who lives there.
nonisolated struct SceneCity: Codable, Equatable, Sendable {
    var key: String
    var members: [String]
    var scenes: [SceneCandidate]
}

/// Every place a listener could be heading into. Not narrowed to the places
/// they already have a foot in: whether they do is theirs, and narrowing by it
/// would make this part change whenever the crate does.
nonisolated struct SceneCatalogue: Codable, Equatable, Sendable {
    var cities: [SceneCity]
    /// A joint credit's artists, by the credit's key. A record by both of them
    /// is a foothold for both.
    var creditMembers: [String: [String]]
}

nonisolated struct SharedKnowledge: Codable, Equatable, Sendable {
    var nodes: [MusicNode]
    var neighbourhoods: [Neighbourhood]
    var shows: [ShowProfile]
    /// Styles and genres, folded, for the artists the crate says something
    /// about the taste of.
    var artistTags: [String: [String]]
    /// Nil until it is worked out: it is the slow half.
    var scenes: SceneCatalogue?

    static let empty = SharedKnowledge(nodes: [], neighbourhoods: [], shows: [], artistTags: [:], scenes: nil)
}

/// What only this device knows: its music library. Kept out of the shared part
/// so the shared part means the same on every device, and so its own effect on
/// For You can be measured by leaving it out.
nonisolated struct DeviceLocalKnowledge: Codable, Equatable, Sendable {
    var nodes: [MusicNode]
    /// The library's edges out of each starting point.
    var neighbourhoods: [Neighbourhood]
    /// Tracks per artist key, before joint credits are shared out.
    var libraryCounts: [String: Int]

    static let empty = DeviceLocalKnowledge(nodes: [], neighbourhoods: [], libraryCounts: [:])
}

// MARK: - The stamp

/// What an answer was worked out from, part by part.
nonisolated struct ExploreStamp: Codable, Equatable, Sendable {
    var format: Int
    /// Days since 1970, UTC. See `ExplorePeriod`.
    var period: Int
    var personal: String
    var shared: String
    var deviceLocal: String
    /// The identity evidence the walks rested on, by content (see
    /// `IdentityGraph.evidenceDigest`). When it moves, the graph was rebuilt.
    /// Nil in a stamp written before artists had identities.
    var identity: String? = nil
    /// Who the listener already knows, under identity: what their history
    /// maps to and which artists that keeps out. When only this moves, the
    /// same knowledge was ranked again.
    var known: String? = nil

    init(period: Int, personal: PersonalInputs, knowledge: KnowledgeSnapshot) {
        self.init(
            format: knowledge.format, period: period, personal: CanonicalDigest.of(personal),
            shared: CanonicalDigest.of(knowledge.shared), deviceLocal: CanonicalDigest.of(knowledge.deviceLocal)
        )
    }

    init(format: Int, period: Int, personal: String, shared: String, deviceLocal: String) {
        self.format = format
        self.period = period
        self.personal = personal
        self.shared = shared
        self.deviceLocal = deviceLocal
    }
}

/// One look's inputs, digested, and what they cost.
nonisolated struct ExploreRun: Sendable {
    let personal: PersonalInputs
    let knowledge: KnowledgeSnapshot
    let stamp: ExploreStamp
    let report: ExploreBuildReport
    /// Artists the listener knows beyond their own rows' keys — see
    /// `KnownArtistPolicy`. Kept out before anything is cut.
    var alsoKnown: Set<String> = []
    /// The rows as kept, before they were read under identity: what the
    /// second half of a look is handed, so it reads them the same way.
    var rows: PersonalInputs = .empty
}

/// What building a look's inputs did: which parts were worked out rather than
/// kept, how long each took, and how big the result is.
nonisolated struct ExploreBuildReport: Codable, Equatable, Sendable {
    var rebuilt: [String] = []
    var milliseconds: [String: Double] = [:]
    /// Canonical-encoding sizes of each part, the bytes its digest covers.
    var bytes: [String: Int] = [:]
    var counts: [String: Int] = [:]
}

/// The day an answer is worked out for.
///
/// Listening is weighed by how long ago it was, so an answer depends on *when*
/// as well as on the rows. Measured from the end of the UTC day (`asOf`), the
/// same rows give the same answer all day on every device, and the next day is
/// a change of input like any other. The clock decides only which day it is.
nonisolated enum ExplorePeriod {
    static let length: TimeInterval = 24 * 60 * 60

    static func containing(_ moment: Date) -> Int {
        Int((moment.timeIntervalSince1970 / length).rounded(.down))
    }

    /// The end of the period: no play inside it is in its future.
    static func asOf(_ period: Int) -> Date {
        Date(timeIntervalSince1970: Double(period + 1) * length)
    }
}

// MARK: - Canonical digests

/// SHA-256 of a value's canonical encoding, as lowercase hex.
///
/// Canonical meaning the same value is the same bytes on every device and
/// every run, whatever produced it:
/// - objects (structs and `[String: _]` dictionaries) are written with their
///   keys in the byte order of their UTF-8, never in dictionary order;
/// - strings are NFC-normalised first, so the two spellings of "ö" that Swift
///   already treats as one string are one string here too;
/// - doubles are their IEEE-754 bit pattern, with -0 written as 0 and every
///   NaN as one NaN; dates are their seconds since 2001 as such a double;
/// - integers are 64-bit big-endian; arrays keep their order, which the types
///   above make an order of content; every value carries a type tag and every
///   string and container its length, so no two values share an encoding.
nonisolated enum CanonicalDigest {
    static func of<T: Encodable>(_ value: T) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4_096)
        CanonicalValue.encode(value).write(into: &bytes)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest and how many bytes it covered, in one encoding.
    static func digestAndSize<T: Encodable>(of value: T) -> (digest: String, bytes: Int) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64 * 1_024)
        CanonicalValue.encode(value).write(into: &bytes)
        return (SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes.count)
    }

    /// The bytes themselves, for a test.
    static func bytes<T: Encodable>(of value: T) -> [UInt8] {
        var bytes: [UInt8] = []
        CanonicalValue.encode(value).write(into: &bytes)
        return bytes
    }
}

nonisolated indirect enum CanonicalValue: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])

    static func encode<T: Encodable>(_ value: T) -> CanonicalValue {
        let root = CanonicalNode()
        // Encoding into a tree of plain values cannot fail on its own; a type
        // that throws while encoding is a programming error.
        try! value.encode(to: CanonicalEncoder(node: root))
        return root.resolved
    }

    func write(into bytes: inout [UInt8]) {
        func u64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) } }
        func string(_ value: String) {
            let utf8 = Array(value.precomposedStringWithCanonicalMapping.utf8)
            u64(UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        switch self {
        case .null: bytes.append(0)
        case .bool(let value): bytes.append(1); bytes.append(value ? 1 : 0)
        case .int(let value): bytes.append(2); u64(UInt64(bitPattern: value))
        case .uint(let value): bytes.append(3); u64(value)
        case .double(let value):
            bytes.append(4)
            let normal: Double = value.isNaN ? .nan : (value == 0 ? 0 : value)
            u64(normal.isNaN ? 0x7FF8_0000_0000_0000 : normal.bitPattern)
        case .string(let value): bytes.append(5); string(value)
        case .array(let items):
            bytes.append(6); u64(UInt64(items.count))
            for item in items { item.write(into: &bytes) }
        case .object(let fields):
            bytes.append(7); u64(UInt64(fields.count))
            let keyed = fields.map { (Array($0.key.precomposedStringWithCanonicalMapping.utf8), $0.value) }
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            for (key, value) in keyed {
                u64(UInt64(key.count)); bytes.append(contentsOf: key)
                value.write(into: &bytes)
            }
        }
    }
}

/// A place in the tree being encoded.
nonisolated final class CanonicalNode {
    var value: CanonicalValue?
    var fields: [String: CanonicalNode]?
    var items: [CanonicalNode]?

    var resolved: CanonicalValue {
        if let fields { return .object(fields.mapValues(\.resolved)) }
        if let items { return .array(items.map(\.resolved)) }
        return value ?? .null
    }
}

nonisolated struct CanonicalEncoder: Encoder {
    let node: CanonicalNode
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if node.fields == nil { node.fields = [:] }
        return KeyedEncodingContainer(Keyed<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if node.items == nil { node.items = [] }
        return Unkeyed(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        Single(node: node, codingPath: codingPath)
    }

    fileprivate static func put<T: Encodable>(_ value: T, in node: CanonicalNode, path: [any CodingKey]) throws {
        switch value {
        case let value as Bool: node.value = .bool(value)
        case let value as String: node.value = .string(value)
        case let value as Double: node.value = .double(value)
        case let value as Float: node.value = .double(Double(value))
        case let value as Int: node.value = .int(Int64(value))
        case let value as Int8: node.value = .int(Int64(value))
        case let value as Int16: node.value = .int(Int64(value))
        case let value as Int32: node.value = .int(Int64(value))
        case let value as Int64: node.value = .int(value)
        case let value as UInt: node.value = .uint(UInt64(value))
        case let value as UInt8: node.value = .uint(UInt64(value))
        case let value as UInt16: node.value = .uint(UInt64(value))
        case let value as UInt32: node.value = .uint(UInt64(value))
        case let value as UInt64: node.value = .uint(value)
        // Written as what they are, not as however their own `encode` chooses
        // to spell them.
        case let value as Date: node.value = .double(value.timeIntervalSinceReferenceDate)
        case let value as URL: node.value = .string(value.absoluteString)
        default: try value.encode(to: CanonicalEncoder(node: node, codingPath: path))
        }
    }

    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let node: CanonicalNode
        var codingPath: [any CodingKey]

        private func child(_ key: Key) -> CanonicalNode {
            let child = CanonicalNode()
            node.fields?[key.stringValue] = child
            return child
        }

        mutating func encodeNil(forKey key: Key) throws { child(key).value = .null }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try CanonicalEncoder.put(value, in: child(key), path: codingPath + [key])
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            CanonicalEncoder(node: child(key), codingPath: codingPath + [key]).container(keyedBy: keyType)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            CanonicalEncoder(node: child(key), codingPath: codingPath + [key]).unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder { CanonicalEncoder(node: node, codingPath: codingPath) }
        mutating func superEncoder(forKey key: Key) -> any Encoder { CanonicalEncoder(node: child(key), codingPath: codingPath + [key]) }
    }

    private struct Unkeyed: UnkeyedEncodingContainer {
        let node: CanonicalNode
        var codingPath: [any CodingKey]
        var count: Int { node.items?.count ?? 0 }

        private func next() -> CanonicalNode {
            let child = CanonicalNode()
            node.items?.append(child)
            return child
        }

        mutating func encodeNil() throws { next().value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws {
            try CanonicalEncoder.put(value, in: next(), path: codingPath)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            CanonicalEncoder(node: next(), codingPath: codingPath).container(keyedBy: keyType)
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            CanonicalEncoder(node: next(), codingPath: codingPath).unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder { CanonicalEncoder(node: next(), codingPath: codingPath) }
    }

    private struct Single: SingleValueEncodingContainer {
        let node: CanonicalNode
        var codingPath: [any CodingKey]
        mutating func encodeNil() throws { node.value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws {
            try CanonicalEncoder.put(value, in: node, path: codingPath)
        }
    }
}
