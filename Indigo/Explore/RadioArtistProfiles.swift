//
//  RadioArtistProfiles.swift
//  Indigo
//
//  What a verified radio artist makes, from a source independent of the
//  programmes that played them: MusicBrainz, reached through MusicBrainz's
//  own link to the artist's Discogs entry -- by id, never by name. A Discogs
//  entry two MusicBrainz artists claim is no one's here. The profile's
//  styles are MusicBrainz's curated genres (else its tags) that name a style
//  the listener's style space knows; nothing else becomes a style.
//
//  Research for For You's radio fill (`ClusterSeedPicks.radioProfiles`):
//  not read by the app unless a caller sets it. One MusicBrainz request a
//  second, so it is for measuring until there is a cache.
//

import Foundation

nonisolated struct RadioArtistProfile: Sendable, Equatable {
    enum Source: String, Sendable { case genres = "musicbrainz genres", tags = "musicbrainz tags", none, ambiguous, unlinked, failed }

    let discogsID: Int
    var musicBrainzID: String?
    var name: String?
    /// Folded, by votes.
    var genres: [String] = []
    var tags: [String] = []
    var releaseGroups = 0
    var albums = 0
    var years: ClosedRange<Int>?
    var source: Source = .none

    /// The styles to judge it by: its genres the style space knows, else its
    /// tags the style space knows.
    func styles(known vectors: [String: [String: Double]]) -> (styles: [String], source: Source) {
        let fromGenres = genres.filter { vectors[$0] != nil }
        if !fromGenres.isEmpty { return (Array(fromGenres.prefix(6)), .genres) }
        let fromTags = tags.filter { vectors[$0] != nil }
        if !fromTags.isEmpty { return (Array(fromTags.prefix(6)), .tags) }
        return ([], source == .ambiguous || source == .unlinked || source == .failed ? source : .none)
    }

    static func build(discogsID: Int, artist: MBArtist) -> RadioArtistProfile {
        func voted(_ list: [MBTag]?) -> [String] {
            let pairs: [(name: String, votes: Int)] = (list ?? []).compactMap { tag in
                guard let name = tag.name, let votes = tag.count, votes > 0 else { return nil }
                return (name, votes)
            }
            let sorted = pairs.sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.name < $1.name }
            return ListeningLog.foldTags(sorted.map { $0.name })
        }
        let groups = artist.releaseGroups ?? []
        let years = groups.compactMap { $0.firstReleaseDate.flatMap { Int($0.prefix(4)) } }.filter { $0 > 1800 }
        return RadioArtistProfile(discogsID: discogsID, musicBrainzID: artist.id, name: artist.name,
                                  genres: voted(artist.genres), tags: voted(artist.tags), releaseGroups: groups.count,
                                  albums: groups.filter { $0.primaryType == "Album" }.count,
                                  years: years.min().flatMap { lo in years.max().map { lo...$0 } }, source: .genres)
    }
}

nonisolated struct RadioArtistProfiles: Sendable {
    var artists: @Sendable (Int) async throws -> [MBArtist]
    var profile: @Sendable (String) async throws -> MBArtist

    static let live: RadioArtistProfiles = {
        let client = MusicBrainzClient()
        return RadioArtistProfiles(artists: { try await client.artists(discogsArtistID: $0) },
                                   profile: { try await client.artistProfile(id: $0) })
    }()

    /// One artist's profile. A throttle is waited out and asked again, twice.
    func profile(discogsID id: Int) async -> RadioArtistProfile {
        func retried<T>(_ body: () async throws -> T) async -> T? {
            for attempt in 0..<3 {
                do { return try await body() } catch MusicBrainzError.rateLimited {
                    try? await Task.sleep(nanoseconds: UInt64(2 + 2 * attempt) * 1_000_000_000)
                } catch { return nil }
            }
            return nil
        }
        guard let linked = await retried({ try await artists(id) }) else { return .init(discogsID: id, source: .failed) }
        let ids = Set(linked.compactMap(\.id))
        guard ids.count == 1, let mbid = ids.first else { return .init(discogsID: id, source: ids.isEmpty ? .unlinked : .ambiguous) }
        guard let artist = await retried({ try await profile(mbid) }) else { return .init(discogsID: id, musicBrainzID: mbid, source: .failed) }
        return RadioArtistProfile.build(discogsID: id, artist: artist)
    }

    func profiles(_ ids: [Int]) async -> [Int: RadioArtistProfile] {
        var out: [Int: RadioArtistProfile] = [:]
        for id in Set(ids).sorted() { out[id] = await profile(discogsID: id) }
        return out
    }
}
