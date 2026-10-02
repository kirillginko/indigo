//
//  RecordingIdentity.swift
//  Indigo
//
//  What names a recording on every device, as opposed to `Recording.id`, which
//  names it on one. This is the only place that builds the string and the only
//  place that takes it apart: nothing else concatenates a key and a code, so
//  the encoding can change here and nowhere else.
//
//  Two parts, because one is not enough:
//
//    * the match key, from artist and title. Most recordings are named by it
//      alone, and everything that is crated or dug into by name already is.
//    * a code, for the recordings a key cannot tell apart. "Unreleased" by one
//      artist at six points in a show is six recordings with one key; each
//      carries a code made from where it was heard. Music nobody named has a
//      code and no key at all.
//
//  The match key is built from letters, digits and single spaces and never
//  contains the separator, which is what makes `init?(key:)` unambiguous.
//
//  The invariant this exists to protect: no two recordings in a store have the
//  same identity. `RecordingStore.identityCollisions()` checks it.
//

import Foundation

nonisolated struct RecordingIdentity: Hashable, Sendable {
    let matchKey: String
    let unknownCode: String?

    private static let separator: Character = "#"

    init(matchKey: String, unknownCode: String?) {
        self.matchKey = matchKey
        self.unknownCode = unknownCode.flatMap { $0.isEmpty ? nil : $0 }
    }

    init(_ recording: Recording) {
        self.init(matchKey: recording.matchKey, unknownCode: recording.unknownCode)
    }

    /// Nothing identifies it: no key and no code.
    var isEmpty: Bool { matchKey.isEmpty && unknownCode == nil }

    /// "papo2oo4unreleased", "papo2oo4unreleased#EAE1B", or for music nobody
    /// named, its code alone. Empty only when `isEmpty`.
    var key: String {
        guard let unknownCode else { return matchKey }
        return matchKey.isEmpty ? unknownCode : "\(matchKey)\(Self.separator)\(unknownCode)"
    }

    static func key(matchKey: String, unknownCode: String?) -> String {
        RecordingIdentity(matchKey: matchKey, unknownCode: unknownCode).key
    }

    /// Reads a key written by `key`. A bare string is a match key: a code on
    /// its own is only ever written for music with no key, and a caller that
    /// holds one says so with `init(unnamedCode:)`.
    init?(key: String) {
        guard !key.isEmpty else { return nil }
        if let index = key.firstIndex(of: Self.separator) {
            self.init(
                matchKey: String(key[..<index]),
                unknownCode: String(key[key.index(after: index)...]))
        } else {
            self.init(matchKey: key, unknownCode: nil)
        }
    }

    init(unnamedCode code: String) {
        self.init(matchKey: "", unknownCode: code)
    }

    /// The identity a node names, when it names a recording.
    init?(node: MusicNode) {
        switch node.kind {
        case .recording: self.init(key: node.key)
        case .unknownRecording: self.init(unnamedCode: node.key)
        default: return nil
        }
    }
}
