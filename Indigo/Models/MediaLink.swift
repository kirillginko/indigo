//
//  MediaLink.swift
//  Indigo
//
//  Where else a thing can be heard. Stations publish these as loose lists of
//  addresses — an artist's Bandcamp, a booking's ticket page — and every
//  provider that reads one wants the same shape, so it lives here rather than
//  inside whichever one happened to need it first.
//

import Foundation

nonisolated struct MediaLink: Identifiable, Hashable, Sendable {
    /// "Bandcamp", "Instagram" — the status vocabulary, not a sentence.
    let label: String
    let url: URL

    var id: String { "\(label)|\(url.absoluteString)" }

    /// "instagram.com" reads as Instagram; anything unrecognised keeps its
    /// host, which is more honest than inventing a name for it.
    static func label(for url: URL) -> String {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let known = [
            "instagram.com": "Instagram",
            "soundcloud.com": "SoundCloud",
            "bandcamp.com": "Bandcamp",
            "mixcloud.com": "Mixcloud",
            "facebook.com": "Facebook",
            "twitter.com": "Twitter",
            "x.com": "X",
            "youtube.com": "YouTube",
            "spotify.com": "Spotify",
            "ra.co": "RA",
            "dice.fm": "Dice",
            "linktr.ee": "Linktree"
        ]
        for (suffix, name) in known where host == suffix || host.hasSuffix("." + suffix) {
            return name
        }
        return host.isEmpty ? "Link" : host
    }
}
