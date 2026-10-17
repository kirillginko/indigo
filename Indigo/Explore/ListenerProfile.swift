//
//  ListenerProfile.swift
//  Indigo
//
//  Listener Profile v2 (prototype): the listener's tastes as several
//  clusters over recordings, records and artists, rather than one bag of
//  tags and a dozen artist seeds.
//
//  `TasteProfile` adds every tag of every encounter into one vector, so a
//  month of jazz and a month of techno average into neither, and a station's
//  "talk" tag counts as a taste; the starting points then collapse all of it
//  into twelve artists (19% of this Mac's positive listening). Here:
//
//  - **Evidence** is kept at the most specific level the history has: the
//    recording played, the record crated or opened, the artist only when
//    nothing narrower is known. Editions of one record fold by title and
//    artist; an alias stays its own project (one person is known through
//    `sameArtist`, keyed by Discogs id, never by a display name).
//  - **Weight** follows intent: crating and saving above a full listen,
//    a full listen above a short one, and browsing DIG pages lightest of
//    all. A skip is ambiguous -- a station sampled, a track not now -- and is
//    counted, never subtracted; only a dismissal argues against something.
//  - **Time**: long-term weight is everything, damped so repetition counts
//    without drowning the rest; recent is the last fortnight, decayed by a
//    week's half-life; a style is *emerging* when its recent share is well
//    above its long-term one.
//  - **Sound**: each unit is placed in the style space Records like yours
//    learns (`RecordSimilarity.vectors`) from the record's own Discogs
//    styles, else the artist's, else the tags it was met with that the space
//    knows -- never a station's "talk".
//  - **Clusters**: units grouped by direction in that space, heaviest first,
//    deterministically; each cluster says what it sounds like, how much of
//    the listener's time it holds, now and over time, and on how much
//    evidence.
//
//  Pure: a function of the inputs and `asOf`, the same on every device for
//  the same synced rows and the same style space.
//

import Foundation
import SwiftData

