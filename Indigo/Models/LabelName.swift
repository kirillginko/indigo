//
//  LabelName.swift
//  Indigo
//
//  Names that are not labels.
//
//  Discogs files a self-released record under "Not On Label", often with the
//  artist's name in brackets after it — "Not On Label (Seefeel Self-Released)".
//  It is the absence of a label written down, not an imprint, and treated as
//  one it does the same damage "Various" does to artists: every self-released
//  record in the catalogue becomes a labelmate of every other, and the app
//  cheerfully explains that two strangers are connected because both are on
//  Not On Label.
//
//  Being self-released is a real and interesting fact. It is just not a
//  shared one.
//

import Foundation

nonisolated enum LabelName {
    private static let exact: Set<String> = [
        "unknown label", "no label", "none", "unknown", "self released",
        "self release", "white label"
    ]

    /// Whether this stands for the absence of a label.
    ///
    /// "Not On Label" is matched as a prefix, unlike the rest: Discogs almost
    /// always appends whose self-release it was, and every one of those is
    /// still not a label.
    static func isPlaceholder(_ name: String?) -> Bool {
        guard let name else { return false }
        let key = RecordingKey.normalize(name)
        guard !key.isEmpty else { return true }
        return key.hasPrefix("not on label") || exact.contains(key)
    }

    static func isRealLabel(_ name: String?) -> Bool {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !isPlaceholder(name)
    }
}
