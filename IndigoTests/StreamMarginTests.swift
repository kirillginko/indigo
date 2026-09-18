//
//  StreamMarginTests.swift
//  IndigoTests
//

import XCTest
@testable import Indigo

/// Which stations the app has to get out of the way of.
///
/// Measured over two minutes each, against a request every 1.7 seconds —
/// which is what the picture backlog actually does while a station plays.
/// IDA holds 10.1s of audio in hand and never dipped under that load;
/// n10.as holds 1.95s and its buffer ran empty inside a minute, having not
/// stalled once in five minutes of being left alone.
///
/// The margin belongs to the station, not to the app: n10.as's Icecast hands
/// over a two-second burst and then paces exactly at realtime, so asking
/// AVPlayer for twenty seconds of buffer yielded the same 2.06s median.
/// Reading the margin is therefore the only way to tell the two apart.
final class StreamMarginTests: XCTestCase {
    func testAStationWithNoRoomIsProtected() {
        // n10.as, as measured.
        XCTAssertTrue(PlaybackCoordinator.shouldStandAside(forMargin: 1.95))
        XCTAssertTrue(PlaybackCoordinator.shouldStandAside(forMargin: 0.1))
    }

    func testAStationWithRoomIsNot() {
        // IDA, as measured. The listener who put it on still gets the faces
        // on the page they are reading.
        XCTAssertFalse(PlaybackCoordinator.shouldStandAside(forMargin: 10.1))
    }

    /// Before the first buffer is readable there is no margin to judge, and
    /// the wrong guess is the one that breaks up the broadcast.
    func testAnUnreadableMarginIsTreatedAsThin() {
        XCTAssertTrue(PlaybackCoordinator.shouldStandAside(forMargin: nil))
    }
}
