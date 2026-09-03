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
