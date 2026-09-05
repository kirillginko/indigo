//
//  PageReturnTests.swift
//  IndigoTests
//
//  Coming back to a page should show what it showed when you left it.
//
//  Both For You and the Crate kept their worked-out answers in the view's own
//  `@State`, which SwiftUI discards the moment somebody navigates away. So
//  every return drew the page from nothing and filled it in a moment later,
//  and what you saw on the way in was the whole list rearranging itself. The
//  answers live on the stores now, which outlive the views.
//

import XCTest
import SwiftData
@testable import Indigo

@MainActor
final class PageReturnTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func crateARecording(_ title: String) {
        let store = RecordingStore(context: context)
        let recording = try? store.upsert(title: title, artistName: "Somebody")
        if let recording { context.insert(CrateItem(recording: recording)) }
        try? context.save()
    }

    func testTheCrateDoesNotWorkItsRowsOutAgainOnEveryReturn() {
        crateARecording("A Track")
        let crate = CrateService(context: context)

        var passes = 0
        func visit() {
            crate.refreshRowCache(digRevision: 7) { _ in
                passes += 1
                return nil
            }
        }

        visit()
        XCTAssertTrue(crate.hasResolvedRows)
        let afterFirst = passes
        XCTAssertGreaterThan(afterFirst, 0)

        // Leaving and coming back, twice. Nothing has changed, so nothing is
        // worked out again — which is what stops the list drawing itself
        // unresolved and then resolved on the way in.
        visit()
        visit()
        XCTAssertEqual(passes, afterFirst)
    }

    func testTheCrateDoesWorkThemOutAgainWhenSomethingIsAdded() throws {
        crateARecording("A Track")
        let crate = CrateService(context: context)
        var passes = 0
        crate.refreshRowCache(digRevision: 1) { _ in passes += 1; return nil }
        let afterFirst = passes

        // Through the service, which is how every crate write in the app
        // happens — and what moves the revision the cache is keyed on.
        let another = try XCTUnwrap(
            try? RecordingStore(context: context).upsert(title: "Another", artistName: "Somebody")
        )
        crate.add(recording: another)

        crate.refreshRowCache(digRevision: 1) { _ in passes += 1; return nil }
        XCTAssertGreaterThan(passes, afterFirst)
    }

    func testTheCrateFollowsDigWhenACreditIsRepaired() {
        crateARecording("A Track")
        let crate = CrateService(context: context)
        var passes = 0
        crate.refreshRowCache(digRevision: 1) { _ in passes += 1; return nil }
        let afterFirst = passes

        // A DIG write can give a recording an artist to open, so the row's
        // destination has to be able to appear.
        crate.refreshRowCache(digRevision: 2) { _ in passes += 1; return nil }
        XCTAssertGreaterThan(passes, afterFirst)
    }

    func testARowIsPlayableUntilProvenOtherwise() {
        crateARecording("A Track")
        let crate = CrateService(context: context)
        // Before the first pass has run, nothing is known — and a list that
        // says somebody's music cannot be played while it is still working
        // that out is worse than one that finds out on press.
        XCTAssertFalse(crate.hasResolvedRows)
        XCTAssertTrue(crate.resolvedSources.isEmpty)
    }
}
