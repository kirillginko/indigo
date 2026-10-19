import Foundation
import Supabase

nonisolated struct RadioDiscoverSource: Sendable {
    var rows: @Sendable ([Int]) async throws -> [Int: [UUID]]
    var seedAppearances: @Sendable ([UUID]) async throws -> [RadioDiscover.Slot]
    var tracklists: @Sendable ([UUID]) async throws -> [RadioDiscover.Slot]
    var identities: @Sendable ([UUID]) async throws -> [UUID: RadioDiscover.Identity]
    var recording: @Sendable (Int, String, String) async -> TrackDiscovery.Appearance?
    var plays: @Sendable (DiscoveredTrack.Source) async -> Bool?
    var catalogueReads: @Sendable () async -> Int = { 0 }

    actor Reads {
        var count = 0
        func add() { count += 1 }
    }
    static let reads = Reads()
    // No genre tags are selected. Styles come only from independent artist/
    // release evidence; the curator is measured by what was actually played.
    private static let columns = "artist_id,raw_artist_name,raw_track_title,track_index,offset_seconds,media_url,radio_episodes!inner(id,radio_show_id,provider,external_id,archive_url,title,aired_at,image_url,duration_seconds,radio_shows(title,host_name))"

    static let live = RadioDiscoverSource(
        rows: { ids in
            guard !ids.isEmpty else { return [:] }
            let client = try SupabaseService.requireClient()
            await reads.add()
            let links: [DiscogsIdentityRows.Link] = try await client.from("external_ids")
                .select("entity_id,provider,external_id").eq("entity_type", value: "artist")
                .in("provider", values: DiscogsIdentityRows.providers)
                .in("external_id", values: ids.map(String.init)).limit(1000).execute().value
            // Fetch all competing destinations before admitting a row.
            let rowIDs = Array(Set(links.map(\.entity_id)))
            guard !rowIDs.isEmpty else { return [:] }
            await reads.add()
            let all: [DiscogsIdentityRows.Link] = try await client.from("external_ids")
                .select("entity_id,provider,external_id").eq("entity_type", value: "artist")
                .in("provider", values: DiscogsIdentityRows.providers)
                .in("entity_id", values: rowIDs.map(\.uuidString)).limit(2000).execute().value
            let names = Dictionary(uniqueKeysWithValues: rowIDs.map { ($0, "Verified seed") })
            let safe = RadioDiscover.identities(all, names: names)
            var out: [Int: [UUID]] = [:]
            for (row, identity) in safe where ids.contains(identity.id) { out[identity.id, default: []].append(row) }
            return out
        },
        seedAppearances: { ids in
            let client = try SupabaseService.requireClient()
            await reads.add()
            return try await client.from("radio_appearances").select(columns)
                .in("artist_id", values: ids.map(\.uuidString))
                .in("radio_episodes.provider", values: ["nts", "lotradio"])
                .order("radio_episode_id").order("track_index").limit(240).execute().value
        },
        tracklists: { ids in
            guard !ids.isEmpty else { return [] }
            let client = try SupabaseService.requireClient()
            var out: [RadioDiscover.Slot] = []
            for page in 0..<3 {
                await reads.add()
                let part: [RadioDiscover.Slot] = try await client.from("radio_appearances").select(columns)
                    .in("radio_episode_id", values: ids.map(\.uuidString))
                    .order("radio_episode_id").order("track_index").range(from: page * 1000, to: page * 1000 + 999).execute().value
                out += part
                if part.count < 1000 { break }
            }
            return out
        },
        identities: { ids in
            guard !ids.isEmpty else { return [:] }
            let client = try SupabaseService.requireClient()
            struct Name: Decodable { let id: UUID; let name: String }
            var names: [Name] = [], links: [DiscogsIdentityRows.Link] = []
            // Bound URL size and avoid relying on PostgREST's default row cap.
            for offset in stride(from: 0, to: ids.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(ids[offset..<min(offset + 100, ids.count)]).map(\.uuidString)
                await reads.add()
                names += try await client.from("artists").select("id,name")
                    .in("id", values: batch).limit(100).execute().value as [Name]
                await reads.add()
                links += try await client.from("external_ids")
                    .select("entity_id,provider,external_id").eq("entity_type", value: "artist")
                    .in("provider", values: DiscogsIdentityRows.providers)
                    .in("entity_id", values: batch).limit(1000).execute().value as [DiscogsIdentityRows.Link]
            }
            return RadioDiscover.identities(links, names: Dictionary(names.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        },
        recording: { id, name, title in
            // Specific recording only. An arbitrary song by the same artist
            // must never replace the track the compatible programme selected.
            var videos = ReleaseVideoTracks.live
            videos.releases = 1
            return await videos.tracks(artistID: id, artist: name).first {
                TrackDiscovery.trackKey($0.title) == TrackDiscovery.trackKey(title)
            }
        },
        plays: TrackDiscoverySource.live.plays,
        catalogueReads: { await reads.count }
    )
}

/// Disposable, device-local and personal. Never synced or written into Git.
actor RadioDiscoverCache {
    static let shared = RadioDiscoverCache(file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("radio-curator-discover-v1.json"))
    let file: URL?
    init(file: URL?) { self.file = file }
    func load(key: String, now: Date = Date()) -> RadioDiscover.Result? {
        guard let file, let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(RadioDiscover.Result.self, from: data),
              result.key == key, now.timeIntervalSince(result.at) < (result.picks.isEmpty ? 600 : 6 * 3600) else { return nil }
        return result
    }
    func save(_ result: RadioDiscover.Result) {
        guard let file, let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