nonisolated struct ListenerProfile: Equatable, Sendable {
    /// What a piece of evidence is about, most specific first.
    enum Level: String, Sendable, Codable { case recording, release, artist }

    /// How the listener showed it.
    enum Signal: String, Sendable, Codable, CaseIterable {
        case crated, saved, fullListen, partialListen, pageVisit, skipped, dismissed

        /// What it is worth before time. Deliberate first, browsing last; a
        /// skip nothing either way.
        var weight: Double {
            switch self {
            case .crated: 3
            case .saved: 2.5
            case .fullListen: 1
            case .partialListen: 0.4
            case .pageVisit: 0.15
            case .skipped: 0
            case .dismissed: -1
            }
        }
    }

    /// One thing the listener did, about one unit.
    struct Evidence: Equatable, Sendable {
        let unit: String
        let level: Level
        let artist: String
        let title: String
        let at: Date
        let signal: Signal
        /// 0...1 of the signal's weight actually earned (a listen's length).
        var strength: Double = 1
        var tags: [String] = []
    }

    /// A unit as the profile holds it.
    struct Unit: Equatable, Sendable {
        let id: String
        let level: Level
        let artist: String
        let title: String
        var longTerm: Double
        var recent: Double
        var lastAt: Date
        var styles: [String]
        /// Where the styles came from: "release", "artist", "tags" or "none".
        var styleSource: String
        var skips: Int
    }

    struct Cluster: Equatable, Sendable {
        let id: Int
        /// The styles nearest its centre, strongest first.
        let label: [String]
        /// Shares of the listener's weight, over time and in the fortnight.
        let longTermShare: Double
        let recentShare: Double
        let emerging: Bool
        /// The heaviest units in it.
        let examples: [Unit]
        let centroid: [String: Double]
        /// How many units, and how many listening events, it rests on.
        let units: Int
        let evidence: Int
        /// 0...1: how much of it rests on record-level styles and on more
        /// than one or two things.
        let confidence: Double
    }

    let asOf: Date
    let units: [Unit]
    let clusters: [Cluster]
    /// Styles rising: recent share well above long-term share.
    let emerging: [String]
    /// Of the positive long-term weight: styled by the record, by the artist,
    /// by tags only, or not at all.
    let coverage: [String: Double]
    let skips: Int
    let dismissals: Int

    // MARK: Building

    static let recentWindow: TimeInterval = 14 * 86_400
    static let recentHalfLife: TimeInterval = 7 * 86_400

    /// - Parameters:
    ///   - evidence: everything the listener did, any order.
    ///   - styles: a unit's styles by unit id (record, then artist), folded.
    ///   - artistStyles: by artist key, for units with none of their own.
    ///   - vectors: the style space (`RecordSimilarity.vectors`).
    ///
    /// An alias is a project of its own here: Caustic Window and Aphex Twin
    /// are one person but two sounds. `Read.sameArtist` says which names are
    /// one person, for leaving them out of recommendations, not for merging.
    static func build(evidence: [Evidence], styles: [String: [String]], artistStyles: [String: [String]],
                      vectors: [String: [String: Double]], asOf: Date,
                      maxClusters: Int = 8) -> ListenerProfile {
        var held: [String: Unit] = [:]
        var counts: [String: Int] = [:]
        var skips = 0, dismissals = 0
        // Raw sums first; long-term is damped below.
        var raw: [String: Double] = [:]
        let ordered = evidence.filter { $0.at <= asOf }.sorted {
            ($0.at, $0.unit, $0.signal.rawValue) < ($1.at, $1.unit, $1.signal.rawValue)
        }
        for item in ordered {
            let artist = item.artist
            let unitID = item.level == .artist ? "artist:\(artist)" : item.unit
            if item.signal == .skipped { skips += 1 }
            if item.signal == .dismissed { dismissals += 1 }
            var unit = held[unitID] ?? Unit(id: unitID, level: item.level, artist: artist, title: item.title,
                                            longTerm: 0, recent: 0, lastAt: item.at, styles: [], styleSource: "none", skips: 0)
            if item.signal == .skipped { unit.skips += 1 }
            let value = item.signal.weight * max(0, min(1, item.strength))
            raw[unitID, default: 0] += value
            let age = asOf.timeIntervalSince(item.at)
            if age <= recentWindow, value != 0 {
                unit.recent += value * pow(0.5, max(0, age) / recentHalfLife)
            }
            unit.lastAt = max(unit.lastAt, item.at)
            if !item.tags.isEmpty, unit.styles.isEmpty {
                // Only tags the style space knows: a station's "talk" is not a sound.
                let known = item.tags.filter { vectors[$0] != nil }
                if !known.isEmpty { unit.styles = known; unit.styleSource = "tags" }
            }
            counts[unitID, default: 0] += item.signal == .skipped ? 0 : 1
            held[unitID] = unit
        }
        for (id, var unit) in held {
            let sum = raw[id] ?? 0
            // log2(1 + x): forty plays outweigh two without drowning the crate.
            unit.longTerm = sum > 0 ? log2(1 + sum) : sum
            if let own = styles[id]?.filter({ vectors[$0] != nil }), !own.isEmpty {
                unit.styles = own; unit.styleSource = unit.level == .artist ? "artist" : "release"
            } else if unit.styleSource != "tags", let byArtist = artistStyles[unit.artist]?.filter({ vectors[$0] != nil }), !byArtist.isEmpty {
                unit.styles = byArtist; unit.styleSource = "artist"
            }
            held[id] = unit
        }
        let units = held.values.sorted { $0.longTerm != $1.longTerm ? $0.longTerm > $1.longTerm : $0.id < $1.id }
        let positive = units.filter { $0.longTerm > 0 }
        let totalLong = positive.reduce(0) { $0 + $1.longTerm }
        let totalRecent = positive.reduce(0) { $0 + max(0, $1.recent) }

        var coverage: [String: Double] = [:]
        for unit in positive { coverage[unit.styleSource, default: 0] += unit.longTerm / max(totalLong, 1e-9) }

        // Style shares, over time and now, for emerging.
        var longStyle: [String: Double] = [:], recentStyle: [String: Double] = [:]
        for unit in positive where !unit.styles.isEmpty {
            let share = 1 / Double(unit.styles.count)
            for style in unit.styles {
                longStyle[style, default: 0] += unit.longTerm * share
                recentStyle[style, default: 0] += max(0, unit.recent) * share
            }
        }
        let longSum = longStyle.values.reduce(0, +), recentSum = recentStyle.values.reduce(0, +)
        let emerging = recentStyle.keys.sorted().filter { style in
            let now = (recentStyle[style] ?? 0) / max(recentSum, 1e-9)
            let then = (longStyle[style] ?? 0) / max(longSum, 1e-9)
            return now >= 0.04 && now >= 2 * then
        }.sorted { (recentStyle[$0] ?? 0) > (recentStyle[$1] ?? 0) }

        let clusters = cluster(positive.filter { !$0.styles.isEmpty }, vectors: vectors, counts: counts,
                               totalLong: totalLong, totalRecent: totalRecent, emerging: Set(emerging), maxClusters: maxClusters)
        return ListenerProfile(asOf: asOf, units: units, clusters: clusters, emerging: emerging, coverage: coverage,
                               skips: skips, dismissals: dismissals)
    }

    // MARK: Clusters

    static func vector(_ styles: [String], _ vectors: [String: [String: Double]]) -> [String: Double] {
        MusicalCompass.embed(Dictionary(styles.map { ($0, 1.0) }, uniquingKeysWith: { first, _ in first }), vectors: vectors)
    }

    /// Heaviest first: each unit joins the nearest cluster it is close
    /// enough to, else starts one while there is room, else joins the
    /// nearest; clusters with under 4% of the weight are folded into their
    /// nearest neighbour. Ordered input, ordered output.
    private static func cluster(_ units: [Unit], vectors: [String: [String: Double]], counts: [String: Int],
                                totalLong: Double, totalRecent: Double, emerging: Set<String>, maxClusters: Int) -> [Cluster] {
        struct Draft { var sum: [String: Double]; var members: [Unit] }
        func normal(_ v: [String: Double]) -> [String: Double] { MusicalCompass.normalised(v) }
        var drafts: [Draft] = []
        for unit in units {
            let v = vector(unit.styles, vectors)
            guard !v.isEmpty else { continue }
            let scored = drafts.indices.map { ($0, MusicalCompass.dot(normal($0 < drafts.count ? drafts[$0].sum : [:]), v)) }
            let best = scored.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }
            let index: Int
            if let best, best.1 >= 0.45 || drafts.count >= maxClusters { index = best.0 }
            else { drafts.append(Draft(sum: [:], members: [])); index = drafts.count - 1 }
            for key in v.keys.sorted() { drafts[index].sum[key, default: 0] += unit.longTerm * (v[key] ?? 0) }
            drafts[index].members.append(unit)
        }
        // Fold the small into their nearest.
        func weight(_ d: Draft) -> Double { d.members.reduce(0) { $0 + $1.longTerm } }
        var changed = true
        while changed, drafts.count > 1 {
            changed = false
            guard let smallest = drafts.indices.min(by: { (weight(drafts[$0]), $0) < (weight(drafts[$1]), $1) }),
                  weight(drafts[smallest]) < 0.04 * totalLong else { break }
            let small = drafts.remove(at: smallest)
            let target = drafts.indices.max { a, b in
                let x = MusicalCompass.dot(normal(drafts[a].sum), normal(small.sum)), y = MusicalCompass.dot(normal(drafts[b].sum), normal(small.sum))
                return x != y ? x < y : a > b
            } ?? 0
            for key in small.sum.keys.sorted() { drafts[target].sum[key, default: 0] += small.sum[key] ?? 0 }
            drafts[target].members += small.members
            changed = true
        }
        let built = drafts.map { draft -> Cluster in
            let centroid = normal(draft.sum)
            let members = draft.members.sorted { $0.longTerm != $1.longTerm ? $0.longTerm > $1.longTerm : $0.id < $1.id }
            // Named by the styles its members actually carry, by weight --
            // not by the space's dimensions, which favour rare styles.
            var carried: [String: Double] = [:]
            for member in members { for style in member.styles { carried[style, default: 0] += member.longTerm / Double(member.styles.count) } }
            let label = carried.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3).map(\.key)
            let long = members.reduce(0) { $0 + $1.longTerm }, recent = members.reduce(0) { $0 + max(0, $1.recent) }
            let releaseLevel = members.filter { $0.styleSource == "release" }.reduce(0) { $0 + $1.longTerm } / max(long, 1e-9)
            let evidence = members.reduce(0) { $0 + (counts[$1.id] ?? 0) }
            let confidence = min(1, (0.5 + 0.5 * releaseLevel) * min(1, Double(members.count) / 5))
            let longShare = long / max(totalLong, 1e-9), recentShare = recent / max(totalRecent, 1e-9)
            return Cluster(id: 0, label: label, longTermShare: longShare, recentShare: recentShare,
                           emerging: recentShare >= 2 * longShare && recentShare >= 0.1 || !Set(label).isDisjoint(with: emerging),
                           examples: Array(members.prefix(6)), centroid: centroid, units: members.count,
                           evidence: evidence, confidence: confidence)
        }
        return built.sorted { $0.longTermShare != $1.longTermShare ? $0.longTermShare > $1.longTermShare : $0.label.joined() < $1.label.joined() }
            .enumerated().map { index, c in
                Cluster(id: index, label: c.label, longTermShare: c.longTermShare, recentShare: c.recentShare, emerging: c.emerging,
                        examples: c.examples, centroid: c.centroid, units: c.units, evidence: c.evidence, confidence: c.confidence)
            }
    }

    // MARK: Relevance

    /// A ranked list given out across the clusters: each takes slots in
    /// proportion to the time it holds (over time or now, whichever is
    /// more), with at least one for any cluster that has a candidate, so a
    /// small taste is not crowded out by the largest. Within a cluster the
    /// list's own order holds.
    func spread<T>(_ ranked: [T], limit: Int, styles: (T) -> [String], vectors: [String: [String: Double]]) -> [T] {
        spread(ranked, limit: limit) { relevance(styles: styles($0), vectors: vectors)?.cluster }
    }

    /// The same, placed by a cluster the caller knows (say, the cluster of
    /// the seed something was reached from when it has no style of its own).
    func spread<T>(_ ranked: [T], limit: Int, cluster: (T) -> Int?) -> [T] {
        var byCluster: [Int: [T]] = [:]
        var unplaced: [T] = []
        for item in ranked {
            if let id = cluster(item), clusters.contains(where: { $0.id == id }) { byCluster[id, default: []].append(item) }
            else { unplaced.append(item) }
        }
        let held = clusters.filter { byCluster[$0.id] != nil }
        let total = held.reduce(0) { $0 + max($1.longTermShare, $1.recentShare) }
        var quota: [Int: Int] = [:]
        for cluster in held {
            quota[cluster.id] = max(1, Int((Double(limit) * max(cluster.longTermShare, cluster.recentShare) / max(total, 1e-9)).rounded()))
        }
        var out: [T] = []
        var taken: [Int: Int] = [:]
        // Round-robin by cluster, each up to its quota, until full.
        var progress = true
        while out.count < limit, progress {
            progress = false
            for cluster in held where out.count < limit {
                let used = taken[cluster.id, default: 0]
                guard used < quota[cluster.id, default: 0], let list = byCluster[cluster.id], used < list.count else { continue }
                out.append(list[used])
                taken[cluster.id] = used + 1
                progress = true
            }
        }
        // Room left: the rest in the list's order.
        if out.count < limit {
            for cluster in held { for item in (byCluster[cluster.id] ?? []).dropFirst(taken[cluster.id, default: 0]) where out.count < limit { out.append(item) } }
            for item in unplaced where out.count < limit { out.append(item) }
        }
        return out
    }

    /// How well something with these styles fits the listener: its nearest
    /// cluster's similarity, weighted toward clusters that hold time, with a
    /// floor so a small taste is still served. Nil when it has no style the
    /// space knows (no evidence either way).
    func relevance(styles: [String], vectors: [String: [String: Double]]) -> (score: Double, cluster: Int)? {
        let v = Self.vector(styles.filter { vectors[$0] != nil }, vectors)
        guard !v.isEmpty, !clusters.isEmpty else { return nil }
        var best: (Double, Int)?
        for cluster in clusters {
            let fit = MusicalCompass.dot(cluster.centroid, v)
            let held = 0.5 + 0.5 * sqrt(max(cluster.longTermShare, cluster.recentShare))
            let score = fit * held
            if best.map({ score > $0.0 }) ?? true { best = (score, cluster.id) }
        }
        return best.map { (score: $0.0, cluster: $0.1) }
    }
}

