//
//  MusicalCompass.swift
//  Indigo
//
//  Where the listener's taste is, where it is heading, and where each thing
//  For You offers would take them: a map with two axes, drawn from their own
//  music rather than from a fixed set of genres.
//
//  - The space is the style embedding Records like yours already learns from
//    the records DIG holds (`RecordSimilarity.vectors`): a style as the
//    company it keeps. Tags it has no vector for stand for themselves.
//  - The axes are the two directions along which the listener's long-term
//    interests differ most -- the first two principal components of their
//    strongest interests, weighted by how strong each is -- found by power
//    iteration from a fixed start, so every device draws the same axes. Each
//    end is named by the interest furthest along it: "Free Jazz ↔ Techno".
//  - "You" is the centre of what they have kept and played over time; "Now"
//    the centre of the last fortnight. The arrow between them is the
//    direction they are moving in.
//  - Each offer is placed by its own tags, with how far it is from "You"
//    (one minus the cosine) and, in words, which way it leads.
//
//  Pure: the same tags, weights and vectors draw the same compass, to the bit.
//

import Foundation

nonisolated struct MusicalCompass: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let id: String
        let x: Double
        let y: Double
        /// 0 at "You", 1 for nothing in common.
        let distance: Double
        /// "Toward Slowcore", "Close to home".
        let heading: String
    }

    /// The ends of each axis: (negative, positive).
    let horizontal: (String, String)
    let vertical: (String, String)
    let you: Point
    let now: Point?
    let points: [Point]

    static func == (left: MusicalCompass, right: MusicalCompass) -> Bool {
        left.horizontal == right.horizontal && left.vertical == right.vertical && left.you == right.you
            && left.now == right.now && left.points == right.points
    }

    typealias Vector = [String: Double]

    // MARK: Vectors

    /// A set of weighted tags in the style space, normalised.
    static func embed(_ weights: [String: Double], vectors: [String: Vector]) -> Vector {
        var sum: Vector = [:]
        for tag in weights.keys.sorted() {
            let weight = weights[tag] ?? 0
            guard weight > 0 else { continue }
            let vector = vectors[tag] ?? [tag: 1]
            for key in vector.keys.sorted() { sum[key, default: 0] += weight * (vector[key] ?? 0) }
        }
        return normalised(sum)
    }

    static func normalised(_ vector: Vector) -> Vector {
        let length = sqrt(vector.keys.sorted().reduce(0.0) { $0 + (vector[$1] ?? 0) * (vector[$1] ?? 0) })
        return length > 0 ? vector.mapValues { $0 / length } : vector
    }

    static func dot(_ left: Vector, _ right: Vector) -> Double {
        let (small, large) = left.count <= right.count ? (left, right) : (right, left)
        return small.keys.sorted().reduce(0.0) { $0 + (small[$1] ?? 0) * (large[$1] ?? 0) }
    }

    private static func add(_ left: Vector, _ right: Vector, scale: Double) -> Vector {
        var out = left
        for key in right.keys.sorted() { out[key, default: 0] += scale * (right[key] ?? 0) }
        return out
    }

    // MARK: Axes

    /// The `count` strongest directions in which weighted interest vectors
    /// differ, by power iteration with deflation from a fixed start.
    static func principalAxes(_ rows: [(vector: Vector, weight: Double)], count: Int = 2, iterations: Int = 60) -> [Vector] {
        guard !rows.isEmpty else { return [] }
        // Centred on their weighted mean, so the axes are about difference.
        let total = rows.reduce(0.0) { $0 + $1.weight }
        var mean: Vector = [:]
        for row in rows { mean = add(mean, row.vector, scale: row.weight / max(total, 1e-9)) }
        let centred = rows.map { (vector: add($0.vector, mean, scale: -1), weight: $0.weight) }
        let dimensions = Set(centred.flatMap(\.vector.keys)).sorted()
        var axes: [Vector] = []
        for index in 0..<count {
            // A fixed, deterministic start: not all ones, or the second axis
            // could begin orthogonal to nothing in particular.
            var axis = normalised(Dictionary(uniqueKeysWithValues: dimensions.enumerated().map {
                ($0.element, 1 + Double(($0.offset * 7 + index * 3) % 11) / 11)
            }))
            for _ in 0..<iterations {
                var next: Vector = [:]
                for row in centred {
                    let projection = dot(row.vector, axis) * row.weight
                    next = add(next, row.vector, scale: projection)
                }
                for found in axes { next = add(next, found, scale: -dot(next, found)) }
                let normal = normalised(next)
                guard !normal.isEmpty else { break }
                axis = normal
            }
            // A sign that does not depend on the start: the heaviest
            // component positive.
            if let heaviest = axis.keys.sorted().max(by: { abs(axis[$0] ?? 0) < abs(axis[$1] ?? 0) }),
               (axis[heaviest] ?? 0) < 0 {
                axis = axis.mapValues { -$0 }
            }
            axes.append(axis)
        }
        return axes
    }

    private static func titled(_ tag: String) -> String {
        tag.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: The compass

    /// - Parameters:
    ///   - longTerm: interest → weight over time (`TasteProfile.weights`).
    ///   - recent: the same for the last fortnight; empty when quiet.
    ///   - items: what is offered, by id, with its tags.
    static func draw(longTerm allLongTerm: [String: Double], recent allRecent: [String: Double],
                     items allItems: [(id: String, tags: [String])],
                     vectors: [String: Vector], interests: Int = 24) -> MusicalCompass? {
        // Only styles the space knows: a station's "talk" or "interview" tag
        // is not a direction in music, and an unknown tag has no company.
        let known = { (tag: String) in vectors[tag] != nil }
        let longTerm = allLongTerm.filter { known($0.key) }
        let recent = allRecent.filter { known($0.key) }
        let items = allItems.map { (id: $0.id, tags: $0.tags.filter(known)) }

        let strongest = longTerm.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(interests)
        guard strongest.count >= 3 else { return nil }
        let rows = strongest.map { (vector: normalised(vectors[$0.key] ?? [:]), weight: $0.value) }
        let axes = principalAxes(rows)
        guard axes.count == 2 else { return nil }
        let you = embed(Dictionary(uniqueKeysWithValues: strongest.map { ($0.key, $0.value) }), vectors: vectors)

        // Each axis's ends: of the interests and the offers' styles, the one
        // furthest along it each way; the second axis never repeats a name
        // the first has.
        let named = Set(strongest.map(\.key) + items.flatMap(\.tags)).sorted()
        func ends(_ axis: Vector, avoiding: Set<String>) -> (String, String) {
            var low: (String, Double)?, high: (String, Double)?
            for tag in named where !avoiding.contains(tag) {
                let value = dot(normalised(vectors[tag] ?? [:]), axis)
                if value < (low?.1 ?? .infinity) { low = (tag, value) }
                if value > (high?.1 ?? -.infinity) { high = (tag, value) }
            }
            return (low?.0 ?? "–", high?.0 ?? "–")
        }
        let across = ends(axes[0], avoiding: [])
        let up = ends(axes[1], avoiding: [across.0, across.1])

        // Which way something leads: of its styles that are not already
        // strong in their taste, the one most like the thing as a whole.
        func heading(_ vector: Vector, tags: [String]) -> String {
            let fresh = tags.filter { (longTerm[$0] ?? 0) < 0.3 }
            guard let best = fresh.max(by: { (dot(normalised(vectors[$0] ?? [:]), vector), $1) < (dot(normalised(vectors[$1] ?? [:]), vector), $0) })
            else { return "Close to home" }
            return "Toward \(titled(best))"
        }

        func place(_ id: String, _ vector: Vector, heading: String) -> Point {
            let similarity = max(0, min(1, dot(vector, you)))
            return Point(id: id, x: dot(vector, axes[0]) - dot(you, axes[0]), y: dot(vector, axes[1]) - dot(you, axes[1]),
                         distance: 1 - similarity, heading: similarity > 0.85 ? "Close to home" : heading)
        }

        let youPoint = Point(id: "you", x: 0, y: 0, distance: 0, heading: "Over time")
        var nowPoint: Point?
        if !recent.isEmpty {
            // Now heads where taste rose most against the long run.
            let rising = recent.keys.sorted().max { (recent[$0]! - (longTerm[$0] ?? 0), $1) < (recent[$1]! - (longTerm[$1] ?? 0), $0) }
            nowPoint = place("now", embed(recent, vectors: vectors), heading: rising.map { "Toward \(titled($0))" } ?? "Close to home")
        }
        var points: [Point] = []
        for item in items where !item.tags.isEmpty {
            let vector = embed(Dictionary(item.tags.map { ($0, 1.0) }, uniquingKeysWith: { first, _ in first }), vectors: vectors)
            points.append(place(item.id, vector, heading: heading(vector, tags: item.tags)))
        }
        // Scaled so the furthest point sits on the edge.
        let reach = max(1e-9, ([nowPoint].compactMap { $0 } + points).map { max(abs($0.x), abs($0.y)) }.max() ?? 1)
        func scaled(_ point: Point) -> Point {
            Point(id: point.id, x: point.x / reach, y: point.y / reach, distance: point.distance, heading: point.heading)
        }
        return MusicalCompass(horizontal: (titled(across.0), titled(across.1)), vertical: (titled(up.0), titled(up.1)),
                              you: youPoint, now: nowPoint.map(scaled), points: points.map(scaled))
    }

    /// The listener's last fortnight, as a taste: plays and crated records in
    /// that window only.
    static func recentTaste(_ personal: PersonalInputs, artistTags: [String: [String]], asOf: Date,
                            window: TimeInterval = 14 * 24 * 60 * 60) -> [String: Double] {
        var recent = personal
        recent.plays = personal.plays.filter { asOf.timeIntervalSince($0.at) <= window }
        recent.crate = personal.crate.filter { asOf.timeIntervalSince($0.addedAt) <= window }
        guard !recent.plays.isEmpty || !recent.crate.isEmpty else { return [:] }
        return TasteProfile.collected(personal: recent, artistTags: artistTags, now: asOf).weights
    }
}
