//
//  ShowSuggestions.swift
//  Indigo
//
//  Radio shows worth putting on, judged by what they actually played.
//
//  The graph could only reach a show through an artist whose records happen to
//  be in the local store *and* to carry an appearance — which on a real
//  library was five edges out of a whole crate. Meanwhile the appearance log
//  held eighteen complete tracklists nobody was reading.
//
//  A tracklist is the best description of a show there is. It is what the
//  selector actually reached for, rather than the genre words a station wrote
//  on the schedule, and it is the same evidence a person uses when they read
//  down a playlist and decide. So a show is scored on two things a listener
//  would recognise: how many of these people you already keep, and whether the
//  rest of it sounds like what you listen to.
//

import Foundation
import SwiftData

nonisolated struct ShowSuggestionEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// A show has to clear this to be offered at all. Low enough that a
    /// station Indigo has barely heard can still say something, high enough
    /// that a tracklist with nothing in common is not dressed up as a match.
    static let threshold = 0.18
    /// Names shown before the sentence gives up counting.
    static let namesShown = 2

    /// Shows worth offering, best first.
    ///
    /// `known` is the set of node ids this listener already has, so a show
    /// they crated is not offered back to them.
    func suggestions(
        taste: TasteProfile,
        known: Set<String>,
        keptArtistKeys: Set<String>,
        limit: Int = 6
    ) -> [ExploreSuggestion] {
        let shows = tracklists()
        guard !shows.isEmpty else { return [] }
        let log = ListeningLog(context: context)
        let styles = artistStyles()

        var found: [ExploreSuggestion] = []
        for show in shows.values {
            let node = MusicNode.broadcast(
                providerID: show.providerID, showID: show.showID, title: show.title
            )
            guard node.destination != nil else { continue }
            guard !known.contains(node.id), !log.hasEncountered(node) else { continue }

            // Whose records were played that this listener keeps.
            let familiar = show.artists
                .filter { keptArtistKeys.contains(RecordingKey.normalizeArtist($0)) }
                .sorted()
            // And what the rest of the hour sounded like.
            let tags = show.artists.flatMap { styles[RecordingKey.normalizeArtist($0)] ?? [] }
            let affinity = taste.affinity(for: tags)

            // Deliberately not a sum. Three artists you keep is a reason on its
            // own and so is an hour of exactly your music; a show with a little
            // of each should not outrank either.
            let byArtists = min(1, Double(familiar.count) / 3)
            let score = max(byArtists, affinity * 0.9)
            guard score >= Self.threshold else { continue }

            found.append(ExploreSuggestion(
                node: node,
                reason: Self.reason(familiar: familiar, tags: tags, taste: taste, affinity: affinity),
                via: familiar.first ?? "what you listen to",
                kind: .playedInShow,
                corroboration: max(1, familiar.count),
                score: score
            ))
        }
        return found
            .sorted { $0.score == $1.score ? $0.node.title < $1.node.title : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Why this show is being offered, in terms somebody would recognise.
    ///
    /// Names first when there are any: "played Suso Sáiz and Jon Hassell" is
    /// something a person can check, and a genre is something they have to
    /// take on trust.
    static func reason(
        familiar: [String], tags: [String], taste: TasteProfile, affinity: Double
    ) -> String {
        if !familiar.isEmpty {
            let named = familiar.prefix(namesShown).joined(separator: " and ")
            let rest = familiar.count - min(namesShown, familiar.count)
            let who = rest > 0 ? "\(named) and \(rest) more you keep" : "\(named), who you keep"
            return "Played \(who)"
        }
        // The tags of theirs that this listener actually listens to, rather
        // than everything the hour touched.
        let matched = ListeningLog.foldTags(tags)
            .filter { taste[$0] > 0 }
            .sorted { taste[$0] > taste[$1] }
            .prefix(3)
        guard !matched.isEmpty else { return "Close to what you listen to" }
        return "\(matched.map(\.capitalized).joined(separator: ", ")) — what you listen to"
    }

    // MARK: - Reading the log

    nonisolated struct Tracklist {
        let providerID: String
        let showID: String
        var title: String
        var artists: Set<String> = []
    }

    /// Every broadcast Indigo has a tracklist for, and who was on it.
    func tracklists() -> [String: Tracklist] {
        var byShow: [String: Tracklist] = [:]
        for appearance in (try? context.fetch(FetchDescriptor<MediaAppearance>())) ?? [] {
            guard let showID = appearance.showID, !showID.isEmpty else { continue }
            let key = "\(appearance.providerID)|\(showID)"
            var entry = byShow[key] ?? Tracklist(
                providerID: appearance.providerID, showID: showID,
                title: appearance.showTitle ?? BroadcastSource.label(for: appearance.providerID)
            )
            if let name = appearance.recording?.artistName, !name.isEmpty {
                entry.artists.insert(name)
            }
            if entry.title.isEmpty, let title = appearance.showTitle { entry.title = title }
            byShow[key] = entry
        }
        // A show nobody could name a single track from says nothing about
        // itself, and guessing from its title is not evidence.
        return byShow.filter { !$0.value.artists.isEmpty }
    }

    /// What the catalogue says each artist sounds like, by normalised name.
    private func artistStyles() -> [String: [String]] {
        var found: [String: [String]] = [:]
        for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] {
            let tags = artist.styles + artist.genres
            guard !tags.isEmpty else { continue }
            found[artist.nameKey] = tags
        }
        return found
    }
}
