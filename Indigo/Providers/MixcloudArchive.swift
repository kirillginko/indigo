//
//  MixcloudArchive.swift
//  Indigo
//
//  Mixcloud's public API — open, documented and needing no key — which is
//  where a good share of community radio keeps its recordings rather than
//  hosting them itself.
//
//  alHara's whole archive lives there, and Radio 80000 keeps a playlist per
//  show there alongside its SoundCloud one, so the shapes live here rather
//  than in whichever provider happened to need them first.
//
//  Playback goes through Mixcloud's own widget, as their terms require:
//  Indigo does not resolve the underlying audio and must not be made to.
//

import Foundation

/// One page of cloudcasts. Mixcloud pages by opaque cursor URL rather than by
/// number, so `paging.next` is the only way on.
nonisolated struct MixcloudPageDTO: Decodable, Sendable {
    let data: [MixcloudCloudcastDTO]
    let paging: Paging?

    nonisolated struct Paging: Decodable, Sendable {
        let next: String?
        let previous: String?
    }
}

nonisolated struct MixcloudCloudcastDTO: Decodable, Sendable {
    let key: String?
    let url: String?
    let name: String?
    let slug: String?
    let created_time: String?
    /// Seconds.
    let audio_length: Int?
    let play_count: Int?
    let favorite_count: Int?
    let tags: [Tag]?
    /// Size name → address. Mixcloud offers ten of them.
    let pictures: [String: String]?
    // Detail only.
    let description: String?
    let sections: [Section]?

    nonisolated struct Tag: Decodable, Sendable {
        let name: String?
        let key: String?
    }

    /// Mixcloud's tracklist. Most uploads have none, and the ones that do give
    /// a start time per track.
    nonisolated struct Section: Decodable, Sendable {
        let start_time: Int?
        let track: Track?

        nonisolated struct Track: Decodable, Sendable {
            let name: String?
            let artist: Artist?
            nonisolated struct Artist: Decodable, Sendable { let name: String? }
        }
    }

    /// Large enough for a detail hero, small enough not to pull the 1024px
    /// original into a grid tile.
    var artworkURL: URL? {
        let preferred = ["large", "640wx640h", "extra_large", "320wx320h", "medium", "thumbnail"]
        for size in preferred {
            if let address = pictures?[size], let url = URL(string: address) { return url }
        }
        return pictures?.values.first.flatMap { URL(string: $0) }
    }
}
