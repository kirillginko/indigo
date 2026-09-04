//
//  CatalogRows.swift
//  Indigo
//
//  The shape of Indigo's shared catalogue as it crosses the wire. These mirror
//  supabase/migrations/0001_core_schema.sql column for column; the local
//  SwiftData models keep their own shape and stay the listener's private copy.
//
//  Namespaced because the app already owns `Artist` and `Recording` as
//  SwiftData models, and the two are not interchangeable.
//

import Foundation

nonisolated enum Catalog {
    /// The entities an external id or an artwork row can point at. Mirrors the
    /// check constraints on `external_ids` and `artwork`.
    enum EntityType: String, Codable, Sendable, CaseIterable {
        case artist
        case label
        case release
        case recording
        case radioShow = "radio_show"
        case radioEpisode = "radio_episode"
    }

    struct Artist: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var normalizedName: String?
        var country: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, country
            case normalizedName = "normalized_name"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Label: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var normalizedName: String?
        var country: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, name, country
            case normalizedName = "normalized_name"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Release: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var artistID: UUID?
        var labelID: UUID?
        var catalogNumber: String?
        var releaseYear: Int?
        var releaseType: String?
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title
            case artistID = "artist_id"
            case labelID = "label_id"
            case catalogNumber = "catalog_number"
            case releaseYear = "release_year"
            case releaseType = "release_type"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct Recording: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var title: String?
        var artistID: UUID?
        var releaseID: UUID?
        var isrc: String?
        var musicbrainzRecordingID: String?
        var identificationStatus: String
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, title, isrc
            case artistID = "artist_id"
            case releaseID = "release_id"
            case musicbrainzRecordingID = "musicbrainz_recording_id"
            case identificationStatus = "identification_status"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    struct ExternalID: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var entityType: EntityType
        var entityID: UUID
        var provider: String
        var externalID: String
        var sourceURL: String?

        enum CodingKeys: String, CodingKey {
            case id, provider
            case entityType = "entity_type"
            case entityID = "entity_id"
            case externalID = "external_id"
            case sourceURL = "source_url"
        }
    }

    /// Artwork carries both a cached path and the upstream URL, because not
    /// every provider licenses re-hosting. A row with only `originalURL` is
    /// legitimate, not a half-finished cache entry.
    struct Artwork: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var entityType: EntityType
        var entityID: UUID
        var provider: String?
        var originalURL: String?
        var storagePath: String?
        var thumbnailPath: String?
        var mediumPath: String?
        var largePath: String?
        var width: Int?
        var height: Int?
        var fetchedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, provider, width, height
            case entityType = "entity_type"
            case entityID = "entity_id"
            case originalURL = "original_url"
            case storagePath = "storage_path"
            case thumbnailPath = "thumbnail_path"
            case mediumPath = "medium_path"
            case largePath = "large_path"
            case fetchedAt = "fetched_at"
        }
    }
}

// MARK: - Radio
//
// Three tables, not one. A programme, a broadcast of it, and a track inside
// that broadcast are different things, and collapsing them makes the question
// the radio feature exists for — which shows have played this artist —
// unanswerable, because there is no show left to count.

