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
    /// Catalogue entities kept while browsing DIG.
    case artist
    case release
    case label
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

    init(
        digKind: CrateItemKind,
        providerID: String,
        entityID: String,
        title: String,
        subtitle: String?,
        artworkURL: URL?,
        genres: [String] = []
    ) {
        precondition([.artist, .release, .label].contains(digKind))
        self.id = UUID()
        self.kindRaw = digKind.rawValue
        self.addedAt = Date()
        self.providerID = providerID
        self.showID = entityID
        self.showTitle = title
        self.showSubtitle = subtitle
        self.artworkURLString = artworkURL?.absoluteString
        self.genreTagsRaw = Self.cleanGenres(genres).joined(separator: "\n")
    }

    var kind: CrateItemKind {
        CrateItemKind(rawValue: kindRaw) ?? .recording
    }

    /// What this is, in the graph's terms.
    ///
    /// Two things in the app already switch on `(kind, providerID)` to decide
    /// where a crated row opens — the crate list and the explore map — and
    /// both are asking a narrower version of this question. Kept here so the
    /// listening log can file a save against the same identity DIG navigates
    /// to, rather than against a crate row nothing else knows about.
    ///
    /// Nil is a real answer: a broadcast whose provider forgot to say which
    /// one, or a dig row saved under a provider tag written after this was.
    var node: MusicNode? {
        switch kind {
        case .recording:
            return recording.map { MusicNode.recording($0, artwork: artworkURL) }
        case .broadcast:
            guard let providerID, let showID else { return nil }
            // A kept live stream is the station itself; there is no episode
            // to point at, which is exactly what made it a stream.
            return isLiveStream
                ? .station(providerID: providerID, stationID: showID)
                : .broadcast(providerID: providerID, showID: showID, title: showTitle)
        case .artist:
            guard let title = showTitle else { return nil }
            return providerID == "dig.artist.mbid"
                ? .artist(title, mbid: showID)
                : .artist(title)
        case .label:
            guard let title = showTitle else { return nil }
            return providerID == "dig.label.mbid"
                ? .label(title, mbid: showID)
                : .label(title)
        case .release:
            guard let title = showTitle else { return nil }
            return .release(title, discogsID: showID.flatMap(Int.init))
        }
    }

    // MARK: Display

    var displayTitle: String {
        switch kind {
        case .recording: recording?.displayTitle ?? "Unknown"
        case .broadcast: showTitle ?? "Broadcast"
        case .artist: showTitle ?? "Artist"
        case .release: showTitle ?? "Release"
        case .label: showTitle ?? "Label"
        }
    }

    var displaySubtitle: String? {
        switch kind {
        case .recording: recording?.displayArtist
        case .broadcast, .artist, .release, .label: showSubtitle
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
        case .artist, .release, .label:
            return "DIG"
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
        case .artist: "Artist"
        case .release: "Release"
        case .label: "Label"
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
        case .artist:
            StatusItem("Artist")
        case .release:
            StatusItem("Release")
        case .label:
            StatusItem("Label")
        }
    }

    /// Day bucket used for the TODAY / date headers in the crate.
    var addedDay: Date { Calendar.current.startOfDay(for: addedAt) }

    /// Whether this row was kept while a station was on air, and so is about
    /// the show rather than the station.
    ///
    /// Crating from the player bar stores the station's own id, because the
    /// station is what was playing — but the title it stores is the show's.
    /// The subtitle is what tells them apart: `CrateService.subtitle(for:)`
    /// puts the station there when a show was known, and leaves it to the
    /// item's own lines when it was not.
    ///
    /// It matters because the two do not mean the same thing later. "Neue
    /// Rituale", replayed, is whatever Radio 80000 is broadcasting now — the
    /// one thing the listener did not keep.
    var isLiveShowSnapshot: Bool {
        guard kind == .broadcast, isLiveStream else { return false }
        guard let showSubtitle, !showSubtitle.isEmpty else { return false }
        return showSubtitle != showTitle
    }

    /// The item the player needs to hear this again, when the crate itself
    /// knows one. Recordings go through SourceResolver instead.
    func broadcastMediaItem() -> MediaItem? {
        // A show kept off the air is not a stream anybody can start again.
        // Playing the station would be playing a different show under the
        // name of the one that was kept, so fail closed and let the crate
        // page find the show itself.
        if isLiveShowSnapshot { return nil }
        // Legacy builds stored the NTS station stream while presenting the
        // on-air show as the crated item. Named as well as caught by the rule
        // above, because those rows predate the subtitle carrying the station.
        if providerID == "nts", isLiveStream,
           showID == "nts.1" || showID == "nts.2" {
            return nil
        }
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
