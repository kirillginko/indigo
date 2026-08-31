//
//  RadioNeighborhoodEngine.swift
//  Indigo
//
//  Builds the radio portion of the discovery graph from provenance Indigo
//  already owns. A show appearance is useful on its own; repeated co-play and
//  timestamped adjacency are progressively stronger evidence.
//

import Foundation
import SwiftData

nonisolated struct RadioNeighborhoodEngine {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Promotes a published NTS tracklist into canonical recordings and
    /// appearances. Loading the same episode again is idempotent: RecordingStore
    /// reuses recordings and collapses the matching appearance.
    func ingest(_ detail: NTSEpisodeDetail) {
        let store = RecordingStore(context: context)
        let showID = detail.summary.id
        let broadcastAt = detail.summary.broadcastAt ?? Date()
        let matchCounts = Dictionary(grouping: detail.tracklist, by: matchKey).mapValues(\.count)

        for entry in detail.tracklist {
            if recording(for: entry, in: detail) != nil { continue }
            let artist = entry.artist == "Unknown Artist" ? nil : entry.artist
            let recording: Recording
            if matchCounts[matchKey(entry), default: 0] > 1 {
                // Repeated placeholders such as “Unreleased” are not evidence
                // that two positions contain the same music. Keep each row as
                // a probable recording until stronger metadata can merge it.
                recording = Recording(title: entry.title, artistName: artist, status: .probable)
                context.insert(recording)
            } else if let resolved = try? store.upsert(
                title: entry.title,
                artistName: artist,
                status: artist == nil ? .probable : .identified
            ) {
                recording = resolved
            } else {
                continue
            }
            let offset = entry.offset.map(Double.init)
            store.note(
                appearance: MediaAppearance(
                    providerID: "nts",
                    stationName: "NTS",
                    showTitle: detail.summary.name,
                    showID: showID,
                    heardAt: broadcastAt.addingTimeInterval(offset ?? 0),
                    offsetSeconds: offset,
                    isLive: false,
                    method: .providerTracklist,
                    originalMetadata: "\(entry.artist) — \(entry.title)"
                ),
                on: recording
            )
            store.link(
                recording,
                toBroadcast: showID,
                providerID: "nts",
                offsetSeconds: offset
            )
            let rowSource = RecordingSource(
                kind: .broadcastAppearance,
                identifier: tracklistIdentity(entry, detail: detail),
                providerID: "nts.tracklist.row",
                offsetSeconds: offset
            )
            context.insert(rowSource)
            rowSource.recording = recording
        }
    }

    func recording(for entry: NTSTracklistEntry, in detail: NTSEpisodeDetail) -> Recording? {
        let identity = tracklistIdentity(entry, detail: detail)
        var descriptor = FetchDescriptor<RecordingSource>(
            predicate: #Predicate {
                $0.identifier == identity && $0.providerID == "nts.tracklist.row"
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.recording
    }

    private func tracklistIdentity(_ entry: NTSTracklistEntry, detail: NTSEpisodeDetail) -> String {
        "\(detail.summary.id)|\(entry.id)"
    }

    private func matchKey(_ entry: NTSTracklistEntry) -> String {
        RecordingKey.match(
            artist: entry.artist == "Unknown Artist" ? nil : entry.artist,
            title: entry.title
        )
    }

    func graph(around subject: Recording) -> MusicGraph {
        let all = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        return graph(around: subject, recordings: all)
    }

    /// Internal input seam keeps the ranking deterministic and independently
    /// testable while the public API continues to read SwiftData.
    func graph(around subject: Recording, recordings: [Recording]) -> MusicGraph {
        var graph = MusicGraph()
        let subjectNode = MusicNode.recording(subject)
        graph.insert(subjectNode)

        let subjectShows = Dictionary(
            subject.appearances.compactMap { appearance -> (String, MediaAppearance)? in
                guard let key = showKey(appearance) else { return nil }
                return (key, appearance)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for appearance in subjectShows.values {
            guard let showID = appearance.showID else { continue }
            let show = MusicNode.broadcast(
                providerID: appearance.providerID,
                showID: showID,
                title: appearance.showTitle
            )
            graph.connect(
                from: subjectNode, to: show,
                reason: Relationship(
                    kind: .playedInShow, source: .radio,
                    detail: "Appears in \(appearance.sourceLine)", confidence: 0.98
                )
            )

            if let selectorName = appearance.showTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !selectorName.isEmpty {
                let selector = MusicNode.selector(selectorName, providerID: appearance.providerID)
                graph.connect(
                    from: subjectNode, to: selector,
                    reason: Relationship(
                        kind: .playedBySameSelector, source: .radio,
                        detail: "Played by \(selectorName)", confidence: 0.82
                    )
                )
            }
        }

        for peer in recordings where peer.id != subject.id {
            let peerByShow = Dictionary(
                peer.appearances.compactMap { appearance -> (String, MediaAppearance)? in
                    guard let key = showKey(appearance) else { return nil }
                    return (key, appearance)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let shared = Set(subjectShows.keys).intersection(peerByShow.keys)
            guard !shared.isEmpty else { continue }

            let peerNode = MusicNode.recording(peer)
            let count = shared.count
            graph.connect(
                from: subjectNode, to: peerNode,
                reason: Relationship(
                    kind: .sharedBroadcast, source: .radio,
                    detail: count == 1
                        ? "Played in the same radio show"
                        : "Played in \(count) of the same radio shows",
                    confidence: ConfidenceMath.reinforced(0.62, occurrences: count)
                )
            )

            let adjacentCount = shared.reduce(0) { count, key in
                guard let lhs = subjectShows[key]?.offsetSeconds,
                      let rhs = peerByShow[key]?.offsetSeconds else { return count }
                return count + (areImmediateNeighbors(
                    lhs: subject.id, rhs: peer.id, in: key, recordings: recordings
                ) && abs(lhs - rhs) <= 20 * 60 ? 1 : 0)
            }
            if adjacentCount > 0 {
                graph.connect(
                    from: subjectNode, to: peerNode,
                    reason: Relationship(
                        kind: .frequentlyPlayedNearby, source: .radio,
                        detail: adjacentCount == 1
                            ? "Played immediately nearby in a radio show"
                            : "Played immediately nearby in \(adjacentCount) radio shows",
                        confidence: ConfidenceMath.reinforced(0.76, occurrences: adjacentCount)
                    )
                )
            }
        }

        return graph
    }

    private func showKey(_ appearance: MediaAppearance) -> String? {
        guard let showID = appearance.showID, !showID.isEmpty else { return nil }
        return "\(appearance.providerID)|\(showID)"
    }

    private func areImmediateNeighbors(
        lhs: UUID,
        rhs: UUID,
        in show: String,
        recordings: [Recording]
    ) -> Bool {
        let ordered = recordings.compactMap { recording -> (UUID, Double)? in
            guard let appearance = recording.appearances.first(where: { showKey($0) == show }),
                  let offset = appearance.offsetSeconds else { return nil }
            return (recording.id, offset)
        }.sorted { $0.1 < $1.1 }

        guard let left = ordered.firstIndex(where: { $0.0 == lhs }),
              let right = ordered.firstIndex(where: { $0.0 == rhs }) else { return false }
        return abs(left - right) == 1
    }
}