// MARK: - From the store

nonisolated extension ListenerProfile {
    /// The evidence in the synced rows (`ListeningEvent`, `CrateItem`,
    /// `DigVisit`) and the style lookups the profile needs, read once.
    struct Read: Sendable {
        var evidence: [Evidence] = []
        var styles: [String: [String]] = [:]
        var artistStyles: [String: [String]] = [:]
        /// Artist key → its Discogs id, where this device holds the entry.
        var discogsIDs: [String: Int] = [:]
        /// Artist key → the person it is, as the smallest Discogs id of a
        /// group whose entries list each other as aliases. Only names the
        /// history holds; only links both entries confirm.
        var sameArtist: [String: Int] = [:]
        /// Plays whose recorded length could not have been heard, read by
        /// their completion instead (the rows themselves are left alone).
        var implausibleDurations = 0
        /// The audit: alias links between names in the history, how many
        /// both entries confirm, and groups as names alone would have made.
        var aliasLinks = 0, confirmedLinks = 0, groupsByName = 0, groupsByID = 0
    }

    /// What a play is worth, reading its length defensively. Rows written
    /// before heard time followed the playhead can carry the wall clock --
    /// one logged 22,010 seconds at 13% through. A length that would make
    /// the item longer than six hours (seconds / completion), or any length
    /// over four hours, is not taken: the completion alone speaks for it.
    /// The synced row is never changed.
    static func plausibleWeight(seconds: Double, completion: Double) -> Double {
        let implausible = (completion > 0 && completion < 1 && seconds / completion > 6 * 3600) || seconds > 4 * 3600
        if implausible { return min(1, max(0, completion)) }
        // As `ListeningEvent.weight` reads a play.
        guard seconds >= ListeningEvent.accidentSeconds else { return 0 }
        return max(min(1, seconds / ListeningEvent.fullListenSeconds), completion)
    }

    static func read(context: ModelContext, before cutoff: Date = .distantFuture) -> Read {
        var read = Read()
        let releases = (try? context.fetch(FetchDescriptor<DiscogsReleaseRecord>())) ?? []
        var releaseByTitleArtist: [String: DiscogsReleaseRecord] = [:]
        var releaseByID: [Int: DiscogsReleaseRecord] = [:]
        for record in releases {
            releaseByID[record.discogsID] = record
            for artist in record.artistNames {
                releaseByTitleArtist["\(RecordingKey.normalize(record.title))|\(RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(artist)))"] = record
            }
        }
        func fold(_ tags: [String]) -> [String] { ListeningLog.foldTags(tags) }
        // Editions: one record by title and artist, whatever pressing.
        func releaseUnit(_ title: String, _ artist: String) -> String { "release:\(RecordingKey.normalize(title))|\(artist)" }

        for event in ((try? context.fetch(FetchDescriptor<ListeningEvent>())) ?? []) where event.at < cutoff {
            let signal: Signal
            var weight = event.weight
            switch event.action {
            case .saved: signal = .saved
            case .skipped: signal = .skipped
            case .dismissed: signal = .dismissed
            case .opened: signal = .pageVisit
            case .played:
                weight = Self.plausibleWeight(seconds: event.seconds, completion: event.completion)
                if weight != event.weight { read.implausibleDurations += 1 }
                signal = weight >= 0.6 ? .fullListen : .partialListen
            }
            switch event.kind {
            case .recording:
                let artist = RecordingKey.normalizeArtist(event.subtitle ?? "")
                guard !artist.isEmpty else { continue }
                read.evidence.append(Evidence(unit: "recording:\(event.nodeKey)", level: .recording, artist: artist, title: event.title,
                                              at: event.at, signal: signal, strength: signal == .partialListen ? max(0.25, weight) : 1,
                                              tags: fold(event.musicTags)))
            case .artist:
                read.evidence.append(Evidence(unit: "artist:\(event.nodeKey)", level: .artist, artist: event.nodeKey, title: event.title,
                                              at: event.at, signal: signal, tags: fold(event.musicTags)))
            case .release:
                let artist = RecordingKey.normalizeArtist(event.subtitle ?? "")
                read.evidence.append(Evidence(unit: releaseUnit(event.title, artist), level: .release, artist: artist, title: event.title,
                                              at: event.at, signal: signal, tags: fold(event.musicTags)))
            default:
                // Stations and shows: where something was heard, not what.
                continue
            }
        }
        for item in ((try? context.fetch(FetchDescriptor<CrateItem>())) ?? []) where item.addedAt < cutoff {
            guard let artistName = item.artistName, !artistName.isEmpty else { continue }
            let artist = RecordingKey.normalizeArtist(artistName)
            if let album = item.albumTitle, !album.isEmpty {
                let unit = releaseUnit(album, artist)
                read.evidence.append(Evidence(unit: unit, level: .release, artist: artist, title: album, at: item.addedAt,
                                              signal: .crated, tags: fold(item.genreTags)))
                if let record = releaseByTitleArtist["\(RecordingKey.normalize(album))|\(artist)"] {
                    read.styles[unit] = fold(record.styles)
                }
            } else if let title = item.title, !title.isEmpty {
                read.evidence.append(Evidence(unit: "recording:\(RecordingKey.normalize(title))|\(artist)", level: .recording, artist: artist,
                                              title: title, at: item.addedAt, signal: .crated, tags: fold(item.genreTags)))
            } else {
                read.evidence.append(Evidence(unit: "artist:\(artist)", level: .artist, artist: artist, title: artistName,
                                              at: item.addedAt, signal: .crated, tags: fold(item.genreTags)))
            }
        }
        for visit in ((try? context.fetch(FetchDescriptor<DigVisit>())) ?? []) where visit.firstVisitedAt < cutoff {
            // Browsing: light, and once per page however often (the counter
            // is per device and later visits may fall after the cutoff).
            switch visit.kind {
            case .artist:
                let artist = RecordingKey.normalizeArtist(visit.title)
                read.evidence.append(Evidence(unit: "artist:\(artist)", level: .artist, artist: artist, title: visit.title,
                                              at: visit.firstVisitedAt, signal: .pageVisit, strength: min(1, Double(max(1, visit.visits)) / 3)))
            case .release:
                guard let id = visit.discogsID, let record = releaseByID[id], let first = record.artistNames.first else { continue }
                let artist = RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(first))
                let unit = releaseUnit(record.title, artist)
                read.styles[unit] = fold(record.styles)
                read.evidence.append(Evidence(unit: unit, level: .release, artist: artist, title: record.title,
                                              at: visit.firstVisitedAt, signal: .pageVisit, strength: min(1, Double(max(1, visit.visits)) / 3)))
            default:
                continue
            }
        }
        // Artists' own styles and ids, and the aliases their own entries list.
        let artists = Set(read.evidence.map(\.artist))
        var byKey: [String: DiscogsArtist] = [:]
        for row in ((try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? []) where row.discogsID > 0 { byKey[row.nameKey] = row }
        func key(_ name: String) -> String { RecordingKey.normalizeArtist(DiscogsClient.withoutDisambiguator(name)) }
        // Union by Discogs id; the smallest id names the group, so every
        // device agrees whatever the spelling.
        var parent: [Int: Int] = [:]
        func root(_ id: Int) -> Int { var id = id; while let up = parent[id], up != id { id = up }; return id }
        func join(_ a: Int, _ b: Int) { let (x, y) = (root(a), root(b)); if x != y { parent[max(x, y)] = min(x, y) } }
        var nameParent: [String: String] = [:]
        func nameRoot(_ k: String) -> String { var k = k; while let up = nameParent[k], up != k { k = up }; return k }
        for artist in artists.sorted() {
            guard let row = byKey[artist] else { continue }
            read.discogsIDs[artist] = row.discogsID
            if !row.styles.isEmpty { read.artistStyles[artist] = fold(row.styles) }
            guard row.isFiledUnderItsOwnName() else { continue }
            for alias in row.aliasNames {
                let other = key(alias)
                guard other != artist, artists.contains(other) else { continue }
                read.aliasLinks += 1
                // As names alone would have it (the old rule), for the audit.
                let (x, y) = (nameRoot(other), nameRoot(artist))
                if x != y { if x < y { nameParent[y] = x } else { nameParent[x] = y } }
                // Confirmed: the other name has its own entry, a different id,
                // and that entry lists this one back.
                guard let entry = byKey[other], entry.discogsID != row.discogsID,
                      entry.aliasNames.contains(where: { key($0) == artist }) else { continue }
                read.confirmedLinks += 1
                join(row.discogsID, entry.discogsID)
            }
        }
        var members: [Int: [String]] = [:]
        for (artist, id) in read.discogsIDs where parent[id] != nil || parent.values.contains(id) { members[root(id), default: []].append(artist) }
        for (group, names) in members where names.count > 1 { for name in names { read.sameArtist[name] = group } }
        read.groupsByID = Set(read.sameArtist.values).count
        read.groupsByName = Set(nameParent.keys.map(nameRoot)).count
        return read
    }
}
