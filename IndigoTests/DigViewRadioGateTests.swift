//
//  DigViewRadioGateTests.swift
//  IndigoTests
//
//  The deadline the DIG landing page waits behind.
//
//  It had one for a long time and it never applied. The page raced the radio
//  request against a 900ms sleep inside a `withTaskGroup`, which reads like a
//  timeout and is not one: a group does not return until every child has
//  returned, and the child awaiting the request was awaiting an unstructured
//  `Task`, which cancellation cannot interrupt. A trace of a cold landing put
//  the "capped" wait at 1956ms — 72% of a 2715ms page.
//
//  These measure the promise rather than the spelling: the caller stops
//  waiting at the deadline, and the abandoned work is left running rather
//  than cancelled.
//

import XCTest
@testable import Indigo

@MainActor
final class DigViewRadioGateTests: XCTestCase {
    private func milliseconds(_ body: () async -> Void) async -> Int {
        let started = ContinuousClock.now
        await body()
        let parts = (ContinuousClock.now - started).components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// The case the old spelling got wrong.
    func testASlowLoadDoesNotHoldThePagePastTheDeadline() async {
        let slow = Task { _ = try? await Task.sleep(for: .milliseconds(3000)) }
        let waited = await milliseconds {
            await waitForFirst(slow, orAfter: .milliseconds(300))
        }
        XCTAssertLessThan(
            waited, 1500,
            "The page must stop waiting at the deadline, not at the request"
        )
        slow.cancel()
    }

    /// And the case it got right, which must keep working: a backend
    /// answering promptly should not make the page sit out the whole deadline.
    func testAPromptLoadIsNotMadeToWaitForTheDeadline() async {
        let quick = Task { _ = try? await Task.sleep(for: .milliseconds(20)) }
        let waited = await milliseconds {
            await waitForFirst(quick, orAfter: .seconds(5))
        }
        XCTAssertLessThan(
            waited, 2000,
            "A load that lands early must release the page immediately"
        )
    }

    /// The deadline stops the waiting, not the work. The request goes on and
    /// writes what it found, which is why the page can fill in afterwards.
    func testTheAbandonedLoadIsLeftRunningRatherThanCancelled() async {
        let finished = Finished()
        let slow = Task {
            try? await Task.sleep(for: .milliseconds(400))
            finished.mark()
        }
        await waitForFirst(slow, orAfter: .milliseconds(50))
        XCTAssertFalse(finished.value, "Precondition: the deadline won the race")

        await slow.value
        XCTAssertTrue(
            finished.value,
            "The abandoned request must run to completion, not be cancelled"
        )
    }

    @MainActor
    private final class Finished {
        private(set) var value = false
        func mark() { value = true }
    }
}
