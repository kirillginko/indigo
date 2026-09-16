//
//  ReleaseCacheStorageTests.swift
//  IndigoTests
//
//  Discogs release payloads moved out of the database into a Storage bucket
//  (0036), leaving a row that says where. Searches, shelves and NTS stayed
//  inline, so the app's cache readers now meet both shapes — and a release
//  whose object cannot be loaded has to read as a miss, not an error, or a
//  CDN blink becomes a broken page instead of a slower one.
//

import XCTest
import Supabase
@testable import Indigo

final class ReleaseCacheStorageTests: XCTestCase {
    private struct Probe: Decodable, Sendable, Equatable {
        let id: Int
        let title: String
    }

    /// Records what was asked for and how many were in flight at once.
    private actor FakeStorage {
        private let objects: [String: Data]
        private(set) var requested: [String] = []
        private var running = 0
        private(set) var peak = 0

        init(_ objects: [String: String]) {
            self.objects = objects.mapValues { Data($0.utf8) }
        }

        func fetch(_ path: String) async throws -> Data {
            requested.append(path)
            running += 1
            peak = max(peak, running)
            defer { running -= 1 }
            try await Task.sleep(for: .milliseconds(5))
            guard let data = objects[path] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    private func repository(_ storage: FakeStorage) -> MetadataRepository {
        var repository = MetadataRepository()
        repository.fetchStoredObject = { path in try await storage.fetch(path) }
        return repository
    }

    func testAnInlinePayloadIsReadWithoutTouchingStorage() async {
        let storage = FakeStorage([:])
        let found = await repository(storage).resolve(
            Probe.self,
            rows: [(id: "episode", inline: ["id": 1, "title": "Inline"], path: nil)]
        )
        XCTAssertEqual(found["episode"], Probe(id: 1, title: "Inline"))
        let requested = await storage.requested
        XCTAssertTrue(requested.isEmpty, "An inline row must not cost a request")
    }

    func testAMovedReleaseIsReadFromItsObject() async {
        let storage = FakeStorage(["releases/9.json": #"{"id":9,"title":"Nine"}"#])
        let found = await repository(storage).resolve(
            Probe.self,
            rows: [(id: "9", inline: nil, path: "releases/9.json")]
        )
        XCTAssertEqual(found["9"], Probe(id: 9, title: "Nine"))
    }

    /// A JSON null in the payload column is what a moved row actually looks
    /// like on the wire, and it must not be mistaken for an inline payload.
    func testANullPayloadWithAPathIsFetched() async {
        let storage = FakeStorage(["releases/9.json": #"{"id":9,"title":"Nine"}"#])
        let found = await repository(storage).resolve(
            Probe.self,
            rows: [(id: "9", inline: .null, path: "releases/9.json")]
        )
        XCTAssertEqual(found["9"]?.title, "Nine")
    }

    /// The case that decides whether a CDN hiccup is a slow page or a broken one.
    func testAnObjectThatWillNotLoadReadsAsAMiss() async {
        let storage = FakeStorage(["releases/1.json": #"{"id":1,"title":"One"}"#])
        let found = await repository(storage).resolve(
            Probe.self,
            rows: [
                (id: "1", inline: nil, path: "releases/1.json"),
                (id: "404", inline: nil, path: "releases/404.json"),
            ]
        )
        XCTAssertEqual(found.keys.sorted(), ["1"], "The missing one is simply absent")
    }

    func testAPayloadThatWillNotDecodeIsSkippedRatherThanFatal() async {
        let storage = FakeStorage(["releases/2.json": #"{"not":"a release"}"#])
        let found = await repository(storage).resolve(
            Probe.self,
            rows: [
                (id: "bad-inline", inline: ["unexpected": true], path: nil),
                (id: "2", inline: nil, path: "releases/2.json"),
                (id: "ok", inline: ["id": 3, "title": "Fine"], path: nil),
            ]
        )
        XCTAssertEqual(found.keys.sorted(), ["ok"])
    }

    /// An artist page reads a couple of dozen releases at once. They are
    /// fetched in parallel, but not all at once.
    func testABatchIsFetchedInParallelButBounded() async {
        var objects: [String: String] = [:]
        var rows: [(id: String, inline: AnyJSON?, path: String?)] = []
        for n in 1...30 {
            objects["releases/\(n).json"] = #"{"id":\#(n),"title":"R\#(n)"}"#
            rows.append((id: "\(n)", inline: nil, path: "releases/\(n).json"))
        }
        let storage = FakeStorage(objects)
        let found = await repository(storage).resolve(Probe.self, rows: rows, concurrency: 4)

        XCTAssertEqual(found.count, 30, "Every release in the batch should come back")
        let peak = await storage.peak
        XCTAssertGreaterThan(peak, 1, "A batch fetched one at a time is thirty round trips in a row")
        XCTAssertLessThanOrEqual(peak, 4, "No more than the limit in flight at once")
    }

    func testTheObjectURLPointsAtThePublicBucket() throws {
        guard let url = MetadataRepository.storedObjectURL(forPath: "releases/74698.json") else {
            throw XCTSkip("No Supabase URL configured in this build")
        }
        XCTAssertTrue(
            url.absoluteString.hasSuffix("/storage/v1/object/public/catalog-cache/releases/74698.json"),
            url.absoluteString
        )
    }
}
