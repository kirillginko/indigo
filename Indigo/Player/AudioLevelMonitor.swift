import AVFoundation
import MediaToolbox
import Accelerate
import os

// The render callback only measures the supplied samples. It never changes audio,
// allocates buffers, dispatches UI work, or waits for the UI to release a lock.
nonisolated final class AudioLevelStorage: @unchecked Sendable {
    private let sample = OSAllocatedUnfairLock(initialState: (level: Float(0), at: UInt64(0)))
    // Only accessed by the serialized prepare/process callbacks.
    var isFloat32 = false

    func measure(_ buffers: UnsafeMutablePointer<AudioBufferList>) {
        guard isFloat32 else { return }
        var sum: Float = 0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let length = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard length > 0 else { continue }
            var rms: Float = 0
            vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &rms, vDSP_Length(length))
            sum += rms * rms * Float(length)
            count += length
        }
        guard count > 0 else { return }
        let rms = sqrt(sum / Float(count))
        let level = Self.normalized(rms: rms)
        _ = sample.withLockIfAvailable { $0 = (level, mach_absolute_time()) }
    }

    static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        // A useful visual range from -50 dB to full scale.
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }

    func read() -> Float {
        let value = sample.withLock { $0 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let age = Double(mach_absolute_time() - value.at) * Double(info.numer) / Double(info.denom) / 1e9
        return age < 0.3 ? value.level : 0
    }
}

/// Optional metering for AVPlayer assets with accessible audio tracks. Widgets
/// and unsupported streams keep the visual's ambient motion without fake levels.
@MainActor
final class AudioLevelMonitor {
    private var storage = AudioLevelStorage()
    private var attachment: Task<Void, Never>?

    deinit { attachment?.cancel() }

    func reset() {
        attachment?.cancel()
        storage = AudioLevelStorage()
    }

    func level() -> Float { storage.read() }

    func attach(to item: AVPlayerItem) {
        reset()
        let storage = storage
        attachment = Task { [weak item] in
            guard let item,
                  let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  !Task.isCancelled else { return }
            let retained = Unmanaged.passRetained(storage)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: retained.toOpaque(),
                init: { _, info, out in out.pointee = info },
                finalize: { tap in
                    Unmanaged<AudioLevelStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                },
                prepare: { tap, _, format in
                    let state = Unmanaged<AudioLevelStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    state.isFloat32 = format.pointee.mFormatID == kAudioFormatLinearPCM
                        && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                        && format.pointee.mBitsPerChannel == 32
                },
                unprepare: nil,
                process: { tap, frames, _, buffers, framesOut, flagsOut in
                    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else {
                        framesOut.pointee = 0
                        return
                    }
                    let state = Unmanaged<AudioLevelStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    state.measure(buffers)
                }
            )
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                            kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
                  let tap else {
                retained.release()
                return
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }
}
