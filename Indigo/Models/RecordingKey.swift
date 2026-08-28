//
//  RecordingKey.swift
//  Indigo
//
//  Normalisation used to decide whether two pieces of metadata describe the
//  same recording, and to mint stable handles for the ones that describe
//  nothing yet.
//

import Foundation

nonisolated enum RecordingKey {
    /// Noise that appears in one catalogue's title and not another's. Stripped
    /// before comparison so "Rev8617 (Original Mix)" and "Rev8617" are one
    /// recording rather than two.
    private static let droppedSuffixes = [
        "original mix", "radio edit", "album version", "remastered",
        "remaster", "extended mix", "single version", "mono", "stereo"
    ]

    /// Case-, diacritic- and punctuation-insensitive form used for comparison.
    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Normalised title with the bracketed cruft catalogues disagree about
    /// removed. "Rev8617 (Original Mix)" → "rev8617".
    static func normalizeTitle(_ value: String?) -> String {
        guard let value else { return "" }
        // Drop bracketed asides before normalising, so "(feat. X)" and
        // "[Original Mix]" don't survive as loose words.
        var trimmed = ""
        var depth = 0
        for character in value {
            if character == "(" || character == "[" { depth += 1; continue }
            if character == ")" || character == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { trimmed.append(character) }
        }
        var normalized = normalize(trimmed)
        for suffix in droppedSuffixes where normalized.hasSuffix(" \(suffix)") {
            normalized = String(normalized.dropLast(suffix.count + 1))
        }
        return normalized
    }

    /// Artist names carry the most variation across catalogues; featured
    /// artists are dropped so the primary credit decides identity.
    static func normalizeArtist(_ value: String?) -> String {
        guard let value else { return "" }
        var name = value
        for separator in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " x ", " vs. ", " vs "] {
            if let range = name.range(of: separator, options: .caseInsensitive) {
                name = String(name[name.startIndex..<range.lowerBound])
            }
        }
        return normalize(name)
    }

    /// The dedup key for a canonical recording. Empty when there isn't enough
    /// metadata to claim identity, which is exactly the unknown case — and an
    /// empty key must never match another empty key.
    static func match(artist: String?, title: String?) -> String {
        let artistKey = normalizeArtist(artist)
        let titleKey = normalizeTitle(title)
        guard !titleKey.isEmpty else { return "" }
        return "\(artistKey)\u{1F}\(titleKey)"
    }

    /// A stable five-character handle for music nobody could name, derived
    /// from where and when it was heard so the same discovery always mints the
    /// same code and two different discoveries practically never collide.
    static func unknownCode(providerID: String, showID: String?, heardAt: Date, offsetSeconds: Double?) -> String {
        let offset = offsetSeconds.map { String(Int($0.rounded())) } ?? "-"
        let seed = "\(providerID)|\(showID ?? "-")|\(Int(heardAt.timeIntervalSince1970))|\(offset)"
        return code(from: seed)
    }

    /// FNV-1a over the seed, rendered as five uppercase hex characters. Chosen
    /// over `hashValue` because Swift's hashing is seeded per process — a code
    /// minted today has to still be the same code tomorrow.
    static func code(from seed: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let value = (hash ^ (hash >> 32)) & 0xFFFFF
        return String(format: "%05X", value)
    }
}
