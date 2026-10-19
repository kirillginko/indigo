//
//  RadioListenFinder.swift
//  Indigo
//
//  A radio episode to hear an artist in, for a Hear next card: found in the
//  shared radio record by the artist's verified Discogs entry, and offered
//  only once the episode's archive is known to play.
//
//  Read-only and bounded. One read of the identity rows for every card on the
//  page (`external_ids`: the backend's Discogs id for each artist row), one
//  read of each row's latest appearances (`artist_radio_appearances`), and at
//  most a few playability checks per artist, stopping at the first that plays
//  -- through the integration that would play it: SoundCloud and Mixcloud by
//  their oEmbed endpoints (as `YouTubeAvailability` asks YouTube), The Lot
//  Radio's HLS archive by reading its playlist. A YouTube "episode" is a
//  channel's playlist, not a broadcast, and is never offered.
//
//  What a card may say comes from the appearance itself: which track of theirs
//  was played, on which show, when. Never that the episode contains the
//  record the card is about.
//

import Foundation
import Supabase

/// An episode an artist was played in, verified to play.
nonisolated struct RadioListen: Codable, Equatable, Sendable {
    /// The app's provider id: "nts", "lot".
    let provider: String
    /// The provider's own reference: "show/episode".
    let episode: String
    let episodeTitle: String
    let showTitle: String?
    let airedAt: Date?
    /// What of theirs was played, as the tracklist wrote it.
    let played: String?
    let offsetSeconds: Int?
    let archiveURL: URL

    /// The episode's page in Indigo.
    var page: MusicNode { MusicNode.broadcast(providerID: provider, showID: episode, title: episodeTitle) }
}

nonisolated struct RadioListenFinder: Sendable {
    /// What a lookup spent and found, for measurement.
    struct Report: Sendable, Equatable {
        var identityReads = 0, appearanceReads = 0, checks = 0
        var verified = 0, notPlayable = 0, unknown = 0, noAppearance = 0
        var failures = 0
    }

    /// Discogs ids to the backend's artist rows.
    var rows: @Sendable ([Int]) async throws -> [Int: [UUID]]
    /// A row's latest appearances.
    var appearances: @Sendable (UUID) async throws -> [Catalog.ArtistRadioAppearance]
    /// Whether an archive plays: true, false, or nil when it could not be told.
    var plays: @Sendable (_ provider: String, _ url: URL) async -> Bool?
    /// Checks per artist before giving up on them for now.
    var checksPerArtist = 3

    /// The backend's providers that are broadcasts, as the app names them.
    static func appProvider(_ backend: String) -> String? {
        switch backend {
        case "nts": NTSProvider.providerID
        case "lotradio": LotProvider.providerID
        default: nil
        }
    }

    /// For each Discogs id: an episode verified to play, or nil when there is
    /// none (or none could be confirmed). Ids missing from the answer could
    /// not be asked at all and should be asked again later.
    func find(_ ids: [Int]) async -> (found: [Int: RadioListen?], report: Report) {
        var report = Report()
        guard !ids.isEmpty else { return ([:], report) }
        let mapped: [Int: [UUID]]
        do {
            report.identityReads += 1
            mapped = try await rows(Array(Set(ids)).sorted())
        } catch {
            report.failures += 1
            return ([:], report)
        }
        var found: [Int: RadioListen?] = [:]
        for id in ids {
            guard let artistRows = mapped[id], !artistRows.isEmpty else {
                found[id] = .some(nil)
                report.noAppearance += 1
                continue
            }
            var heard: [Catalog.ArtistRadioAppearance] = []
            var failed = false
            for row in artistRows.prefix(3) {
                do {
                    report.appearanceReads += 1
                    heard += try await appearances(row)
                } catch {
                    report.failures += 1
                    failed = true
                }
            }
            // Newest first, one appearance per episode.
            var episodes = Set<UUID>()
            let candidates = heard
                .filter { Self.appProvider($0.provider) != nil && $0.archiveURL != nil }
                .sorted { ($0.airedAt ?? .distantPast, $0.episodeID.uuidString) > ($1.airedAt ?? .distantPast, $1.episodeID.uuidString) }
                .filter { episodes.insert($0.episodeID).inserted }
            if candidates.isEmpty {
                if !failed { found[id] = .some(nil); report.noAppearance += 1 }
                continue
            }
            var answer: RadioListen?
            var sure = true
            for appearance in candidates.prefix(checksPerArtist) {
                guard let provider = Self.appProvider(appearance.provider),
                      let link = appearance.archiveURL, let url = URL(string: link) else { continue }
                report.checks += 1
                switch await plays(appearance.provider, url) {
                case true?:
                    report.verified += 1
                    answer = RadioListen(
                        provider: provider, episode: appearance.episodeExternalID,
                        episodeTitle: appearance.episodeTitle ?? appearance.showTitle ?? "Radio episode",
                        showTitle: appearance.showTitle, airedAt: appearance.airedAt,
                        played: appearance.rawTrackTitle, offsetSeconds: appearance.offsetSeconds, archiveURL: url)
                case false?:
                    report.notPlayable += 1
                case nil:
                    report.unknown += 1
                    sure = false
                }
                if answer != nil { break }
            }
            // A miss is kept only when every check was a verdict.
            if answer != nil || sure { found[id] = .some(answer) }
        }
        return (found, report)
    }

    // MARK: Live

    static let live = RadioListenFinder(
        rows: { ids in
            let client = try SupabaseService.requireClient()
            let on = DiscogsIdentityRows.isEnabled
            let links: [DiscogsIdentityRows.Link] = try await DiscogsIdentityRows.providerFilter(client
                .from("external_ids")
                .select("entity_id,provider,external_id"), enabled: on)
                .eq("entity_type", value: "artist")
                .in("external_id", values: ids.map(String.init))
                .limit(200)
                .execute()
                .value
            guard on else { return DiscogsIdentityRows.arrivingRows(byDiscogs: links) }
            // A MusicBrainz-linked row's other such links, asked for by id
            // above or not: two of them and it reads neither.
            let linked = Set(links.filter { $0.provider != "discogs" }.map(\.entity_id))
            guard !linked.isEmpty else { return DiscogsIdentityRows.rows(byDiscogs: links) }
            let others: [DiscogsIdentityRows.Link] = try await client
                .from("external_ids")
                .select("entity_id,provider,external_id")
                .eq("provider", value: "musicbrainz_discogs")
                .eq("entity_type", value: "artist")
                .in("entity_id", values: linked.map(\.uuidString))
                .limit(400)
                .execute()
                .value
            let asked = Set(ids)
            let extra = others.filter { !links.contains($0) }
            return DiscogsIdentityRows.rows(byDiscogs: links + extra).filter { asked.contains($0.key) }
        },
        appearances: { row in try await RadioRepository().appearances(forArtist: row, limit: 12) },
        plays: { provider, url in await playable(provider: provider, url: url) }
    )

    /// Whether an archive plays through the integration that would play it.
    static func playable(provider: String, url: URL, session: URLSession = NetworkEnvironment.metadataSession) async -> Bool? {
        let host = url.host?.lowercased() ?? ""
        var request: URLRequest
        if host.hasSuffix("soundcloud.com") || host.hasSuffix("mixcloud.com") {
            var components = URLComponents(string: host.hasSuffix("soundcloud.com")
                                           ? "https://soundcloud.com/oembed" : "https://app.mixcloud.com/oembed/")
            components?.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: url.absoluteString)]
            guard let query = components?.url else { return nil }
            request = URLRequest(url: query)
        } else if url.pathExtension.lowercased() == "m3u8" {
            request = URLRequest(url: url)
        } else {
            return nil
        }
        request.timeoutInterval = 8
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200:
                // A playlist must be one: storage that has lost the file can
                // still answer 200 with an error page.
                if url.pathExtension.lowercased() == "m3u8" {
                    return String(decoding: data.prefix(16), as: UTF8.self).hasPrefix("#EXTM3U")
                }
                return true
            case 401, 403, 404, 410: return false
            default: return nil
            }
        } catch {
            return nil
        }
    }
}

