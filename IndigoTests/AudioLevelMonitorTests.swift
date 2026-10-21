import XCTest
import AVFoundation
@testable import Indigo

final class AudioLevelMonitorTests: XCTestCase {
    func testSilenceAndInvalidSamplesHaveNoEnergy() {
        XCTAssertEqual(AudioLevelStorage.normalized(rms: 0), 0)
        XCTAssertEqual(AudioLevelStorage.normalized(rms: .nan), 0)
        XCTAssertEqual(AudioLevelStorage.normalized(rms: .infinity), 0)
        XCTAssertEqual(AudioLevelStorage.normalized(rms: 1), 1)
    }

    func testMeterMeasuresWithoutChangingSamples() {
        let meter = AudioLevelStorage()
        meter.isFloat32 = true
        var samples: [Float] = [0.1, -0.1, 0.1, -0.1]
        let original = samples
        samples.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            meter.measure(&buffers)
        }
        XCTAssertEqual(samples, original)
        XCTAssertEqual(meter.read(), 0.6, accuracy: 0.001)
    }

    @MainActor
    func testPlayerTapReceivesAudioAndResetClearsIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = 0.2 * sin(Float(frame) * 2 * .pi * 220 / 44100)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let item = AVPlayerItem(url: url)
        let meter = AudioLevelMonitor()
        meter.attach(to: item)
        // Attach before starting so the test exercises the tap, not an early buffer.
        for _ in 0..<40 {
            if item.audioMix != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(item.audioMix)
        let player = AVPlayer(playerItem: item)
        player.volume = 0 // Test tone is measured before the final volume control.
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        var measured: Float = 0
        for _ in 0..<60 {
            measured = meter.level()
            if measured > 0.1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(measured, 0.1)
        meter.reset()
        XCTAssertEqual(meter.level(), 0)
    }
}

// MARK: - One failure is one failure

/// Three observers report the same dropped connection — the item's status
/// turning failed, a playbackStalled notification, and a
/// failedToPlayToEndTime notification — and each used to count as a separate
/// failure.
final class ReconnectPolicyTests: XCTestCase {
    func testASecondObserverIsNotASecondFailure() {
        var policy = ReconnectPolicy(limit: 5)

        XCTAssertEqual(policy.interrupted(), .retry(after: .zero))
        XCTAssertEqual(policy.interrupted(), .ignore, "The same failure, noticed again")
        XCTAssertEqual(policy.interrupted(), .ignore)
        XCTAssertEqual(policy.attempts, 1, "One failure spent one chance")
    }

    /// The cost that mattered most: the first retry waits no time at all by
    /// design, and a phantom attempt handed the real retry the one-second
    /// backoff meant for the second.
    func testTheFreeRetryIsNotSpentOnAPhantom() {
        var policy = ReconnectPolicy(limit: 5)
        _ = policy.interrupted()
        _ = policy.interrupted()

        // The stream is opened again, and fails for real this time.
        policy.opening()

        XCTAssertEqual(
            policy.interrupted(), .retry(after: .seconds(1)),
            "The second real failure waits a second — not the first one"
        )
    }

    func testAFailureAfterARestartIsANewFailure() {
        var policy = ReconnectPolicy(limit: 5)
        XCTAssertEqual(policy.interrupted(), .retry(after: .zero))
        policy.opening()
        XCTAssertEqual(policy.interrupted(), .retry(after: .seconds(1)))
        policy.opening()
        XCTAssertEqual(policy.interrupted(), .retry(after: .seconds(2)))
        XCTAssertEqual(policy.attempts, 3)
    }

    func testAStationRunsOutOfChances() {
        var policy = ReconnectPolicy(limit: 2)
        _ = policy.interrupted()
        policy.opening()
        _ = policy.interrupted()
        policy.opening()

        XCTAssertEqual(policy.interrupted(), .giveUp)
        XCTAssertEqual(policy.attempts, 2, "Giving up is not another attempt")
    }

    /// Anything playing means the trouble is over.
    func testPlayingClearsTheSlate() {
        var policy = ReconnectPolicy(limit: 5)
        _ = policy.interrupted()
        policy.reset()

        XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(policy.interrupted(), .retry(after: .zero),
                       "And the next failure gets the free retry again")
    }

    /// The backoff itself, unchanged: nothing, then 1, 2, 4, 8, capped.
    func testTheBackoffGrowsAndStops() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 1), .zero)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 2), .seconds(1))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 3), .seconds(2))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 4), .seconds(4))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 5), .seconds(8))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 9), .seconds(8))
    }
}

// MARK: - A station that has played is given time to come back

