//
//  LegacyStoreFixture.swift
//  IndigoTests
//
//  A store shaped the way the listener's is: version 2, every model in one file,
//  the crate pointing at recordings, events and visits carrying local recording
//  ids, and the repeated "Unreleased" placeholders that share a match key.
//
//  Written with the frozen types, so it is the shape on disk and not a
//  paraphrase of it.
//

import Foundation
import SwiftData
@testable import Indigo

enum LegacyStoreFixture {
    /// What the fixture holds, for tests to compare against.
    struct Contents {
        // Fixed, so that two stores made from this are the same store.
        var plainRecordingID = LegacyStoreFixture.id("plain")
        var aggregateID = LegacyStoreFixture.id("aggregate")
        var twinIDs = [LegacyStoreFixture.id("twin0"), LegacyStoreFixture.id("twin1"), LegacyStoreFixture.id("twin2")]
        var otherTwinIDs = [LegacyStoreFixture.id("other0"), LegacyStoreFixture.id("other1")]
        var unnamedID = LegacyStoreFixture.id("unnamed")
        var crateIDs: [String: UUID] = [:]
        var eventIDs: [String: UUID] = [:]
        let sharedKey = RecordingKey.match(artist: "Papo2oo4", title: "Unreleased")
        let otherKey = RecordingKey.match(artist: "Starker", title: "Unreleased")
        let plainKey = RecordingKey.match(artist: "Skee Mask", title: "Rev8617")
    }

