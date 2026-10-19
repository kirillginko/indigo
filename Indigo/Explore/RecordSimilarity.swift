//
//  RecordSimilarity.swift
//  Indigo
//
//  Records like the ones somebody keeps: album, genre and scene similarity
//  from what the record documents themselves say, and nothing else -- no
//  listening data from another service, no scraped ratings.
//
//  Three ways of judging, so they can be compared on the same pool:
//
//  - **Metadata**: the styles two records share, each weighted by how rare it
//    is in the pool (sharing "Slowcore" says more than sharing "Rock"), their
//    genres, how close in time they were made, a shared label, a scene their
//    artists share, and the players, writers and producers on both -- the
//    musical credits only (`ContributorRole`): a shared mastering engineer is
//    not a resemblance.
//  - **Embedding**: each style as the company it keeps across the pool -- its
//    positive pointwise mutual information with every other style -- and a
//    record as the rarity-weighted sum of its styles' vectors. Two records
//    that share no style can still be close: "Slowcore" and "Sadcore" keep
//    the same company. Learned from the pool on the device, deterministic,
//    no model downloaded.
//  - **Hybrid**: the two halves together, with the credits, label and scene
//    as evidence on top.
//
//  A pure function of the pool, the seed and the arguments: summed in a fixed
//  order, so the same pool on two devices gives the same scores to the bit.
//  Development and internal builds only, on For You (`SimilarRecordsFeature`).
//

import Foundation

nonisolated enum SimilarRecordsFeature {
    #if DEBUG
    static let switchKey = "INDIGO_FORYOU_SIMILAR"
    #endif
    nonisolated(unsafe) static var override: Bool?

    static var isEnabled: Bool {
        if let override { return override }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: switchKey)
        #elseif INDIGO_INTERNAL
        // An internal TestFlight archive: on, with no switch to turn.
        return true
        #else
        return false
        #endif
    }
}

/// What a record is, as similarity reads it.
nonisolated struct RecordProfile: Equatable, Sendable, Codable {
    let id: Int
    let title: String
    let artists: [String]
    /// Folded artist names, and the Discogs entries where the document gives them.
    let artistKeys: Set<String>
    var artistIDs: Set<Int> = []
    /// Folded, in the document's order.
    let styles: [String]
    let genres: [String]
    let year: Int?
    /// Folded label names, placeholders left out.
    let labels: Set<String>
    /// The musical and creative credits: "id:409922" where the document names
    /// the entry, "name:fred seibert" where it does not.
    var personnel: Set<String> = []
    /// Display names for `personnel`, for the reason line.
    var personnelNames: [String: String] = [:]
    var artworkURL: URL? = nil

    var artistLine: String { artists.joined(separator: ", ") }
}

nonisolated extension RecordProfile {
    private static func fold(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func labels(_ names: [String]) -> Set<String> {
        Set(names.filter(LabelName.isRealLabel).map(RecordingKey.normalize).filter { !$0.isEmpty })
    }

    /// From a release DIG has cached: credits by name only.
    init(record: DiscogsReleaseRecord) {
        var personnel = Set<String>(), names: [String: String] = [:]
        let headline = Set(record.artistNames.map { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator($0)) })
        for (index, name) in record.creditNames.enumerated() where ArtistName.isRealArtist(name) {
            let role = index < record.creditRoles.count ? record.creditRoles[index] : ""
            guard ContributorRole.of(credit: role)?.leadsToSomebody == true else { continue }
            let key = RecordingKey.normalizeArtist(name)
            guard !key.isEmpty, !headline.contains(key) else { continue }
            personnel.insert("name:\(key)")
            names["name:\(key)"] = name
        }
        self.init(id: record.discogsID, title: record.title, artists: record.artistNames.map(DiscogsClient.withoutDisambiguator),
                  artistKeys: headline, styles: Self.fold(record.styles), genres: Self.fold(record.genres),
                  year: record.year.flatMap { $0 > 0 ? $0 : nil }, labels: Self.labels(record.labelNames),
                  personnel: personnel, personnelNames: names, artworkURL: record.imageURLString.flatMap(URL.init(string:)))
    }

    /// From a release document: credits by entry.
    init(detail: DiscogsReleaseDetail) {
        let artists = (detail.artists ?? []).compactMap { $0.name.map(DiscogsClient.withoutDisambiguator) }
        let headline = Set(artists.map(RecordingKey.normalizeArtist))
        let headlineIDs = Set((detail.artists ?? []).compactMap(\.id))
        var personnel = Set<String>(), names: [String: String] = [:]
        for credit in detail.extraartists ?? [] {
            guard let name = credit.name.map(DiscogsClient.withoutDisambiguator), ArtistName.isRealArtist(name),
                  ContributorRole.of(credit: credit.role)?.leadsToSomebody == true else { continue }
            if let id = credit.id, headlineIDs.contains(id) { continue }
            let key = credit.id.map { "id:\($0)" } ?? "name:\(RecordingKey.normalizeArtist(name))"
            guard !headline.contains(RecordingKey.normalizeArtist(name)) else { continue }
            personnel.insert(key)
            names[key] = name
        }
        self.init(id: detail.id, title: detail.title, artists: artists, artistKeys: headline, artistIDs: headlineIDs,
                  styles: Self.fold(detail.styles ?? []), genres: Self.fold(detail.genres ?? []),
                  year: detail.year.flatMap { $0 > 0 ? $0 : nil },
                  labels: Self.labels((detail.labels ?? []).compactMap(\.name)), personnel: personnel, personnelNames: names)
    }
}