nonisolated extension Catalog {
    /// The programme: "Ben UFO", "Moxie", "NTS Breakfast".
    struct RadioShow: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var provider: String
        var externalID: String
        var station: String?
        var title: String?
        var description: String?
        var hostName: String?
        var imageURL: String?
        var providerURL: String?

        enum CodingKeys: String, CodingKey {
            case id, provider, station, title, description
            case externalID = "external_id"
            case hostName = "host_name"
            case imageURL = "image_url"
            case providerURL = "provider_url"
        }
    }

    /// One broadcast of a programme.
    struct RadioEpisode: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var radioShowID: UUID?
        var provider: String
        var externalID: String
        var title: String?
        var description: String?
        var airedAt: Date?
        var durationSeconds: Int?
        var archiveURL: String?
        var imageURL: String?
        /// Whether anyone has published a tracklist for this broadcast, so a
        /// second pass knows the difference between "not looked at" and
        /// "looked at, and there is none".
        var tracklistStatus: String

        enum CodingKeys: String, CodingKey {
            case id, provider, title, description
            case radioShowID = "radio_show_id"
            case externalID = "external_id"
            case airedAt = "aired_at"
            case durationSeconds = "duration_seconds"
            case archiveURL = "archive_url"
            case imageURL = "image_url"
            case tracklistStatus = "tracklist_status"
        }
    }

    /// One track in one broadcast.
    ///
    /// `recordingID` and `artistID` are both optional, and that is the design
    /// rather than a gap in it: a station announces "Skee Mask - Flyby VFR"
    /// long before Indigo has a recording to point at, and the white labels
    /// and dubplates that never resolve are the ones most worth keeping.
    struct RadioAppearance: Codable, Sendable, Identifiable, Hashable {
        var id: UUID
        var radioEpisodeID: UUID?
        var recordingID: UUID?
        var artistID: UUID?
        var trackIndex: Int?
        var rawArtistName: String?
        var rawTrackTitle: String?
        var offsetSeconds: Int?
        var endOffsetSeconds: Int?
        var identificationSource: String?
        var confidence: Double?

        enum CodingKeys: String, CodingKey {
            case id, confidence
            case radioEpisodeID = "radio_episode_id"
            case recordingID = "recording_id"
            case artistID = "artist_id"
            case trackIndex = "track_index"
            case rawArtistName = "raw_artist_name"
            case rawTrackTitle = "raw_track_title"
            case offsetSeconds = "offset_seconds"
            case endOffsetSeconds = "end_offset_seconds"
            case identificationSource = "identification_source"
        }
    }
}

// MARK: - Radio read models
//
// Shaped by the database functions in 0004 rather than assembled here. An
// artist page needs the counts, not every row it took to reach them, and
// sending the rows so the app can count them is the round trip this avoids.

nonisolated extension Catalog {
    struct ArtistRadioSummary: Codable, Sendable, Hashable {
        var artistID: UUID
        var appearanceCount: Int
        var episodeCount: Int
        var showCount: Int
        var hostCount: Int
        var firstAppearanceAt: Date?
        var latestAppearanceAt: Date?
        var topShows: [TopShow]

        struct TopShow: Codable, Sendable, Hashable, Identifiable {
            var showID: UUID
            var provider: String
            /// The station's own handle for the programme — an NTS show alias.
            /// Carried so a name in this list can open the show it names.
            var externalID: String
            var title: String?
            var station: String?
            var hostName: String?
            var appearanceCount: Int

            var id: UUID { showID }

            /// Never the URL slug a show was created under before anyone
            /// fetched its description.
            var displayName: String {
                let name = title?.nilIfEmpty ?? externalID
                return name == externalID
                    ? externalID.replacingOccurrences(of: "-", with: " ").capitalized
                    : name
            }

            enum CodingKeys: String, CodingKey {
                case title, station, provider
                case showID = "show_id"
                case externalID = "external_id"
                case hostName = "host_name"
                case appearanceCount = "appearance_count"
            }
        }

        var isEmpty: Bool { appearanceCount == 0 }

        enum CodingKeys: String, CodingKey {
            case artistID = "artist_id"
            case appearanceCount = "appearance_count"
            case episodeCount = "episode_count"
            case showCount = "show_count"
            case hostCount = "host_count"
            case firstAppearanceAt = "first_appearance_at"
            case latestAppearanceAt = "latest_appearance_at"
            case topShows = "top_shows"
        }
    }

    /// One line of "where have I heard this artist on radio": which show, which
    /// broadcast, what was played, and where in it.
    struct ArtistRadioAppearance: Codable, Sendable, Hashable, Identifiable {
        var appearanceID: UUID
        var episodeID: UUID
        var episodeTitle: String?
        var airedAt: Date?
        var archiveURL: String?
        var episodeExternalID: String
        var provider: String
        var showID: UUID?
        var showTitle: String?
        var station: String?
        var hostName: String?
        var trackIndex: Int?
        var rawArtistName: String?
        var rawTrackTitle: String?
        var offsetSeconds: Int?
        var recordingID: UUID?

        var id: UUID { appearanceID }

        enum CodingKeys: String, CodingKey {
            case provider, station
            case appearanceID = "appearance_id"
            case episodeID = "episode_id"
            case episodeTitle = "episode_title"
            case airedAt = "aired_at"
            case archiveURL = "archive_url"
            case episodeExternalID = "episode_external_id"
            case showID = "show_id"
            case showTitle = "show_title"
            case hostName = "host_name"
            case trackIndex = "track_index"
            case rawArtistName = "raw_artist_name"
            case rawTrackTitle = "raw_track_title"
            case offsetSeconds = "offset_seconds"
            case recordingID = "recording_id"
        }
    }

    /// A tracklist read back from Indigo rather than from the station.
    struct EpisodeTrack: Codable, Sendable, Hashable, Identifiable {
        var appearanceID: UUID
        var trackIndex: Int?
        var rawArtistName: String?
        var rawTrackTitle: String?
        var offsetSeconds: Int?
        var artistID: UUID?
        var artistName: String?
        var recordingID: UUID?

        var id: UUID { appearanceID }

        enum CodingKeys: String, CodingKey {
            case appearanceID = "appearance_id"
            case trackIndex = "track_index"
            case rawArtistName = "raw_artist_name"
            case rawTrackTitle = "raw_track_title"
            case offsetSeconds = "offset_seconds"
            case artistID = "artist_id"
            case artistName = "artist_name"
            case recordingID = "recording_id"
        }
    }
}

