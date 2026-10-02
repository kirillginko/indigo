//
//  UserDataWriteGateTests.swift
//  IndigoTests
//
//  When the listener's store cannot be opened the app runs unsaved, and the
//  one thing that must not happen is a crate row, a listen or a dig that looks
//  kept and is gone at quit. Each owner of one of those writes refuses it.
//

import XCTest
import SwiftData
@testable import Indigo

final class UserDataWriteGateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: Persistence.schema, configurations: configuration)
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    private func recording() throws -> Recording {
        try RecordingStore(context: context).upsert(title: "Rev8617", artistName: "Skee Mask")
    }

    func testTheTestHostCanWrite() {
        XCTAssertTrue(Persistence.userDataWritable)
        XCTAssertNil(Persistence.openFailure)
    }

    // MARK: Crate

    func testAnUnwritableCrateRefusesToAddAndSaysWhy() throws {
        let crate = CrateService(context: context, writable: false)

        XCTAssertNil(crate.add(recording: try recording()))
        XCTAssertNil(crate.add(
            broadcast: "nts.show.x", providerID: "nts", title: "X", subtitle: nil,
            artworkURL: nil, playbackURL: nil, embedProvider: nil))
        XCTAssertNil(crate.add(
            dig: .artist, identifier: "a", providerID: "mb", title: "A",
            subtitle: nil, artworkURL: nil))

        XCTAssertEqual(crate.count, 0)
        XCTAssertEqual(crate.notice, Persistence.userDataUnavailableNotice)
    }

    func testAnUnwritableCrateDoesNotRemoveWhatIsThere() throws {
        let writable = CrateService(context: context, writable: true)
        let kept = try recording()
        let item = try XCTUnwrap(writable.add(recording: kept))
        XCTAssertEqual(writable.count, 1)

        let locked = CrateService(context: context, writable: false)
        locked.remove(item)
        locked.toggle(recording: kept)

        XCTAssertEqual(writable.count, 1)
    }

    func testAWritableCrateStillAdds() throws {
        let crate = CrateService(context: context, writable: true)
        XCTAssertNotNil(crate.add(recording: try recording()))
        XCTAssertEqual(crate.count, 1)
        XCTAssertNil(crate.notice)
    }

    // MARK: Listening

    func testAnUnwritableLogRecordsNothingAndForgetsNothing() {
        let node = MusicNode.label("Ilian Tape")
        XCTAssertNotNil(ListeningLog(context: context, writable: true).record(node, action: .opened))

        let locked = ListeningLog(context: context, writable: false)
        XCTAssertNil(locked.record(node, action: .opened))
        locked.forget()

        XCTAssertEqual(locked.all().count, 1)
    }

    // MARK: Dig history

    func testAnUnwritableDigHistoryRecordsNothingAndForgetsNothing() {
        let node = MusicNode.label("Ilian Tape")
        DigHistory(context: context, writable: true).record(node)

        let locked = DigHistory(context: context, writable: false)
        locked.record(MusicNode.label("Hessle Audio"))
        locked.forget()

        XCTAssertEqual(locked.visits().map(\.title), ["Ilian Tape"])
    }
}
