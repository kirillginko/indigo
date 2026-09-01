//
//  MusicNode.swift
//  Indigo
//
//  One thing you can dig into. Until now DIG passed artist names around as
//  bare strings, which is why it could only ever relate artists to artists —
//  a label, a broadcast or a white label had nowhere to sit. A node is the
//  smallest thing that fixes that: an identity, a way to draw it, and a way
//  to open it.
//
//  Deliberately a value type and not a `@Model`. The graph is rebuilt from
//  the caches on demand; persisting a second copy of what MusicBrainz,
//  Discogs and the appearance log already say would only give the app two
//  versions of the truth to disagree about. What *does* get persisted is the
//  handful of edges nobody else knows (see `StoredEdge`).
//

import Foundation

nonisolated enum MusicNodeKind: String, Hashable, Sendable, CaseIterable {
    case artist
    case release
    case label
    case recording
    /// Music heard and kept but never named. A first-class node, not a
    /// degenerate recording: white labels and dubplates are the point.
    case unknownRecording
    /// A show or episode on a station.
    case broadcast
    /// Whoever played it — a DJ, a resident, a show host.
    case selector
    /// A catalogue number treated as somewhere you can go: WHT003, ITLP09.
    case catalogNumber
    case style
    /// A city-and-era cluster: "Berlin / 2010–2016".
    case scene

    /// How the kind is written in the interface — technical, uppercase,
    /// the way a shelf label is.
    var label: String {
        switch self {
        case .artist: "ARTIST"
        case .release: "RELEASE"
        case .label: "LABEL"
        case .recording: "TRACK"
        case .unknownRecording: "UNKNOWN"
        case .broadcast: "SHOW"
        case .selector: "SELECTOR"
        case .catalogNumber: "CATALOG"
        case .style: "STYLE"
        case .scene: "SCENE"
        }
    }
}

