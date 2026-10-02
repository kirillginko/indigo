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
    /// Not unique: nothing in a synced store can refuse a second row with an
    /// id, so two rows with one id are two copies of one row, and
    /// `UserDataDedupe` folds them. The defaults below are what a row that
    /// arrives without a field holds, chosen so that it neither wins nor
    /// distorts anything: `addedAt` is `distantPast`, which sorts to the bottom
    /// of a newest-first crate and which a merge reads as "no date".
    var id: UUID = UUID()
    var kindRaw: String = CrateItemKind.recording.rawValue
    var addedAt: Date = Date.distantPast

    // MARK: Recording snapshot
    //
    // Set for `.recording`. What a crated recording is, kept on the row itself
    // rather than as a relationship into the catalogue: a row that has to be
    // the same on every device cannot point at an object that exists on one of
    // them. Each device resolves it to its own `Recording` by `matchKey`, or by
    // `unknownCode` for music nobody named -- see `CrateRecordings`.
    //
    // `artworkURLString`, `genreTagsRaw`, `playbackURLString` and
    // `embedProviderRaw` below are the same snapshot's picture, genres and one
    // link to play it, and `providerID`, `showID`, `showTitle` are the
    // broadcast it was heard in ("local" for a file from the library).

    /// Normalised artist + title. Empty for unnamed music, which `unknownCode`
    /// identifies instead.
    var matchKey: String = ""
    var unknownCode: String?
    var title: String?
    var artistName: String?
    var albumTitle: String?
    /// `IdentificationStatus.rawValue`.
    var identificationStatusRaw: String?
    /// "NTS 1": the station, when the broadcast it was heard in had one.
    var stationName: String?
    /// Seconds into that broadcast.
    var broadcastOffsetSeconds: Double?

    /// The relationship every row had before the snapshot. Nothing reads it:
    /// the one-time backfill copies it into the fields above, and the store
    /// split removes it. Named so that any code still reaching for it fails to
    /// compile instead of working on one device and not another.
    @Relationship(originalName: "recording") var legacyRecording: Recording?

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

    init(snapshot: CrateSnapshot) {
        self.id = UUID()
        self.kindRaw = CrateItemKind.recording.rawValue
        self.addedAt = Date()
        snapshot.apply(to: self)
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
    var node: MusicNode? { node(resolving: nil) }

    /// The same, with the local `Recording` this device resolved the row to,
    /// when it has one. A node carries that recording's id so it can be
    /// reopened; the row on its own cannot know it.
    func node(resolving recording: Recording?) -> MusicNode? {
        switch kind {
        case .recording:
            if let recording { return MusicNode.recording(recording, artwork: artworkURL) }
            return recordingNodeFromSnapshot
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

    /// What identifies this row's recording across devices: the match key, or
    /// the code for unnamed music. Empty only for a row with no snapshot.
    var recordingIdentity: String {
        CrateSnapshot.identity(matchKey: matchKey, unknownCode: unknownCode)
    }

    var hasRecordingSnapshot: Bool { !recordingIdentity.isEmpty }

    private var recordingNodeFromSnapshot: MusicNode? {
        guard hasRecordingSnapshot else { return nil }
        return MusicNode.recording(
            identity: RecordingIdentity(matchKey: matchKey, unknownCode: unknownCode),
            title: displayTitle, subtitle: displaySubtitle, artwork: artworkURL)
    }

    // MARK: Display

    var displayTitle: String {
        switch kind {
        case .recording:
            if let title, !title.isEmpty { return title }
            return hasRecordingSnapshot ? "UNKNOWN/\(unknownCode ?? "?????")" : "Unknown"
        case .broadcast: return showTitle ?? "Broadcast"
        case .artist: return showTitle ?? "Artist"
        case .release: return showTitle ?? "Release"
        case .label: return showTitle ?? "Label"
        }
    }

    var displaySubtitle: String? {
        switch kind {
        case .recording: artistName.flatMap { $0.isEmpty ? nil : $0 }
        case .broadcast, .artist, .release, .label: showSubtitle
        }
    }

    /// "NTS 1 / Moxie @ 01:21:43" — where this came from, which is the crate's
    /// whole point.
    var sourceLine: String? {
        switch kind {
        case .recording:
            guard let providerID else { return nil }
            let left = stationName ?? Self.providerName(providerID)
            var line = left
            if let showTitle, !showTitle.isEmpty { line += " / \(showTitle)" }
            if let offset = Self.offsetLabel(broadcastOffsetSeconds) { line += " @ \(offset)" }
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

    /// Filtered on read, like the Discogs models: a track resolved through a
    /// Discogs search can have kept a `spacer.gif`, which loads fine and draws
    /// a blank tile instead of the placeholder.
    var artworkURL: URL? {
        guard let usable = DiscogsClient.usableImage(artworkURLString) else { return nil }
        return URL(string: usable)
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

    private var recordingStatus: IdentificationStatus? {
        identificationStatusRaw.flatMap(IdentificationStatus.init(rawValue:))
    }

    /// The names `MediaAppearance` gives the providers a track was heard
    /// through, so a row reads the same as it did when it asked the appearance.
    private static func providerName(_ providerID: String) -> String {
        switch providerID {
        case "nts": "NTS"
        case "kiosk": "Kiosk Radio"
        case "local": "Local Library"
        default: providerID.capitalized
        }
    }

    /// "01:14:32" into the broadcast.
    private static func offsetLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Status chip: MATCH / PROBABLE / UNKNOWN, or the kind of thing it is.
    var statusLabel: String? {
        switch kind {
        case .recording: recordingStatus?.label
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
            switch recordingStatus {
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

    /// Whether this row is a live snapshot still waiting to be pointed at the
    /// recording it kept.
    ///
    /// A show kept while it was on air stores the station rather than the
    /// broadcast, because at that moment the broadcast has no handle. Once the
    /// station publishes one the row can be repaired — see
    /// `CrateService.migrateLotLiveBroadcast` — and this is what the crate page
    /// looks for when deciding which rows to go and ask about.
    ///
    /// Its own property because the repair used to ride along with genre
    /// hydration, which only visits rows with no genres. A row that was kept
    /// with genres was therefore never repaired at all, and the one thing that
    /// is actually wrong with it — where it points — is unrelated to whether
    /// anybody filled its genres in.
    var needsLiveSnapshotRepair: Bool {
        guard kind == .broadcast, isLiveStream, let showID, let providerID else { return false }
        switch providerID {
        case LotProvider.providerID: return !showID.hasPrefix("lot.episode.")
        case NTSProvider.providerID: return !showID.hasPrefix("nts.episode.")
        default: return false
        }
    }

    /// The item the player needs to hear this again, when the crate itself
    /// knows one. Recordings go through SourceResolver instead.
    /// Legacy builds stored the NTS station stream while presenting the
    /// on-air show as the crated item. Named as well as caught by
    /// `isLiveShowSnapshot`, because those rows predate the subtitle carrying
    /// the station.
    var isLegacyNTSLiveRow: Bool {
        providerID == "nts" && isLiveStream && (showID == "nts.1" || showID == "nts.2")
    }

    func broadcastMediaItem() -> MediaItem? {
        // A show kept off the air is not a stream anybody can start again.
        // Playing the station would be playing a different show under the
        // name of the one that was kept, so fail closed and let the crate
        // page find the show itself.
        if isLiveShowSnapshot { return nil }
        if isLegacyNTSLiveRow { return nil }
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
