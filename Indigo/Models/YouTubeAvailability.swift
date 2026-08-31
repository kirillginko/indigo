//
//  YouTubeAvailability.swift
//  Indigo
//
//  Whether a recording can actually be played here, asked before it is
//  offered.
//
//  Uses YouTube's public oEmbed endpoint, which is the documented way to ask
//  about a video without an API key or a quota: it answers 200 for something
//  that can be embedded, 404 for one that has been removed or made private,
//  and 401 for one whose uploader has turned embedding off.
//
//  Verified here for the 404 case. The 401 case is YouTube's documented
//  behaviour but was not reproducible against a known example, so it is not
//  relied on alone — anything that fails at play time is remembered too, and
//  that is the layer certain to catch it.
//

import Foundation

nonisolated enum YouTubeAvailability {
    /// True if it can be played, false if it certainly cannot, nil if the
    /// question could not be asked.
    ///
    /// The distinction matters: a dropped connection must not be recorded as
    /// a verdict about the recording, or one bad minute of network hides a
    /// catalogue.
    static func isPlayable(_ url: URL, session: URLSession = NetworkEnvironment.metadataSession) async -> Bool? {
        guard YouTubeLink.isYouTube(url),
              var components = URLComponents(string: "https://www.youtube.com/oembed")
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let query = components.url else { return nil }

        var request = URLRequest(url: query)
        request.setValue(NetworkEnvironment.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            switch http.statusCode {
            case 200: return true
            case 401, 403, 404: return false
            default: return nil
            }
        } catch {
            return nil
        }
    }
}
