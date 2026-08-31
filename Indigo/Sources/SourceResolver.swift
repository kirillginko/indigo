//
//  SourceResolver.swift
//  Indigo
//
//  The UI requests a recording. It does not choose its playback provider.
//
//      PLAY RECORDING
//          ↓
//      Local file?        YES ─→ PLAY LOCAL
//          ↓ NO
//      Known broadcast?   YES ─→ OPEN / SEEK SHOW
//          ↓ NO
//      Kept a link?       YES ─→ PLAY IN ITS OWN PLAYER
//          ↓ NO
//      No playable source
//

import Foundation
import SwiftData

nonisolated struct SourceResolver {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Every way this recording can currently be heard, best first.
    func resolve(_ recording: Recording) -> [AudioSource] {
        let local = LocalFileSource(context: context).sources(for: recording)
        let broadcast = BroadcastSource(context: context).sources(for: recording)
        let links = StreamingLinkSource(context: context).sources(for: recording)
        return (local + broadcast + links).sorted { $0.rank < $1.rank }
    }

    /// What pressing play should do.
    func best(_ recording: Recording) -> AudioSource? {
        resolve(recording).first
    }

    /// True when there is nothing to hear — the state the UI has to render
    /// honestly rather than showing a play button that does nothing.
    func isUnavailable(_ recording: Recording) -> Bool {
        resolve(recording).isEmpty
    }
}
