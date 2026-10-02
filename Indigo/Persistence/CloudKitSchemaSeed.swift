//
//  CloudKitSchemaSeed.swift
//  Indigo
//
//  Development builds only. Not compiled into a release build at all.
//
//  CloudKit makes a field when a record that has a value for it is first
//  written, so a development schema built from the listener's real rows would
//  lack every optional field none of them happens to fill -- and a production
//  schema deployed from that would lack it for good. SwiftData has no call to
//  create the whole schema, so this builds rows that fill every field of the
//  four synced models, with the odd cases the real data has, for a throwaway
//  run against CloudKit's *development* environment.
//
//  What this file is: the rows, the guard that refuses to use them anywhere but
//  a throwaway store, and the comparison that proves a string came back from
//  CloudKit scalar for scalar. What it is not: the run itself. That needs the
//  iCloud entitlement and is step 10.
//
//  The guard is the point. A seed written into the listener's own `UserData`
//  would sync fake rows to their devices, so the run is refused unless every one
//  of these holds: it is a debug build; it was asked for by name on the command
//  line; and its store is not any file of the layout.
//

#if DEBUG

import Foundation
import SwiftData

nonisolated struct CloudKitSchemaSeed: Sendable {
    var crate: [CrateValue]
    var events: [EventValue]
    var visits: [VisitValue]
    var steps: [StepValue]

    /// Every seed row carries this, so it can be told apart and deleted.
    static let marker = "INDIGO-SCHEMA-SEED"

    static func id(_ name: String) -> UUID { UserDataTransform.stableID("indigo.cloudkit.seed|\(name)") }

    /// The match key of a real recording: artist, the unit separator, title.
    /// It is in the listener's data, so it is in the seed.
    static var separatedKey: String { RecordingKey.match(artist: "\(marker) Artist", title: "\(marker) Title") }

    static func make() -> CloudKitSchemaSeed {
        let at = Date(timeIntervalSince1970: 1_700_000_000)

        // Every optional field filled, on one row, so each exists in the schema.
        var full = CrateValue(id: id("crate-full"), kindRaw: CrateItemKind.recording.rawValue, addedAt: at)
        full.matchKey = separatedKey
        full.unknownCode = "5EED1"
        full.title = "\(marker) Title"; full.artistName = "\(marker) Artist"; full.albumTitle = "\(marker) Album"
        full.identificationStatusRaw = IdentificationStatus.identified.rawValue
        full.stationName = "NTS 1"; full.broadcastOffsetSeconds = 4903
        full.providerID = "nts"; full.showID = "nts.episode.seed/seed"
        full.showTitle = "\(marker) Show"; full.showSubtitle = "\(marker) Subtitle"
        full.artworkURLString = "https://example.invalid/seed.jpg"
        full.playbackURLString = "https://www.youtube.com/watch?v=seed"
        full.embedProviderRaw = "youtube"; full.isLiveStream = true
        full.genreTagsRaw = "ambient\ndub techno"

        // The kinds a real crate holds.
        var placeholder = CrateValue(id: id("crate-placeholder"), kindRaw: CrateItemKind.recording.rawValue, addedAt: at)
        placeholder.matchKey = RecordingKey.match(artist: "\(marker) Placeholder", title: "Unreleased")
        placeholder.unknownCode = "5EED2"; placeholder.title = "Unreleased"; placeholder.artistName = "\(marker) Placeholder"
        placeholder.identificationStatusRaw = IdentificationStatus.probable.rawValue
        var show = CrateValue(id: id("crate-show"), kindRaw: CrateItemKind.broadcast.rawValue, addedAt: at,
                              providerID: "nts", showID: "nts.episode.seed/show", showTitle: "\(marker) Broadcast")
        show.playbackURLString = "https://example.invalid/seed.mp3"; show.embedProviderRaw = "mixcloud"
        let artist = CrateValue(id: id("crate-artist"), kindRaw: CrateItemKind.artist.rawValue, addedAt: at,
                                providerID: "dig.artist.mbid", showID: "seed-mbid", showTitle: "\(marker) Dig Artist")

        let node = MusicNode.recording(
            identity: RecordingIdentity(matchKey: separatedKey, unknownCode: "5EED1"),
            title: "\(marker) Title", subtitle: "\(marker) Artist")
        let event = EventValue(
            id: id("event"), at: at, actionRaw: ListeningAction.played.rawValue, nodeID: node.id,
            nodeKindRaw: node.kind.rawValue, nodeKey: node.key, title: "\(marker) Title", subtitle: "\(marker) Artist",
            mbid: "00000000-0000-0000-0000-00000000seed", discogsID: 123_456, providerID: "nts", handle: "seed-handle",
            sourceProviderID: "nts", sourceShowID: "seed/show", sourceShowTitle: "\(marker) Show",
            seconds: 90, completion: 0.5, tags: ["ambient", "dub techno"])
        let visit = VisitValue(
            id: id("visit"), nodeID: node.id, kindRaw: node.kind.rawValue, title: "\(marker) Title",
            subtitle: "\(marker) Artist", visits: 3, firstVisitedAt: at, lastVisitedAt: at.addingTimeInterval(60),
            mbid: "00000000-0000-0000-0000-00000000seed", discogsID: 123_456, providerID: "nts", handle: "seed-handle")
        let from = MusicNode.artist("\(marker) Artist").id
        let step = StepValue(
            id: id("step"), identity: DigStep.canonicalIdentity(from: from, to: node.id),
            fromNodeID: from, toNodeID: node.id, count: 2, lastAt: at)

        return CloudKitSchemaSeed(crate: [full, placeholder, show, artist], events: [event], visits: [visit], steps: [step])
    }
}

