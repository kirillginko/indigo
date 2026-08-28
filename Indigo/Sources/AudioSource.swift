//
//  AudioSource.swift
//  Indigo
//
//  A resolved way to hear a recording. The UI asks for a recording and gets
//  these back, ranked; it never picks a provider itself. That is the whole
//  point of the seam — adding Bandcamp later must not touch a single view.
//

import Foundation

nonisolated enum SourceAction: Hashable, Sendable {
    /// Hand this straight to the player.
    case play(MediaItem)
    /// The music is inside a broadcast rather than addressable on its own, so
    /// the honest thing is to open that broadcast at the right moment.
    case openBroadcast(DetailPage, offsetSeconds: Double?)
}

nonisolated struct AudioSource: Identifiable, Hashable, Sendable {
    let kind: AudioSourceKind
    let action: SourceAction
    /// "LOCAL", "NTS" — the status vocabulary, not a sentence.
    let label: String
    /// "FLAC · 44.1", "Moxie @ 01:14:32".
    let detail: String?
    /// Lower wins. Local files always outrank anything on the network.
    let rank: Int

    var id: String {
        switch action {
        case .play(let item): "play:\(item.id)"
        case .openBroadcast(let page, let offset): "open:\(page.hashValue):\(offset ?? -1)"
        }
    }

    var isPlayable: Bool {
        if case .play = action { return true }
        return false
    }

    /// "LOCAL / FLAC · 44.1"
    var displayLine: String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) / \(detail)"
    }
}