/// What the finder has answered, kept a day (a miss six hours) on disk, so a
/// card that was given an episode keeps it and nobody asks twice.
nonisolated final class RadioListenCache: @unchecked Sendable {
    private struct Entry: Codable { let listen: RadioListen?; let at: Date }
    static let hitLifetime: TimeInterval = 24 * 60 * 60
    static let missLifetime: TimeInterval = 6 * 60 * 60

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var asking = Set<Int>()
    private let file: URL?

    init(file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("hear-next-radio.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let held = try? JSONDecoder().decode([Int: Entry].self, from: data) {
            entries = held
        }
    }

    private func fresh(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.at) < (entry.listen == nil ? Self.missLifetime : Self.hitLifetime)
    }

    /// Every fresh answer: an episode, or a known nothing.
    var found: [Int: RadioListen?] {
        let now = Date()
        return lock.withLock { entries.filter { fresh($0.value, now: now) }.mapValues(\.listen) }
    }

    /// Of these ids, the ones nobody has a fresh answer for and nobody is
    /// asking about, now claimed for asking.
    func claim(_ ids: [Int]) -> [Int] {
        let now = Date()
        return lock.withLock {
            let wanted = ids.filter { id in
                !asking.contains(id) && !(entries[id].map { fresh($0, now: now) } ?? false)
            }
            asking.formUnion(wanted)
            return wanted
        }
    }

    func record(_ found: [Int: RadioListen?], asked: [Int]) {
        let now = Date()
        let snapshot: [Int: Entry] = lock.withLock {
            for (id, listen) in found { entries[id] = Entry(listen: listen, at: now) }
            asking.subtract(asked)
            return entries
        }
        if let file, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }
}
