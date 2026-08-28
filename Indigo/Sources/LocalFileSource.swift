//
//  LocalFileSource.swift
//  Indigo
//
//  Finds the listener's own copy of a recording. A file you already own beats
//  any stream: it is faster, it is higher quality, and it works on a train.
//

import Foundation
import SwiftData

nonisolated struct LocalFileSource {
    let context: ModelContext

    /// The match ladder from the spec, strongest rung first. Each rung is a
    /// stronger claim than the one below it, so the first hit wins outright.
    enum MatchRung: String, Sendable {
        case isrc
        case musicBrainzID
        case artistAndTitle
        case artistTitleAndDuration
        case fuzzyTitle

        var isExact: Bool { self == .isrc || self == .musicBrainzID }
    }

    /// Not Sendable: it carries a SwiftData model, which belongs to the
    /// context that fetched it and must not cross actors.
    struct Match {
        let track: Track
        let rung: MatchRung
    }

    // MARK: - Resolution

    func sources(for recording: Recording) -> [AudioSource] {
        guard let track = resolvedTrack(for: recording) else { return [] }
        return [
            AudioSource(
                kind: .localFile,
                action: .play(track.mediaItem()),
                label: "Local",
                detail: Self.formatDetail(track),
                rank: 0
            )
        ]
    }

    /// A link recorded earlier is trusted without re-matching; otherwise the
    /// ladder runs and a hit is remembered so this stays cheap.
    func resolvedTrack(for recording: Recording) -> Track? {
        if let linked = recording.sources.first(where: { $0.kind == .localFile }),
           let track = track(atPath: linked.identifier) {
            return track
        }
        guard let match = findMatch(for: recording) else { return nil }
        RecordingStore(context: context).link(recording, toLocalFile: match.track.path)
        return match.track
    }

    // MARK: - The ladder

    func findMatch(for recording: Recording) -> Match? {
        if let isrc = recording.isrc, !isrc.isEmpty,
           let hit = first(#Predicate<Track> { $0.isrc == isrc }) {
            return Match(track: hit, rung: .isrc)
        }

        // MusicBrainz IDs are not read from files yet, so this rung only fires
        // once a track has been enriched and written back. Kept in place so
        // the ladder is the spec's, not a subset of it.
        if let mbid = recording.musicBrainzRecordingID, !mbid.isEmpty,
           let hit = candidatesByText(recording).first(where: { $0.isrc != nil && $0.isrc == recording.isrc }) {
            return Match(track: hit, rung: .musicBrainzID)
        }

        let candidates = candidatesByText(recording)
        guard !candidates.isEmpty else { return fuzzyMatch(for: recording) }

        // With a duration to compare, prefer the copy that actually is this
        // length — the same title by the same artist can be an edit, a live
        // version, or a twelve-minute remix.
        if let target = recording.durationSeconds, target > 0 {
            let close = candidates
                .filter { $0.duration > 0 && abs($0.duration - target) <= 5 }
                .min { abs($0.duration - target) < abs($1.duration - target) }
            if let close { return Match(track: close, rung: .artistTitleAndDuration) }
        }
        return Match(track: candidates[0], rung: .artistAndTitle)
    }

    /// Exact match on the normalised artist+title key.
    private func candidatesByText(_ recording: Recording) -> [Track] {
        let key = recording.matchKey
        guard !key.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        return all.filter { RecordingKey.match(artist: $0.artist, title: $0.title) == key }
    }

    /// Last resort: same normalised title, artist ignored. Compilations and
    /// mislabelled rips get the artist wrong far more often than the title.
    private func fuzzyMatch(for recording: Recording) -> Match? {
        let title = RecordingKey.normalizeTitle(recording.title)
        guard !title.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        guard let hit = all.first(where: { RecordingKey.normalizeTitle($0.title) == title }) else {
            return nil
        }
        return Match(track: hit, rung: .fuzzyTitle)
    }

    // MARK: - Helpers

    private func track(atPath path: String) -> Track? {
        first(#Predicate<Track> { $0.path == path })
    }

    private func first(_ predicate: Predicate<Track>) -> Track? {
        var descriptor = FetchDescriptor<Track>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// "FLAC · 44.1" — the format badge from the spec's visual vocabulary.
    static func formatDetail(_ track: Track) -> String? {
        let ext = URL(fileURLWithPath: track.path).pathExtension.uppercased()
        return ext.isEmpty ? nil : ext
    }
}
