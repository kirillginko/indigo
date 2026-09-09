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

nonisolated enum MusicNodeKind: String, Hashable, Sendable, Codable, CaseIterable {
    case artist
    case release
    case label
    case recording
    /// Music heard and kept but never named. A first-class node, not a
    /// degenerate recording: white labels and dubplates are the point.
    case unknownRecording
    /// A show or episode on a station.
    case broadcast
    /// The station itself, as distinct from anything it broadcast. Kept apart
    /// from `broadcast` because "which stations do they favour" and "which
    /// shows do they favour" are different questions, and folding the first
    /// into the second answers neither.
    case station
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
        case .station: "STATION"
        case .selector: "SELECTOR"
        case .catalogNumber: "CATALOG"
        case .style: "STYLE"
        case .scene: "SCENE"
        }
    }
}

nonisolated struct MusicNode: Identifiable, Hashable, Sendable, Codable {
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

    /// A label, keyed on its name.
    ///
    /// Deliberately still the name, even though `discogsID` can now say which
    /// of two labels sharing one this is. Identity here is what decides
    /// whether two rows are the same row, and keying on an id would split one
    /// label into two the moment a record named it and another did not —
    /// stored edges, crate entries and the graph all disagreeing about a
    /// label nobody renamed. The id is carried for the reason every other
    /// identifier on a node is: so the row opens the right page.
    static func label(_ name: String, mbid: String? = nil, discogsID: Int? = nil) -> MusicNode {
        MusicNode(kind: .label, key: RecordingKey.normalize(name), title: name,
                  mbid: mbid, discogsID: discogsID)
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

    /// A broadcast, keyed on one spelling of its handle.
    ///
    /// The crate and the appearance log disagree about whether a show id
    /// carries its provider's prefix, so the handle is reduced to the bare
    /// form both of them mean. Without that the same show is two nodes, and
    /// one of them is offered back to somebody who already kept the other.
    static func broadcast(providerID: String, showID: String, title: String?) -> MusicNode {
        let handle = BroadcastSource.canonicalShowID(showID, providerID: providerID)
        return MusicNode(kind: .broadcast, key: "\(providerID)|\(handle)",
                         title: title ?? BroadcastSource.label(for: providerID),
                         subtitle: BroadcastSource.label(for: providerID),
                         providerID: providerID, handle: handle)
    }

    /// A station, keyed on the provider that runs it.
    ///
    /// Deliberately not keyed on the channel: IDA runs two and NTS runs two,
    /// and a listener who says they listen to NTS means the station rather
    /// than channel 2. The channel is kept in `handle` so a node can still
    /// open the one they were actually on.
    static func station(providerID: String, stationID: String? = nil) -> MusicNode {
        MusicNode(kind: .station, key: providerID,
                  title: BroadcastSource.label(for: providerID),
                  providerID: providerID, handle: stationID)
    }

    /// Catalogue numbers are compared with their punctuation and spacing
    /// removed, because the same pressing is written "IT 001", "IT-001" and
    /// "IT001" by three different people describing one record.
    static func catalogNumber(_ number: String) -> MusicNode {
        MusicNode(kind: .catalogNumber, key: CatalogNumber.normalize(number),
                  title: number.uppercased())
    }

    /// A place and a sound — the two halves of a scene's address. See
    /// `MusicScene.id`, which mints the same key.
    ///
    /// A sound is optional because a place can be a scene without one, and
    /// because an older link that names only a city still has to land
    /// somewhere: it opens the strongest scene there.
    static func scene(city: String, sound: String? = nil) -> MusicNode {
        MusicNode(
            kind: .scene,
            key: "\(RecordingKey.normalize(city))|\(RecordingKey.normalize(sound))",
            title: city.uppercased(),
            subtitle: sound?.uppercased(),
            providerID: city,
            handle: sound
        )
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
            return .digDiscogsLabel(name: title, discogsID: discogsID)
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
        case .scene:
            // A scene has had a page for a while; this was the one route to
            // it that did not know. DEEP and the graph both hand back scene
            // nodes, and every one of them was a row that would not open —
            // which in a thing built on "no dead ends" is the worst kind of
            // gap, because it looks like a link.
            return .digScene(city: providerID ?? title, sound: handle)
        case .selector, .style, .station:
            // A station is a section of the app rather than a page inside
            // one, so it is reached through `route` instead. A style is a
            // lens, and a selector has nowhere to go yet.
            return nil
        }
    }

    /// The section of the app this node *is*, for the kinds that are one.
    ///
    /// Separate from `destination` because the sidebar and the detail stack
    /// are different axes: opening NTS means selecting a station, not pushing
    /// a page on top of wherever the listener happened to be.
    var route: Route? {
        guard kind == .station, let providerID else { return nil }
        return BroadcastSource.route(providerID: providerID, stationID: handle)
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

    /// "ITLP09" → ("ITLP", 9, ""), "SBR276CD" → ("SBR", 276, "CD").
    ///
    /// The prefix is a label's mark and the number is its position in the run,
    /// which is what makes neighbouring catalogue numbers worth offering. The
    /// suffix is the format the pressing was issued in, and it has to be
    /// carried rather than refused: this used to require that everything after
    /// the prefix be digits, so any number written with its format on the end
    /// split to nil — and a catalogue node that cannot be split has no
    /// neighbours, which is a page offered from every release that opens on
    /// nothing at all.
    ///
    /// It stays part of the shelf's identity. SBR276CD and SBR277CD are a run;
    /// SBR276CD and SBR277LP are the same records in two formats, and reading
    /// along a shelf that alternates between them is not reading along a shelf.
    static func split(_ value: String) -> (prefix: String, number: Int, suffix: String)? {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }
        let prefix = normalized.prefix { !$0.isNumber }
        let rest = normalized.dropFirst(prefix.count)
        let digits = rest.prefix { $0.isNumber }
        guard !prefix.isEmpty, !digits.isEmpty, let number = Int(digits) else { return nil }
        return (prefix.uppercased(), number, String(rest.dropFirst(digits.count)).uppercased())
    }
}
