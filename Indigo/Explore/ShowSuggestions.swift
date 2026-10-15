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

    /// A show has to clear this to be offered at all. See
    /// `ExploreRanker.showThreshold`, which is where it is applied now.
    static let threshold = ExploreRanker.showThreshold
    /// Names shown before the sentence gives up counting.
    static let namesShown = 2

    /// Shows worth offering, best first, from this store's tracklists.
    ///
    /// `known` is the set of node ids this listener already has, so a show
    /// they crated is not offered back to them. The judging itself is
    /// `ExploreRanker.shows`, over `profiles()`.
    func suggestions(
        taste: TasteProfile,
        known: Set<String>,
        keptArtistKeys: Set<String>,
        limit: Int = 6
    ) -> [ExploreSuggestion] {
        ExploreRanker.shows(
            profiles(), taste: taste, known: known, keptArtistKeys: keptArtistKeys,
            encountered: Set(ListeningLog.gather(ListeningLog(context: context).all()).map(\.node.id)),
            limit: limit
        )
    }

    /// Every tracklist, folded to what a show is judged on: who was on it,
    /// and the catalogue's styles for them as one folded set. A set is all
    /// the judging reads -- `TasteProfile.affinity` and `reason` fold and
    /// deduplicate whatever they are given -- so it is the same judgement
    /// from much less.
    func profiles() -> [ShowProfile] {
        let styles = artistStyles()
        return tracklists().values
            .map { show in
                let artists = show.artists.sorted()
                let tags = ListeningLog.foldTags(artists.flatMap { styles[RecordingKey.normalizeArtist($0)] ?? [] })
                return ShowProfile(
                    providerID: show.providerID, showID: show.showID, title: show.title,
                    artworkURL: show.artworkURL, artists: artists, tags: Array(Set(tags)).sorted()
                )
            }
            .sorted { $0.key < $1.key }
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
            .sorted { taste[$0] == taste[$1] ? $0 < $1 : taste[$0] > taste[$1] }
            .prefix(3)
        guard !matched.isEmpty else { return "Close to what you listen to" }
        return "\(matched.map(\.capitalized).joined(separator: ", ")) — what you listen to"
    }

    // MARK: - Reading the log

    nonisolated struct Tracklist {
        let providerID: String
        let showID: String
        var title: String
        /// Where it is filed: provider and show.
        var key: String { "\(providerID)|\(showID)" }
        var artists: Set<String> = []
        /// The first picture any of these appearances carried. A show has one
        /// cover however many tracks were logged off it.
        var artworkURL: URL?
    }

    /// Every broadcast Indigo has a tracklist for, and who was on it.
    ///
    /// A show's name and picture are whatever its appearances say, chosen by
    /// what they say: the first by name and by address. They were the first
    /// appearance read, which is the order the store filed them in -- not the
    /// same on two devices holding the same tracklist -- and a show whose
    /// first appearance had no title kept the station's name even when a
    /// later one had the show's.
    func tracklists() -> [String: Tracklist] {
        var byShow: [String: Tracklist] = [:]
        var titles: [String: String] = [:]
        for appearance in (try? context.fetch(FetchDescriptor<MediaAppearance>())) ?? [] {
            guard let showID = appearance.showID, !showID.isEmpty else { continue }
            let key = "\(appearance.providerID)|\(showID)"
            var entry = byShow[key] ?? Tracklist(
                providerID: appearance.providerID, showID: showID,
                title: BroadcastSource.label(for: appearance.providerID)
            )
            if let name = appearance.recording?.artistName, !name.isEmpty {
                entry.artists.insert(name)
            }
            if let title = appearance.showTitle, !title.isEmpty {
                titles[key] = titles[key].map { min($0, title) } ?? title
            }
            if let artwork = appearance.artworkURL,
               entry.artworkURL.map({ artwork.absoluteString < $0.absoluteString }) ?? true {
                entry.artworkURL = artwork
            }
            byShow[key] = entry
        }
        for (key, title) in titles { byShow[key]?.title = title }
        // A show nobody could name a single track from says nothing about
        // itself, and guessing from its title is not evidence.
        return byShow.filter { !$0.value.artists.isEmpty }
    }

    /// What the catalogue says each artist sounds like, by normalised name.
    func artistStyles() -> [String: [String]] {
        var found: [String: [String]] = [:]
        for artist in (try? context.fetch(FetchDescriptor<DiscogsArtist>())) ?? [] {
            let tags = artist.styles + artist.genres
            guard !tags.isEmpty else { continue }
            found[artist.nameKey] = tags
        }
        return found
    }
}