nonisolated struct RecordSimilarity: Sendable {
    enum Mode: String, Sendable, CaseIterable { case metadata, embedding, hybrid }

    /// A record found, how close, and why in a line.
    struct Match: Equatable, Sendable {
        let record: RecordProfile
        let score: Double
        let metadata: Double
        let embedding: Double
        let reason: String
    }

    let pool: [RecordProfile]
    /// How rare each style is in the pool: log(N / records with it).
    let idf: [String: Double]
    /// How rare each label is in the pool, the same way: a small label two
    /// records share says much more than a major's.
    let labelIDF: [String: Double]
    /// Each style's company: PPMI with every style it appears beside,
    /// itself included, normalised.
    let vectors: [String: [String: Double]]
    /// Scenes each artist key is in, when known.
    let scenes: [String: Set<String>]
    /// Every pool record's embedding, normalised.
    let embeddings: [Int: [String: Double]]

    init(pool: [RecordProfile], scenes: [String: Set<String>] = [:]) {
        // One profile per record id; the first wins, the pool sorted by id.
        var seen = Set<Int>()
        let pool = pool.sorted { $0.id < $1.id }.filter { seen.insert($0.id).inserted }
        self.pool = pool
        self.scenes = scenes
        var count: [String: Double] = [:]
        var pairs: [String: [String: Double]] = [:]
        var labelCount: [String: Double] = [:]
        for record in pool {
            for label in record.labels { labelCount[label, default: 0] += 1 }
            let styles = Set(record.styles)
            for style in styles {
                count[style, default: 0] += 1
                for other in styles { pairs[style, default: [:]][other, default: 0] += 1 }
            }
        }
        let total = Double(max(1, pool.count))
        idf = count.mapValues { log((total + 1) / ($0 + 0.5)) }
        labelIDF = labelCount.mapValues { log((total + 1) / ($0 + 0.5)) }
        var rowTotals: [String: Double] = [:]
        for style in pairs.keys.sorted() {
            let row = pairs[style] ?? [:]
            rowTotals[style] = row.keys.sorted().reduce(0.0) { $0 + (row[$1] ?? 0) }
        }
        let pairTotal = rowTotals.keys.sorted().reduce(0.0) { $0 + (rowTotals[$1] ?? 0) }
        var vectors: [String: [String: Double]] = [:]
        for style in pairs.keys.sorted() {
            var row: [String: Double] = [:]
            let found = pairs[style] ?? [:]
            for other in found.keys.sorted() {
                let pmi = log(((found[other] ?? 0) * pairTotal) / max(1e-9, (rowTotals[style] ?? 0) * (rowTotals[other] ?? 0)))
                if pmi > 0 { row[other] = pmi }
            }
            vectors[style] = Self.normalised(row)
        }
        self.vectors = vectors
        var embeddings: [Int: [String: Double]] = [:]
        for record in pool {
            embeddings[record.id] = Self.normalised(Self.embedding(record, idf: idf, vectors: vectors, poolSize: pool.count))
        }
        self.embeddings = embeddings
    }

    private static func normalised(_ vector: [String: Double]) -> [String: Double] {
        let length = sqrt(vector.keys.sorted().reduce(0.0) { $0 + (vector[$1] ?? 0) * (vector[$1] ?? 0) })
        guard length > 0 else { return vector }
        return vector.mapValues { $0 / length }
    }

    /// Two normalised vectors' dot product, summed in a fixed order.
    private static func dot(_ left: [String: Double], _ right: [String: Double]) -> Double {
        let (small, large) = left.count <= right.count ? (left, right) : (right, left)
        return max(0, min(1, small.keys.sorted().reduce(0.0) { $0 + (small[$1] ?? 0) * (large[$1] ?? 0) }))
    }

    private static func embedding(_ record: RecordProfile, idf: [String: Double], vectors: [String: [String: Double]],
                                  poolSize: Int) -> [String: Double] {
        var sum: [String: Double] = [:]
        for style in Set(record.styles).sorted() {
            let weight = idf[style] ?? log(Double(poolSize + 1) / 0.5)
            let vector = vectors[style] ?? [style: 1]
            for key in vector.keys.sorted() { sum[key, default: 0] += weight * (vector[key] ?? 0) }
        }
        return sum
    }

    /// A record as the rarity-weighted sum of its styles' company, normalised.
    func embedding(_ record: RecordProfile) -> [String: Double] {
        Self.normalised(Self.embedding(record, idf: idf, vectors: vectors, poolSize: pool.count))
    }

    /// Rarity-weighted overlap of two style sets, 0...1.
    func styleOverlap(_ left: RecordProfile, _ right: RecordProfile) -> Double {
        let a = Set(left.styles), b = Set(right.styles)
        func weight(_ set: Set<String>) -> Double { set.sorted().reduce(0.0) { $0 + (idf[$1] ?? 1) } }
        let shared = weight(a.intersection(b))
        let norm = sqrt(weight(a) * weight(b))
        return norm > 0 ? shared / norm : 0
    }

    private func sharedScenes(_ left: RecordProfile, _ right: RecordProfile) -> Set<String> {
        let a = left.artistKeys.reduce(into: Set<String>()) { $0.formUnion(scenes[$1] ?? []) }
        let b = right.artistKeys.reduce(into: Set<String>()) { $0.formUnion(scenes[$1] ?? []) }
        return a.intersection(b)
    }

    /// The same artist, or a reissue of the same record: never "like" it.
    static func isSameWork(_ left: RecordProfile, _ right: RecordProfile) -> Bool {
        if left.id == right.id { return true }
        if !left.artistIDs.isDisjoint(with: right.artistIDs) { return true }
        return !left.artistKeys.isDisjoint(with: right.artistKeys)
    }

    /// One candidate judged against a seed.
    func judge(_ candidate: RecordProfile, against seed: RecordProfile, seedEmbedding: [String: Double]? = nil,
               mode: Mode = .hybrid) -> Match {
        // A record tagged with one style matches anything else with it
        // perfectly, and that is weak evidence: the overlap counts in full
        // from two styles up.
        let coverage = min(1, Double(Set(seed.styles).count) / 2)
        let styles = styleOverlap(seed, candidate) * coverage
        let genresA = Set(seed.genres), genresB = Set(candidate.genres)
        let genres = genresA.isEmpty || genresB.isEmpty ? 0
            : Double(genresA.intersection(genresB).count) / Double(genresA.union(genresB).count)
        let resembles = styles > 0 || genres > 0
        let era: Double = {
            guard resembles, let a = seed.year, let b = candidate.year else { return 0 }
            let gap = Double(abs(a - b)) / 8
            return exp(-gap * gap)
        }()
        // A shared label by its rarity, 0...1: the pool's rarest label is 1.
        let rarest = log(Double(pool.count + 1) / 0.5)
        let label = seed.labels.intersection(candidate.labels).map { min(1, (labelIDF[$0] ?? rarest) / rarest) }.max() ?? 0
        let people = seed.personnel.intersection(candidate.personnel).sorted()
        let scene = sharedScenes(seed, candidate)
        // Evidence that two records belong together, beyond how they are
        // tagged: the same players, a small label, a scene.
        let evidence = min(1, Double(people.count) / 2) * 0.25 + label * 0.35 + (scene.isEmpty ? 0 : 0.08)
        // Era only breaks ties between records alike in other ways.
        let metadata = styles * 0.6 + genres * 0.15 + era * 0.05 + evidence
        // The same for the embedding: one style's company is all a
        // one-style record has to go on.
        let embedding = Self.dot(seedEmbedding ?? self.embedding(seed), embeddings[candidate.id] ?? self.embedding(candidate)) * coverage
        let score: Double
        switch mode {
        case .metadata: score = metadata
        case .embedding: score = embedding
        case .hybrid: score = 0.5 * (styles * 0.6 + genres * 0.15 + era * 0.05) + 0.5 * embedding * 0.8 + evidence
        }

        var parts: [String] = []
        let sharedStyles = Set(seed.styles).intersection(candidate.styles)
            .sorted { (idf[$0] ?? 0) != (idf[$1] ?? 0) ? (idf[$0] ?? 0) > (idf[$1] ?? 0) : $0 < $1 }
        if !sharedStyles.isEmpty {
            parts.append(sharedStyles.prefix(2).map(Self.titled).joined(separator: ", "))
        } else if embedding > 0.3, let near = nearestStyles(seed, candidate) {
            parts.append("\(Self.titled(near.0)) ~ \(Self.titled(near.1))")
        }
        if let name = people.first.flatMap({ candidate.personnelNames[$0] ?? seed.personnelNames[$0] }) {
            parts.append(people.count > 1 ? "\(name) and \(people.count - 1) more on both" : "\(name) on both")
        }
        if label > 0, let shared = seed.labels.intersection(candidate.labels)
            .max(by: { (labelIDF[$0] ?? 0, $1) < (labelIDF[$1] ?? 0, $0) }) {
            parts.append("both on \(Self.titled(shared))")
        }
        if let year = candidate.year, era > 0.5 { parts.append(String(year)) }
        return Match(record: candidate, score: score, metadata: metadata, embedding: embedding,
                     reason: parts.isEmpty ? "Close in sound" : parts.joined(separator: " · "))
    }

    /// The pair of styles, one from each, that keep the most company.
    private func nearestStyles(_ seed: RecordProfile, _ candidate: RecordProfile) -> (String, String)? {
        var best: (String, String, Double)?
        for a in Set(seed.styles).sorted() {
            for b in Set(candidate.styles).sorted() where a != b {
                let value = vectors[a]?[b] ?? 0
                if value > (best?.2 ?? 0) { best = (a, b, value) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func titled(_ folded: String) -> String {
        folded.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The closest records to a seed, one per artist, none by the seed's own
    /// artists and none in `excluding` (release ids).
    func similar(to seed: RecordProfile, limit: Int = 10, mode: Mode = .hybrid,
                 excluding: Set<Int> = [], minimum: Double = 0.12) -> [Match] {
        let seedEmbedding = embedding(seed)
        var found: [Match] = []
        for candidate in pool where !excluding.contains(candidate.id) && !Self.isSameWork(seed, candidate) {
            guard !candidate.styles.isEmpty || !candidate.genres.isEmpty else { continue }
            let match = judge(candidate, against: seed, seedEmbedding: seedEmbedding, mode: mode)
            if match.score >= minimum { found.append(match) }
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.record.id < $1.record.id }
        // One per artist: a joint record counts for each of its artists.
        var artists = Set<String>(), chosen: [Match] = []
        for match in found where chosen.count < limit {
            guard artists.isDisjoint(with: match.record.artistKeys) else { continue }
            artists.formUnion(match.record.artistKeys)
            chosen.append(match)
        }
        return chosen
    }

    /// For several seeds at once -- what For You asks -- each candidate under
    /// its best seed, one per artist, at most `perSeed` from any one seed.
    func similar(to seeds: [RecordProfile], limit: Int = 8, perSeed: Int = 3,
                 excluding: Set<Int> = [], excludingArtists: Set<String> = []) -> [(match: Match, seed: RecordProfile)] {
        var best: [Int: (match: Match, seed: RecordProfile)] = [:]
        let seedIDs = Set(seeds.map(\.id))
        for seed in seeds {
            for match in similar(to: seed, limit: limit * 3, excluding: excluding.union(seedIDs))
            where match.record.artistKeys.isDisjoint(with: excludingArtists)
                && !seeds.contains(where: { Self.isSameWork($0, match.record) }) {
                if let held = best[match.record.id], held.match.score >= match.score { continue }
                best[match.record.id] = (match, seed)
            }
        }
        let ranked = best.values.sorted {
            $0.match.score != $1.match.score ? $0.match.score > $1.match.score : $0.match.record.id < $1.match.record.id
        }
        var artists = Set<String>(), perVia: [Int: Int] = [:], chosen: [(match: Match, seed: RecordProfile)] = []
        for entry in ranked where chosen.count < limit {
            guard perVia[entry.seed.id, default: 0] < perSeed, artists.isDisjoint(with: entry.match.record.artistKeys) else { continue }
            artists.formUnion(entry.match.record.artistKeys)
            perVia[entry.seed.id, default: 0] += 1
            chosen.append(entry)
        }
        return chosen
    }
}