// MARK: - Grouping

nonisolated extension Catalog {
    /// One broadcast and everything of this artist's that was played in it.
    ///
    /// The database returns a flat list because that is the cheap query; a
    /// page reads as broadcasts, each with the tracks it contained. Grouping
    /// here rather than in a view keeps it testable and keeps every screen
    /// that shows radio agreeing about what a broadcast is called.
    struct RadioEpisodeGroup: Identifiable, Sendable, Hashable {
        let episodeID: UUID
        let provider: String
        let externalID: String
        let showTitle: String?
        let episodeTitle: String?
        let station: String?
        let airedAt: Date?
        let archiveURL: String?
        let tracks: [ArtistRadioAppearance]

        var id: UUID { episodeID }

        /// "NTS — Ben UFO", or as much of it as is actually known. Never the
        /// URL slug an unnamed show was created under.
        var heading: String {
            let name = showTitle?.nilIfEmpty ?? episodeTitle?.nilIfEmpty
            let left = station?.nilIfEmpty
            return [left, name].compactMap { $0 }.joined(separator: " — ")
                .nilIfEmpty ?? provider.uppercased()
        }

        /// "12 Jun 2026".
        var dateLabel: String? {
            guard let airedAt else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: airedAt)
        }
    }

    /// Flat rows to broadcasts, keeping the order the database chose — newest
    /// first, and each episode's tracks in the order they were played.
    static func groupedByEpisode(_ appearances: [ArtistRadioAppearance]) -> [RadioEpisodeGroup] {
        var order: [UUID] = []
        var byEpisode: [UUID: [ArtistRadioAppearance]] = [:]

        for appearance in appearances {
            if byEpisode[appearance.episodeID] == nil { order.append(appearance.episodeID) }
            byEpisode[appearance.episodeID, default: []].append(appearance)
        }

        return order.compactMap { episodeID in
            guard let tracks = byEpisode[episodeID], let first = tracks.first else { return nil }
            return RadioEpisodeGroup(
                episodeID: episodeID,
                provider: first.provider,
                externalID: first.episodeExternalID,
                showTitle: first.showTitle,
                episodeTitle: first.episodeTitle,
                station: first.station,
                airedAt: first.airedAt,
                archiveURL: first.archiveURL,
                tracks: tracks
            )
        }
    }
}

