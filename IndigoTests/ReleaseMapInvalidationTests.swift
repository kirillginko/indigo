//
//  ReleaseMapInvalidationTests.swift
//  IndigoTests
//
//  The map of releases by credited name is handed from one graph generation
//  to the next while the release table is as it was read: the same number of
//  records, none written since. Every way a record's credits change in this
//  app moves one of the two — these pin that down, the cases where the count
//  stays the same above all.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class ReleaseMapInvalidationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var generation: GraphStore!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
        for (id, artist) in [(1, "Hype Williams (2)"), (2, "Dean Blunt"), (3, "Inga Copeland")] {
            try store(id, artist)
        }
        // Written long before anything reads them.
        for record in try context.fetch(FetchDescriptor<DiscogsReleaseRecord>()) {
            record.fetchedAt = Date(timeIntervalSinceNow: -3_600)
        }
        try context.save()
        generation = GraphStore(context: context)
        XCTAssertEqual(generation.releaseIDs(creditedTo: "dean blunt"), [2], "Read once")
    }

    override func tearDown() {
        generation = nil
        context = nil
        container = nil
    }

    private func store(_ id: Int, _ artist: String, source: String? = nil) throws {
        let json = #"{"id":\#(id),"title":"Record \#(id)","artists":[{"id":\#(id * 10),"name":"\#(artist)"}]}"#
        DiscogsEnricher(context: context, client: DiscogsClient())
            .store(try JSONDecoder().decode(DiscogsReleaseDetail.self, from: Data(json.utf8)), id: id, source: source)
        try context.save()
    }

    /// The next generation, offered this one's map.
    private func next() -> GraphStore {
        generation = GraphStore(context: context, inheriting: generation)
        return generation
    }

    private func count() throws -> Int { try context.fetchCount(FetchDescriptor<DiscogsReleaseRecord>()) }

    func testARecordRewrittenInPlaceIsSeen() throws {
        let before = try count()
        try store(2, "Joanne Robertson")
        XCTAssertEqual(try count(), before, "Same count")
        let graph = next()
        XCTAssertEqual(graph.releaseIDs(creditedTo: "joanne robertson"), [2])
        XCTAssertEqual(graph.releaseIDs(creditedTo: "dean blunt"), [], "And the old credit is gone")
    }

    func testARecordReplacedByAnotherIsSeen() throws {
        let before = try count()
        for record in try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.discogsID == 3 })) {
            context.delete(record)
        }
        try store(4, "Panda Bear")
        XCTAssertEqual(try count(), before, "Same count")
        let graph = next()
        XCTAssertEqual(graph.releaseIDs(creditedTo: "panda bear"), [4])
        XCTAssertEqual(graph.releaseIDs(creditedTo: "inga copeland"), [])
    }

    func testADeletedRecordIsSeen() throws {
        for record in try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.discogsID == 2 })) {
            context.delete(record)
        }
        try context.save()
        XCTAssertEqual(next().releaseIDs(creditedTo: "dean blunt"), [])
    }

    func testANewRecordIsSeen() throws {
        try store(5, "Dean Blunt")
        XCTAssertEqual(Set(next().releaseIDs(creditedTo: "dean blunt")), [2, 5])
    }

    /// From Indigo's shared cache rather than Discogs: the same write, stamped
    /// when it was written here.
    func testARecordImportedFromTheBackendIsSeen() throws {
        try store(3, "Copeland", source: "backend")
        XCTAssertEqual(next().releaseIDs(creditedTo: "copeland"), [3])
    }

    func testNothingWrittenIsHandedOn() throws {
        // A write elsewhere starts a generation; the release table is as read.
        context.insert(ListeningEvent(node: .artist("Dean Blunt"), action: .played, at: Date(),
                                      seconds: 60, completion: 1, tags: [], source: nil))
        try context.save()
        XCTAssertEqual(next().releaseIDs(creditedTo: "dean blunt"), [2])
    }

    /// The rule's one assumption, stated: a record's credits change only with
    /// a new `fetchedAt`. Every writer in the app stamps it
    /// (`DiscogsEnricher.writeRelease`, and a new record's initialiser); one
    /// that did not would not be seen until the table changed otherwise. This
    /// is also what shows the map really is handed on rather than read again.
    func testAWriteThatDoesNotStampIsNotSeen() throws {
        for record in try context.fetch(FetchDescriptor<DiscogsReleaseRecord>(predicate: #Predicate { $0.discogsID == 1 })) {
            record.artistNames = ["Somebody Else"]
        }
        try context.save()
        XCTAssertEqual(next().releaseIDs(creditedTo: "somebody else"), [], "Handed on: the unstamped write is not read")
        XCTAssertEqual(GraphStore(context: context).releaseIDs(creditedTo: "somebody else"), [1], "A fresh read sees it")
    }
}
