//
//  YouTubeLink.swift
//  Indigo
//
//  Reading a video's identity out of the several shapes its address comes in.
//
//  Indigo plays YouTube through the official IFrame Player API, which is what
//  YouTube's terms permit; it does not resolve or download the underlying
//  stream, which they prohibit. All this file does is find the id the player
//  needs.
//

import Foundation

nonisolated enum YouTubeLink {
    /// The eleven-character video id, from whichever form the link takes:
    /// `watch?v=`, `youtu.be/`, `/embed/`, `/shorts/`.
    static func videoID(from url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path()

        if host.contains("youtu.be") {
            return validate(String(path.dropFirst()))
        }
        guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else {
            return nil
        }
        for prefix in ["/embed/", "/shorts/", "/v/", "/live/"] where path.hasPrefix(prefix) {
            return validate(String(path.dropFirst(prefix.count)))
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return validate(query.first { $0.name == "v" }?.value)
    }

    static func isYouTube(_ url: URL) -> Bool { videoID(from: url) != nil }

    /// Video ids are eleven characters of an unreserved alphabet. Checking is
    /// worth it: anything else handed to the player is a blank frame the
    /// listener has no way to interpret.
    private static func validate(_ value: String?) -> String? {
        guard var candidate = value, !candidate.isEmpty else { return nil }
        if let slash = candidate.firstIndex(of: "/") { candidate = String(candidate[..<slash]) }
        guard candidate.count == 11,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }
}
