//
//  CrateItem.swift
//  Indigo
//
//  Something kept. The crate is deliberately not a playlist: it holds whatever
//  the listener wanted to keep — a named track, an unidentified one, a file
//  they already own, a whole broadcast — with the moment they kept it.
//

import Foundation
import SwiftData

nonisolated enum CrateItemKind: String, Codable, CaseIterable, Sendable {
    /// A piece of music, identified or not.
    case recording
    /// A whole broadcast: an NTS episode, a Kiosk show.
    case broadcast
}

@Model
nonisolated final class CrateItem {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var addedAt: Date

    /// Set for `.recording`.
    var recording: Recording?

    /// Set for `.broadcast`. Kept as plain fields rather than a relationship
    /// so a crated show survives the provider's catalogue changing under it.
    var providerID: String?
    var showID: String?
    var showTitle: String?
    var showSubtitle: String?
    var artworkURLString: String?
    /// What the player needs to start this broadcast again.
    var playbackURLString: String?
    var embedProviderRaw: String?
    var isLiveStream: Bool = false
    /// Newline-separated to keep SwiftData persistence simple while exposing
    /// a normal array to filtering views.
    var genreTagsRaw: String = ""

    init(recording: Recording) {
        self.id = UUID()
        self.kindRaw = CrateItemKind.recording.rawValue
        self.addedAt = Date()
        self.recording = recording
    }

    init(
        providerID: String,
        showID: String,
        showTitle: String,
        showSubtitle: String?,
        artworkURL: URL?,
        playbackURL: URL?,
        embedProvider: EmbedProvider?,
        isLiveStream: Bool,
        genres: [String] = []
    ) {
        self.id = UUID()
        self.kindRaw = CrateItemKind.broadcast.rawValue
        self.addedAt = Date()
        self.providerID = providerID
        self.showID = showID
        self.showTitle = showTitle
        self.showSubtitle = showSubtitle
        self.artworkURLString = artworkURL?.absoluteString
        self.playbackURLString = playbackURL?.absoluteString
        self.embedProviderRaw = embedProvider?.rawValue
        self.isLiveStream = isLiveStream
        self.genreTagsRaw = Self.cleanGenres(genres).joined(separator: "\n")
    }

    var kind: CrateItemKind {
        CrateItemKind(rawValue: kindRaw) ?? .recording
    }

    // MARK: Display

    var displayTitle: String {
        switch kind {
        case .recording: recording?.displayTitle ?? "Unknown"
        case .broadcast: showTitle ?? "Broadcast"
        }
    }

    var displaySubtitle: String? {
        switch kind {
        case .recording: recording?.displayArtist
        case .broadcast: showSubtitle
        }
    }

    /// "NTS 1 / Moxie @ 01:21:43" — where this came from, which is the crate's
    /// whole point.
    var sourceLine: String? {
        switch kind {
        case .recording:
            guard let appearance = recording?.firstAppearance else {
                return recording?.sources.contains { $0.kind == .localFile } == true
                    ? "Local Library"
                    : nil
            }
            var line = appearance.sourceLine
            if let offset = appearance.offsetLabel { line += " @ \(offset)" }
            return line
        case .broadcast:
            switch providerID {
            case "nts": return "NTS"
            case "kiosk": return "Kiosk Radio"
            default: return providerID?.capitalized
            }
        }
    }

    var artworkURL: URL? {
        guard let artworkURLString else { return nil }
        return URL(string: artworkURLString)
    }

    var genreTags: [String] {
        Self.cleanGenres(genreTagsRaw.components(separatedBy: "\n"))
    }

    func setGenres(_ genres: [String]) {
        genreTagsRaw = Self.cleanGenres(genres).joined(separator: "\n")
    }

    private static func cleanGenres(_ genres: [String]) -> [String] {
        var seen = Set<String>()
        return genres
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(LibraryKey.normalize($0)).inserted }
    }

    /// Status chip: MATCH / PROBABLE / UNKNOWN, or the kind of thing it is.
    var statusLabel: String? {
        switch kind {
        case .recording: recording?.identificationStatus.label
        case .broadcast: "Show"
        }
    }

    /// The same fact, in the app's shared status vocabulary.
    @MainActor
    var statusItem: StatusItem? {
        switch kind {
        case .recording:
            switch recording?.identificationStatus {
            case .identified: StatusItem("Match ✓", .affirmed)
            case .probable: StatusItem("Probable", .pending)
            case .unknown: StatusItem("Unknown", .pending)
            case nil: nil
            }
        case .broadcast:
            StatusItem("Show")
        }
    }

    /// Day bucket used for the TODAY / date headers in the crate.
    var addedDay: Date { Calendar.current.startOfDay(for: addedAt) }

    /// The item the player needs to hear this again, when the crate itself
    /// knows one. Recordings go through SourceResolver instead.
    func broadcastMediaItem() -> MediaItem? {
        guard kind == .broadcast,
              let playbackURLString,
              let url = URL(string: playbackURLString),
              let showID, let providerID
        else { return nil }
        return MediaItem(
            id: "crate.\(providerID).\(showID)",
            sourceID: providerID,
            kind: isLiveStream ? .radioStation : .episode,
            title: showTitle ?? "Broadcast",
            subtitle: showSubtitle,
            detail: sourceLine,
            genres: genreTags,
            remoteArtworkURL: artworkURL,
            playbackURL: url,
            embedProvider: embedProviderRaw.flatMap { EmbedProvider(rawValue: $0) }
        )
    }
}