    static func id(_ name: String) -> UUID { UserDataTransform.stableID("fixture|\(name)") }
    static let moment = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    static func make(in layout: StoreLayout) throws -> Contents {
        try FileManager.default.createDirectory(at: layout.directory, withIntermediateDirectories: true)
        var c = Contents()
        let schema = Schema(versionedSchema: IndigoSchemaV2.self)
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: layout.legacy, cloudKitDatabase: .none))
            let ctx = ModelContext(container)

            func recording(_ id: UUID, _ title: String?, _ artist: String?, status: String = "identified", code: String? = nil) -> IndigoLegacy.Recording {
                let r = IndigoLegacy.Recording(
                    id: id, title: title, artistName: artist,
                    matchKey: RecordingKey.match(artist: artist, title: title))
                r.identificationStatusRaw = status
                r.unknownCode = code
                ctx.insert(r)
                return r
            }
            func appearance(_ r: IndigoLegacy.Recording, offset: Double, show: String = "100-elements/x") {
                let a = IndigoLegacy.MediaAppearance(id: id("app|\(r.id.uuidString)|\(offset)"), providerID: "nts")
                a.stationName = "NTS"; a.showTitle = "100 Elements"; a.showID = show
                a.offsetSeconds = offset
                a.heardAt = Date(timeIntervalSince1970: 1_000_000 + offset)
                ctx.insert(a); a.recording = r
            }

            // Recordings: a plain one with a link, an aggregate with four
            // appearances beside three placeholders of its key, a second group of
            // two, and one nobody named.
            let plain = recording(c.plainRecordingID, "Rev8617", "Skee Mask")
            let link = IndigoLegacy.RecordingSource(id: id("link"), identifier: "https://www.youtube.com/watch?v=abc")
            link.providerID = "youtube"; ctx.insert(link); link.recording = plain
            let aggregate = recording(c.aggregateID, "Unreleased", "Papo2oo4")
            for offset in [8.0, 278, 904, 2542] { appearance(aggregate, offset: offset) }
            var twins: [IndigoLegacy.Recording] = []
            for (id, offset) in zip(c.twinIDs, [8.0, 278, 904]) {
                let t = recording(id, "Unreleased", "Papo2oo4", status: "probable")
                appearance(t, offset: offset); twins.append(t)
            }
            var others: [IndigoLegacy.Recording] = []
            for (id, offset) in zip(c.otherTwinIDs, [100.0, 400]) {
                let t = recording(id, "Unreleased", "Starker", status: "probable")
                appearance(t, offset: offset, show: "other/y"); others.append(t)
            }
            _ = recording(c.unnamedID, nil, nil, status: "unknown", code: "8F42A")

            // The crate.
            func crate(_ name: String, kind: String, added: TimeInterval, recording r: IndigoLegacy.Recording? = nil) -> IndigoSchemaV4.CrateItem {
                let id = Self.id("crate|\(name)"); c.crateIDs[name] = id
                let item = IndigoSchemaV4.CrateItem(id: id, kindRaw: kind, addedAt: Date(timeIntervalSince1970: added))
                item.legacyRecording = r
                ctx.insert(item)
                return item
            }
            let a = crate("plain", kind: "recording", added: 100, recording: plain); a.artworkURLString = "https://art/plain"
            _ = crate("twin", kind: "recording", added: 200, recording: twins[1])
            let b = crate("show", kind: "broadcast", added: 300); b.providerID = "nts"; b.showID = "nts.episode.a/b"; b.showTitle = "A"
            let d = crate("artist", kind: "artist", added: 400); d.providerID = "dig.artist.mbid"; d.showID = "mbid-1"; d.showTitle = "Skee Mask"
            _ = crate("dangling", kind: "recording", added: 500)

            // Events: with a recording id, without one, and with one that points
            // at nothing.
            func event(_ name: String, kind: String, key: String, rid: UUID?, seconds: Double) {
                let e = IndigoSchemaV2.ListeningEvent(nodeKind: kind, nodeKey: key, title: key, recordingID: rid)
                e.id = Self.id("event|\(name)"); e.at = moment
                e.seconds = seconds; c.eventIDs[name] = e.id; ctx.insert(e)
            }
            event("plain", kind: "recording", key: c.plainKey, rid: c.plainRecordingID, seconds: 90)
            event("twin", kind: "recording", key: c.sharedKey, rid: c.twinIDs[0], seconds: 60)
            event("artist", kind: "artist", key: "skee mask", rid: nil, seconds: 30)
            event("gone", kind: "recording", key: "gone gone", rid: UUID(), seconds: 15)
            event("otherA", kind: "recording", key: c.otherKey, rid: c.otherTwinIDs[0], seconds: 10)
            event("otherB", kind: "recording", key: c.otherKey, rid: c.otherTwinIDs[1], seconds: 12)

            // Visits.
            func visit(_ kind: String, _ key: String, _ visits: Int, rid: UUID?) {
                let v = IndigoSchemaV2.DigVisit(kind: kind, key: key, title: key, visits: visits, recordingID: rid)
                v.firstVisitedAt = moment; v.lastVisitedAt = moment
                ctx.insert(v)
            }
            visit("recording", c.sharedKey, 3, rid: c.twinIDs[0])
            visit("recording", c.plainKey, 2, rid: c.plainRecordingID)
            visit("artist", "skee mask", 7, rid: nil)

            // Steps.
            func step(_ from: String, _ to: String, _ count: Int) {
                let s = IndigoSchemaV3.DigStep(from: from, to: to, count: count)
                s.lastAt = moment
                ctx.insert(s)
            }
            step("artist:skee mask", "recording:\(c.sharedKey)", 2)          // the node meant one thing: follows it
            step("artist:skee mask", "recording:\(c.otherKey)", 4)           // meant two: left alone
            step("artist:skee mask", "artist:actress", 5)
            step("recording:\(c.plainKey)", "artist:actress", 1)

            // What stays on the device.
            for n in ["skee mask", "actress"] { ctx.insert(DiscogsArtist(nameKey: n, discogsID: n.count, name: n)) }
            for i in 0..<3 { ctx.insert(IndigoSchemaV2.StoredEdge(id: "edge\(i)", toKey: "k\(i)", toRecordingID: nil)) }
            try ctx.save()
        }
        return c
    }

    /// A digest of a store's three files, to prove nothing touched them.
    static func fingerprint(_ layout: StoreLayout, _ base: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for file in layout.files(of: base) { result[file.lastPathComponent] = try? Data(contentsOf: file) }
        return result
    }
}
