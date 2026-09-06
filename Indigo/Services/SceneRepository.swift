//
//  SceneRepository.swift
//  Indigo
//
//  Who else is in a scene.
//
//  The local `SceneEngine` builds a scene out of what this listener's own
//  catalogue happens to hold, which on any real collection is a handful of
//  names — eight under "New York / Jazz", which is a story about one record
//  shelf rather than about a scene. This is the rest of it.
//
//  Read from Indigo's own backend rather than from MusicBrainz directly, and
//  that is the point rather than an implementation detail. MusicBrainz asks
//  for one request a second from a named client; a phone opening a scene page
//  cannot honour that, and every copy of the app trying would be a separate
//  anonymous client hammering one endpoint. A crawler that paces itself fills
//  a table in once, and every copy reads the answer.
//

import Foundation
import PostgREST
import Supabase

nonisolated struct SceneRepository: Sendable {
    static let shared = SceneRepository()

    /// Somebody in a scene, as the shared catalogue knows them.
    nonisolated struct Member: Decodable, Sendable, Identifiable, Hashable {
        let name: String
        let normalizedName: String
        let mbid: String?
        let area: String?
        let beganYear: Int?
        let endedYear: Int?
        let disambiguation: String?
        let score: Int

        var id: String { normalizedName }

        /// "1968–1994", "since 2011", or nothing when the catalogue is silent.
        var yearsLabel: String? {
            switch (beganYear, endedYear) {
            case let (.some(began), .some(ended)): "\(began)–\(ended)"
            case let (.some(began), .none): "since \(began)"
            case let (.none, .some(ended)): "until \(ended)"
            case (.none, .none): nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case normalizedName = "normalized_name"
            case mbid
            case area
            case beganYear = "began_year"
            case endedYear = "ended_year"
            case disambiguation
            case score
        }
    }

    nonisolated struct Roster: Decodable, Sendable {
        let id: UUID
        let status: String
        let memberCount: Int
        let totalAvailable: Int?

        /// Whether the crawl has finished. A roster still filling is worth
        /// showing — half a scene is more than none — but worth saying so.
        var isComplete: Bool { status == "ready" }

        private enum CodingKeys: String, CodingKey {
            case id
            case status
            case memberCount = "member_count"
            case totalAvailable = "total_available"
        }
    }

    /// The roster for one scene, if the backend has ever been asked for it.
    func roster(place: String, sound: String?) async throws -> Roster? {
        let client = try SupabaseService.requireClient()
        let rows: [Roster] = try await client
            .from("scene_rosters")
            .select("id,status,member_count,total_available")
            .eq("place_key", value: RecordingKey.normalize(place))
            .eq("sound_key", value: RecordingKey.normalize(sound))
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Everybody in it, best match first.
    func members(rosterID: UUID, limit: Int = 120) async throws -> [Member] {
        let client = try SupabaseService.requireClient()
        return try await client
            .from("scene_members")
            .select("name,normalized_name,mbid,area,began_year,ended_year,disambiguation,score")
            .eq("roster_id", value: rosterID.uuidString)
            .order("score", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Asks for a scene to be filled in, and says what is known so far.
    ///
    /// Safe to call every time a scene page opens. The backend will not queue
    /// the same scene twice, and will not walk one that was filled recently —
    /// so opening a page repeatedly costs one row and no upstream requests.
    @discardableResult
    func request(place: String, sound: String?) async throws -> Roster? {
        let client = try SupabaseService.requireClient()
        // The keys are computed here rather than in SQL. There is no
        // normalizer in Postgres: the app and the worker each carry one and
        // `NormalizationParityTests` keeps them in step, and a third would be
        // a third thing to drift.
        _ = try await client
            .rpc("request_scene_roster", params: Request(
                pPlace: place,
                pPlaceKey: RecordingKey.normalize(place),
                pSound: sound,
                pSoundKey: RecordingKey.normalize(sound)
            ))
            .execute()
        return try await roster(place: place, sound: sound)
    }

    private struct Request: Encodable, Sendable {
        let pPlace: String
        let pPlaceKey: String
        let pSound: String?
        let pSoundKey: String

        private enum CodingKeys: String, CodingKey {
            case pPlace = "p_place"
            case pPlaceKey = "p_place_key"
            case pSound = "p_sound"
            case pSoundKey = "p_sound_key"
        }
    }
}