nonisolated extension Catalog.ArtistRadioAppearance {
    /// What the show said was playing. The raw strings, not a resolved title:
    /// what a selector announced is the record of what was played, and for
    /// most of these there is no resolved recording to prefer over it.
    var trackLine: String {
        let artist = rawArtistName?.nilIfEmpty
        let title = rawTrackTitle?.nilIfEmpty
        return [artist, title].compactMap { $0 }.joined(separator: " — ")
            .nilIfEmpty ?? "Untitled"
    }

    /// "1:14:32" into the broadcast, when the station reported one.
    var offsetLabel: String? {
        guard let offsetSeconds, offsetSeconds > 0 else { return nil }
        return TimeFormat.clock(TimeInterval(offsetSeconds))
    }
}

// MARK: - Radio-derived relationships
//
// The DIG edges radio produces (4G). Every one carries the count it was derived
// from, because an unexplained score is the thing this app exists not to show:
// "played alongside in nine episodes" is a reason, and 0.87 is not.

nonisolated extension Catalog {
    struct RadioRelation: Codable, Sendable, Hashable, Identifiable {
        var relationshipType: String
        var entityType: String
        var entityID: UUID
        var title: String?
        var station: String?
        var provider: String?
        var externalID: String?
        var evidenceCount: Int
        var confidence: Double?
        var metadata: Evidence?

        /// What the edge was counted from. Which field is filled depends on
        /// the kind of edge, so all of them are optional.
        struct Evidence: Codable, Sendable, Hashable {
            var episodes: Int?
            var appearances: Int?
            var adjacencies: Int?
        }

        var id: String { "\(relationshipType)|\(entityID.uuidString)" }

        /// Never the URL slug a show was created under before anyone fetched
        /// its description.
        var displayName: String {
            let name = title?.nilIfEmpty ?? externalID ?? "Unknown"
            return name == externalID
                ? name.replacingOccurrences(of: "-", with: " ").capitalized
                : name
        }

        /// The line that answers "why this?".
        var reason: String? {
            switch relationshipType {
            case "played_by":
                let episodes = metadata?.episodes ?? evidenceCount
                return episodes == 1
                    ? "Played in one broadcast"
                    : "Played in \(episodes) broadcasts"
            case "radio_neighbor":
                let adjacent = metadata?.adjacencies ?? evidenceCount
                return adjacent == 1
                    ? "Played back to back once"
                    : "Played back to back \(adjacent) times"
            default:
                return nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case title, station, provider, confidence, metadata
            case relationshipType = "relationship_type"
            case entityType = "entity_type"
            case entityID = "entity_id"
            case externalID = "external_id"
            case evidenceCount = "evidence_count"
        }
    }

    /// §10. What radio knows about a label.
    ///
    /// `derivation` is part of the answer, not decoration: this is currently
    /// reached through the label's artists rather than its records, because
    /// appearances matched to recordings barely exist yet. A page that renders
    /// this should be able to say which claim it is making.
    struct LabelRadioSummary: Codable, Sendable, Hashable {
        var labelID: UUID
        var derivation: String
        var appearanceCount: Int
        var episodeCount: Int
        var showCount: Int
        var artistCount: Int
        var firstAppearanceAt: Date?
        var latestAppearanceAt: Date?
        var topShows: [ArtistRadioSummary.TopShow]
        var topArtists: [TopArtist]

        struct TopArtist: Codable, Sendable, Hashable, Identifiable {
            var artistID: UUID
            var name: String?
            var appearanceCount: Int

            var id: UUID { artistID }

            enum CodingKeys: String, CodingKey {
                case name
                case artistID = "artist_id"
                case appearanceCount = "appearance_count"
            }
        }

        var isEmpty: Bool { appearanceCount == 0 }

        /// True when the numbers describe the label's roster rather than its
        /// records. Worth saying out loud on screen.
        var isViaRoster: Bool { derivation == "artist_roster" }

        enum CodingKeys: String, CodingKey {
            case derivation
            case labelID = "label_id"
            case appearanceCount = "appearance_count"
            case episodeCount = "episode_count"
            case showCount = "show_count"
            case artistCount = "artist_count"
            case firstAppearanceAt = "first_appearance_at"
            case latestAppearanceAt = "latest_appearance_at"
            case topShows = "top_shows"
            case topArtists = "top_artists"
        }
    }
}