final class SustainedReconnectPolicyTests: XCTestCase {
    /// Five chances in sixteen seconds is right for a station that never
    /// answers and wrong for one that was playing a moment ago.
    func testAStationThatHasPlayedGetsTheLongerBudget() {
        var policy = ReconnectPolicy(limit: 2, sustainedLimit: 4)
        policy.playing()
        for _ in 0..<4 {
            guard case .retry = policy.interrupted() else { return XCTFail("Gave up early") }
            policy.opening()
        }
        XCTAssertEqual(policy.interrupted(), .giveUp)
        XCTAssertEqual(policy.attempts, 4)
    }

    func testAStationThatNeverPlayedKeepsTheShortOne() {
        var policy = ReconnectPolicy(limit: 2, sustainedLimit: 4)
        _ = policy.interrupted(); policy.opening()
        _ = policy.interrupted(); policy.opening()
        XCTAssertEqual(policy.interrupted(), .giveUp)
    }

    /// A dead zone is not the station's fault, and costs it nothing.
    func testAnOutageSpendsNoChances() {
        var policy = ReconnectPolicy(limit: 2, sustainedLimit: 2)
        policy.playing()
        XCTAssertEqual(policy.interrupted(isOnline: false), .waitForNetwork)
        XCTAssertEqual(policy.interrupted(isOnline: false), .ignore, "Already waiting")
        XCTAssertEqual(policy.attempts, 0)
        policy.opening()
        XCTAssertEqual(policy.interrupted(), .retry(after: .zero),
                       "Back online, the first retry is still the free one")
    }

    /// Pressing play offline says why, rather than buffering forever.
    func testAStationNeverHeardIsStillJudgedOffline() {
        var policy = ReconnectPolicy(limit: 1)
        XCTAssertEqual(policy.interrupted(isOnline: false), .retry(after: .zero))
        policy.opening()
        XCTAssertEqual(policy.interrupted(isOnline: false), .giveUp)
    }

    func testPuttingAStationOnForgetsThatTheLastOnePlayed() {
        var policy = ReconnectPolicy(limit: 1, sustainedLimit: 5)
        policy.playing()
        policy.reset()
        XCTAssertFalse(policy.hasPlayed)
        XCTAssertEqual(policy.currentLimit, 1)
    }
}

// MARK: - A station that has played comes back quickly

final class PlayedStationBackoffTests: XCTestCase {
    /// A dead zone ends without the path saying so, and an eight-second
    /// sleep could keep the station quiet that long after the signal was back.
    func testAStationThatHasPlayedWaitsAtMostTwoSeconds() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 1, hasPlayed: true), .zero)
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 2, hasPlayed: true), .seconds(1))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 3, hasPlayed: true), .seconds(2))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 9, hasPlayed: true), .seconds(2))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 15, hasPlayed: true), .seconds(2))
    }

    /// Half a minute of two-second retries, then the ordinary eight: a
    /// station still refusing is not a dead zone ending.
    func testTheQuickRetriesDoNotGoOnForever() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 16, hasPlayed: true), .seconds(8))
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 40, hasPlayed: true), .seconds(8))
    }

    func testThePolicyUsesItOnceTheStationHasPlayed() {
        var policy = ReconnectPolicy(limit: 5, sustainedLimit: 10)
        policy.playing()
        for _ in 0..<4 { _ = policy.interrupted(); policy.opening() }
        XCTAssertEqual(policy.interrupted(), .retry(after: .seconds(2)))
    }
}

// MARK: - A station that dropped out plays again from a cushion

final class CushionGateTests: XCTestCase {
    private let gate = CushionGate(target: 8, patience: 12, stallLimit: 10)

    func testItWaitsForTheCushion() {
        XCTAssertEqual(gate.decide(margin: 3, waited: 2, sinceProgress: 0.2, complete: false), .wait)
        XCTAssertEqual(gate.decide(margin: 8, waited: 6, sinceProgress: 0.2, complete: false), .play)
    }

    /// A station receiving slowly is not held forever.
    func testPatienceRunsOutForAStationThatIsReceiving() {
        XCTAssertEqual(gate.decide(margin: 4, waited: 12, sinceProgress: 0.3, complete: false), .play)
        XCTAssertEqual(gate.decide(margin: 0.5, waited: 12, sinceProgress: 0.3, complete: false), .wait,
                       "Half a second would only run dry again")
    }

    /// A connection that carries nothing for ten seconds is given up on —
    /// but not one still opening, which is the connect timeout's to judge.
    func testADeadConnectionIsReopened() {
        XCTAssertEqual(gate.decide(margin: 2, waited: 10, sinceProgress: 10, complete: false), .reopen)
        XCTAssertEqual(gate.decide(margin: nil, waited: 15, sinceProgress: 15, complete: false), .wait)
        XCTAssertEqual(gate.decide(margin: nil, waited: 30, sinceProgress: 30, complete: false), .reopen)
    }

    /// Everything there is, is in hand.
    func testAnItemWithAKnownEndPlaysWhenItIsAllLoaded() {
        XCTAssertEqual(gate.decide(margin: 1, waited: 0.25, sinceProgress: 0, complete: true), .play)
    }
}