// MARK: - The guard

nonisolated enum CloudKitSeedGuard {
    static let argument = "-INDIGO_SEED_CLOUDKIT_DEV"

    /// Whether a seed run may write `store`. Every reason it may not is a
    /// separate line, so a refusal says which.
    static func refusals(arguments: [String], store: URL, layout: StoreLayout) -> [String] {
        var reasons: [String] = []
        if !arguments.contains(argument) { reasons.append("not asked for by name") }
        if Persistence.isRunningTests { reasons.append("this is a test process") }
        let target = store.standardizedFileURL.path
        for file in [layout.userData, layout.local, layout.legacy, layout.archive].flatMap(layout.files(of:)) {
            if file.standardizedFileURL.path == target { reasons.append("the store is \(file.lastPathComponent), which is the listener's") }
        }
        if !store.lastPathComponent.hasPrefix("CloudKitSchemaSeed") { reasons.append("the store is not named for the seed") }
        return reasons
    }
}

// MARK: - Did it come back whole

nonisolated enum UnicodeFidelity {
    /// Where two strings first differ, scalar for scalar, or nil if they do not.
    /// Compared by Unicode scalar and not by character: String equality treats
    /// canonically equivalent sequences as equal, which is exactly the
    /// difference a round trip through a service could introduce.
    static func firstDifference(sent: String, received: String) -> (index: Int, sent: UInt32?, received: UInt32?)? {
        let a = Array(sent.unicodeScalars), b = Array(received.unicodeScalars)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index].value : nil
            let y = index < b.count ? b[index].value : nil
            if x != y { return (index, x, y) }
        }
        return nil
    }

    /// Every string field of every seed row, compared with what came back.
    static func differences(sent: CloudKitSchemaSeed, received: CloudKitSchemaSeed) -> [String] {
        var found: [String] = []
        func check(_ name: String, _ a: String?, _ b: String?) {
            guard let a else { return }
            if let diff = firstDifference(sent: a, received: b ?? "") {
                found.append("\(name) differs at scalar \(diff.index): \(diff.sent.map { String($0, radix: 16) } ?? "-") vs \(diff.received.map { String($0, radix: 16) } ?? "-")")
            }
        }
        let receivedCrate = Dictionary(received.crate.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in sent.crate {
            let got = receivedCrate[row.id]
            check("CrateItem \(row.id).matchKey", row.matchKey, got?.matchKey)
            check("CrateItem \(row.id).title", row.title, got?.title)
            check("CrateItem \(row.id).showID", row.showID, got?.showID)
            check("CrateItem \(row.id).genreTagsRaw", row.genreTagsRaw, got?.genreTagsRaw)
        }
        let receivedEvents = Dictionary(received.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in sent.events {
            let got = receivedEvents[row.id]
            check("ListeningEvent \(row.id).nodeID", row.nodeID, got?.nodeID)
            check("ListeningEvent \(row.id).nodeKey", row.nodeKey, got?.nodeKey)
            check("ListeningEvent \(row.id).tags", row.tags.joined(separator: "\n"), got?.tags.joined(separator: "\n"))
        }
        let receivedVisits = Dictionary(received.visits.map { ($0.nodeID, $0) }, uniquingKeysWith: { a, _ in a })
        for row in sent.visits { check("DigVisit \(row.nodeID)", row.nodeID, receivedVisits[row.nodeID]?.nodeID) }
        let receivedSteps = Dictionary(received.steps.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        for row in sent.steps { check("DigStep \(row.identity)", row.identity, receivedSteps[row.identity]?.identity) }
        return found
    }
}

#endif
