//
//  ArtworkSizing.swift
//  Indigo
//
//  A picture's address, asked for at the size it will be drawn.
//
//  Stations hand over one cut of each picture, sized for a list: NTS a
//  400-pixel one, Cashmere's WordPress and The Lot's Contentful 600, a
//  Mixcloud cover 600, a YouTube still 320. Drawn the width of a phone --
//  1,179 pixels -- they were blown up and blurred. Most of these hosts take
//  the size in the address, so a tile drawn large asks for a larger cut;
//  the small one stays the preview, so a size a host does not have falls
//  back to it rather than to nothing.
//

import Foundation

nonisolated enum ArtworkSizing {
    /// Below this many pixels a station's own cut is sharp enough.
    static let threshold: CGFloat = 640

    /// `url`, asked for at a size covering `pixels`; `url` unchanged where
    /// the host takes no size, or the tile is small.
    static func sharper(_ url: URL?, pixels: CGFloat?) -> URL? {
        guard let url, let pixels, pixels > threshold else { return url }
        let address = url.absoluteString
        let host = url.host ?? ""
        let edge = pixels <= 1000 ? 1000 : 1600

        // NTS: media*.ntslive.co.uk/resize/400x400/... -- 800 and 1600 exist.
        if host.hasSuffix("ntslive.co.uk"), address.contains("/resize/") {
            let size = pixels <= 800 ? 800 : 1600
            return URL(string: address.replacing(/\/resize\/\d+x\d+\//, with: "/resize/\(size)x\(size)/")) ?? url
        }
        // Mixcloud's thumbnailer: /unsafe/600x600/...
        if host.hasPrefix("thumbnailer.mixcloud.com") {
            return URL(string: address.replacing(/\/unsafe\/\d+x\d+\//, with: "/unsafe/\(edge)x\(edge)/")) ?? url
        }
        // Contentful (The Lot): a w= query.
        if host.contains("ctfassets.net"), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = parts.queryItems ?? []
            items.removeAll { $0.name == "w" }
            items.append(URLQueryItem(name: "w", value: String(edge)))
            parts.queryItems = items
            return parts.url ?? url
        }
        // WordPress sizes (Cashmere, Radio 80000): name-600x600.jpg is a cut
        // of name.jpg, the upload itself.
        if address.contains("/wp-content/uploads/") {
            return URL(string: address.replacing(/-\d+x\d+(?=\.[A-Za-z]+$)/, with: "")) ?? url
        }
        // YouTube stills: mqdefault is 320 wide; hq720 is 1280, for the
        // uploads that have one (the preview covers the rest).
        if host.hasSuffix("ytimg.com"), address.hasSuffix("/mqdefault.jpg") {
            return URL(string: address.replacingOccurrences(of: "/mqdefault.jpg", with: "/hq720.jpg")) ?? url
        }
        return url
    }
}