nonisolated struct MusicNode: Identifiable, Hashable, Sendable {
    let kind: MusicNodeKind
    /// Normalised identity within the kind. Two nodes with the same kind and
    /// key are the same thing, however differently they were spelled.
    let key: String
    /// The spelling to show, which is whichever one the listener's own data
    /// used rather than whichever catalogue answered last.
    let title: String
    var subtitle: String?

    // Whatever identifiers happen to be known. None of them is the identity;
    // they are what lets a node open the right page and be enriched further.
    var mbid: String?
    var discogsID: Int?
    var recordingID: UUID?
    var providerID: String?
    var handle: String?
    /// The release sleeve, when the catalogue has been asked. A node in a
    /// RADIO list is a record, and a list of records with no records in it is
    /// a list of strings.
    var artworkURL: URL?

    var id: String { "\(kind.rawValue):\(key)" }

    // MARK: Constructors

    static func artist(_ name: String, mbid: String? = nil, discogsID: Int? = nil) -> MusicNode {
        MusicNode(kind: .artist, key: RecordingKey.normalizeArtist(name), title: name,
                  mbid: mbid, discogsID: discogsID)
    }

    /// The same, for a caller that already folded the name.
    ///
    /// Folding a credit runs nine case-insensitive searches for a
    /// collaboration marker before it normalises anything. The peer walk
    /// builds hundreds of these a page from names it took the key from a
    /// moment earlier, so asking again is the same answer at full price.
    static func artist(_ name: String, key: String, mbid: String? = nil) -> MusicNode {
        MusicNode(kind: .artist, key: key, title: name, mbid: mbid)
    }

    static func label(_ name: String, mbid: String? = nil) -> MusicNode {
        MusicNode(kind: .label, key: RecordingKey.normalize(name), title: name, mbid: mbid)
    }

    static func release(_ title: String, discogsID: Int? = nil, mbid: String? = nil, year: String? = nil) -> MusicNode {
        // A Discogs ID is a real identity and a title is a guess at one, so a
        // resolved release keys on the ID: two different pressings called
        // "Untitled" must not collapse into one node.
        let key = discogsID.map { "discogs \($0)" } ?? RecordingKey.normalizeTitle(title)
        return MusicNode(kind: .release, key: key, title: title, subtitle: year,
                         mbid: mbid, discogsID: discogsID)
    }

    static func style(_ name: String) -> MusicNode {
        MusicNode(kind: .style, key: RecordingKey.normalize(name), title: name)
    }

    static func selector(_ name: String, providerID: String? = nil, handle: String? = nil) -> MusicNode {
        MusicNode(kind: .selector, key: RecordingKey.normalizeArtist(name), title: name,
                  subtitle: providerID.map(BroadcastSource.label(for:)),
                  providerID: providerID, handle: handle)
    }

    static func broadcast(providerID: String, showID: String, title: String?) -> MusicNode {
        MusicNode(kind: .broadcast, key: "\(providerID)|\(showID)",
                  title: title ?? BroadcastSource.label(for: providerID),
                  subtitle: BroadcastSource.label(for: providerID),
                  providerID: providerID, handle: showID)
    }

    /// Catalogue numbers are compared with their punctuation and spacing
    /// removed, because the same pressing is written "IT 001", "IT-001" and
    /// "IT001" by three different people describing one record.
    static func catalogNumber(_ number: String) -> MusicNode {
        MusicNode(kind: .catalogNumber, key: CatalogNumber.normalize(number),
                  title: number.uppercased())
    }

    static func scene(city: String, era: ClosedRange<Int>) -> MusicNode {
        MusicNode(kind: .scene, key: "\(RecordingKey.normalize(city))|\(era.lowerBound)",
                  title: city.uppercased(), subtitle: "\(era.lowerBound)–\(era.upperBound)")
    }

    /// A recording node, which is an unknown node when nobody could name it.
    /// The two are one constructor on purpose: identifying a white label
    /// later must move the same object between kinds rather than mint a
    /// second one beside it.
    ///
    /// `artwork` is passed in rather than looked up because a node is a value
    /// and has no store to ask. Whoever builds the node has the metadata row
    /// in hand already.
    static func recording(_ recording: Recording, artwork: URL? = nil) -> MusicNode {
        if recording.isIdentified, !recording.matchKey.isEmpty {
            return MusicNode(
                kind: .recording, key: recording.matchKey,
                title: recording.displayTitle, subtitle: recording.displayArtist,
                mbid: recording.musicBrainzRecordingID, recordingID: recording.id,
                artworkURL: artwork
            )
        }
        return MusicNode(
            kind: .unknownRecording,
            key: recording.unknownCode ?? recording.id.uuidString,
            title: recording.displayTitle,
            subtitle: recording.displayArtist,
            recordingID: recording.id,
            handle: recording.unknownCode,
            artworkURL: artwork
        )
    }

    // MARK: Navigation

    /// Where opening this node lands, when there is anywhere to land. Nil is
    /// a real answer: a style or a scene is a lens, not a page, and a
    /// catalogue number is only navigable once something claims it.
    var destination: DetailPage? {
        switch kind {
        case .artist:
            return .digArtist(mbid: mbid, name: title)
        case .label:
            if let mbid, !mbid.isEmpty { return .digLabel(mbid: mbid, name: title) }
            return .digDiscogsLabel(name: title)
        case .release:
            return discogsID.map { .digRelease(id: $0, title: title) }
        case .broadcast:
            guard let providerID, let handle else { return nil }
            return BroadcastSource.destination(showID: handle, providerID: providerID)
        case .recording, .unknownRecording:
            // Including the unnamed. A white label having its own page is the
            // point: it is a destination, not a gap.
            return recordingID.map { .digRecording(id: $0, title: title) }
        case .catalogNumber:
            return .digCatalog(number: title)
        case .selector, .style, .scene:
            return nil
        }
    }

    /// True when the node stands for music nobody has named. DEEP treats
    /// these as destinations rather than as gaps.
    var isUnidentified: Bool { kind == .unknownRecording }
}

/// Catalogue numbers, normalised for comparison and split into their parts so
/// a prefix can act as a route back to the label that issued it.
nonisolated enum CatalogNumber {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
    }

    /// "ITLP09" → ("ITLP", 9). The prefix is a label's mark and the number is
    /// its position in the run, which is what makes neighbouring catalogue
    /// numbers worth offering.
    static func split(_ value: String) -> (prefix: String, number: Int)? {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }
        let digits = normalized.drop { !$0.isNumber }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
        let prefix = String(normalized.prefix(normalized.count - digits.count))
        guard !prefix.isEmpty else { return nil }
        return (prefix.uppercased(), number)
    }
}
