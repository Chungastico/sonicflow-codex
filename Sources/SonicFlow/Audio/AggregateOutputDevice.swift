import Foundation
import CoreAudio
import AudioToolbox

/// Slot in the gain table — one per active app, indexed by tap order.
/// Float reads/writes are atomic on aligned 32-bit boundaries — IOProc reads
/// without locks; stale reads of at most one buffer (~10ms) are fine.
final class GainSlot {
    private(set) var gain: Float = 1.0
    private let pointer: UnsafeMutablePointer<Float>

    init(pointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
        pointer.pointee = 1.0
    }

    func setGain(_ value: Float) {
        let clamped = max(0, min(2, value))  // allow modest boost (>1.0)
        gain = clamped
        pointer.pointee = clamped
    }
}

/// **CAPTURE half of Phase 3.**
///
/// Builds a private aggregate device containing per-app process taps.
/// Apps that are tapped have their audio silenced from the normal output
/// path (via `CATapMutedWhenTapped`) and routed to us. Our IOProc:
///   1. Reads each tap's input buffer
///   2. Applies per-app gain
///   3. Mixes all taps into a single stereo stream
///   4. Writes that stream to the ring buffer
///
/// The playback half (`PlaybackDevice`) reads from the ring buffer on the
/// user's default output device's IOProc and mixes into the speakers.
final class AggregateOutputDevice {
    let aggregateID: AudioObjectID
    private(set) var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// Per-tap gain slots in the same order taps were passed at init.
    let gainSlots: [GainSlot]
    private let gainBuffer: UnsafeMutableBufferPointer<Float>
    private let smoothedGains = UnsafeMutablePointer<Float>.allocate(capacity: 32)

    /// Output ring buffer shared with the playback IOProc.
    private let ringBuffer: FloatRingBuffer

    /// Frame counters (IOProc updates atomically).
    /// Layout: [0]=tap-frames-in, [1]=samples-written-to-ring, [2]=ring-overruns.
    private let counterBuffer: UnsafeMutableBufferPointer<UInt64>

    var framesReceived: UInt64 { counterBuffer[0] }
    var samplesToRing:  UInt64 { counterBuffer[1] }
    var ringOverruns:   UInt64 { counterBuffer[2] }

    private let slotCount: Int
    private let voiceIndex: Int
    private let voiceLevelPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    var voiceLevel: Float { voiceLevelPtr.pointee }

    /// One-shot diagnostic so we know the buffer layout at runtime.
    private var didLogPtr: UnsafeMutablePointer<UInt32>?

    init(
        outputDeviceUID: String,
        taps: [ProcessTap],
        ringBuffer: FloatRingBuffer
    ) throws {
        precondition(taps.count <= 32, "Phase 3 supports up to 32 taps")
        smoothedGains.initialize(repeating: 1, count: 32)
        self.slotCount = taps.count
        self.voiceIndex = taps.firstIndex(where: { $0.bundleID.lowercased().hasPrefix("com.openai.codex") }) ?? -1
        voiceLevelPtr.initialize(to: 0)
        self.ringBuffer = ringBuffer

        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        buf.initialize(repeating: 1.0)
        self.gainBuffer = buf
        self.gainSlots = (0..<taps.count).map { i in
            GainSlot(pointer: buf.baseAddress!.advanced(by: i))
        }

        let cbuf = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 3)
        cbuf.initialize(repeating: 0)
        self.counterBuffer = cbuf

        // Build a private aggregate. We DO include the user's output device
        // as a sub-device — gives us a stable clock source matching the
        // playback device's sample rate.
        let aggregateUID = "com.sonicflow.aggregate.\(UUID().uuidString)"
        var tapList: [[String: Any]] = []
        for tap in taps {
            if let uid = Self.tapUID(for: tap.tapID) {
                tapList.append([kAudioSubTapUIDKey: uid])
            }
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "SonicFlow Capture",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: tapList
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard status == noErr, aggID != kAudioObjectUnknown else {
            buf.deallocate()
            cbuf.deallocate()
            throw AggregateError.creationFailed(status: status)
        }
        self.aggregateID = aggID
    }

    deinit {
        stop()
        if let pid = ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, pid)
        }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        smoothedGains.deallocate()
        gainBuffer.deallocate()
        counterBuffer.deallocate()
        voiceLevelPtr.deallocate()
        didLogPtr?.deallocate()
    }

    func start() throws {
        let gainPtr = gainBuffer.baseAddress!
        let smoothPtr = smoothedGains
        let counterPtr = counterBuffer.baseAddress!
        let count = slotCount
        let voiceIndex = self.voiceIndex
        let voiceLevelPtr = self.voiceLevelPtr
        let ring = ringBuffer

        let didLog = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        didLog.initialize(to: 0)
        self.didLogPtr = didLog

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            nil
        ) { _, inputData, _, outputData, _ in
            AggregateOutputDevice.captureCallback(
                input: inputData,
                output: outputData,
                gains: gainPtr,
                smoothedGains: smoothPtr,
                slotCount: count,
                voiceIndex: voiceIndex,
                voiceLevel: voiceLevelPtr,
                ring: ring,
                counters: counterPtr,
                didLog: didLog
            )
        }
        guard status == noErr, let id = procID else {
            throw AggregateError.ioProcCreationFailed(status: status)
        }
        self.ioProcID = id

        let startStatus = AudioDeviceStart(aggregateID, id)
        guard startStatus == noErr else {
            throw AggregateError.startFailed(status: startStatus)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning, let id = ioProcID else { return }
        AudioDeviceStop(aggregateID, id)
        isRunning = false
    }

    // MARK: - Realtime callback — captures tap audio into the ring buffer.
    //
    // Strict realtime constraints: no allocation, no locks, no main-actor
    // state. Scratch space is stack-allocated as a fixed-size local buffer.

    /// Stereo float32 scratch space sized for one IOProc buffer.
    /// 2048 samples = 1024 stereo frames = ~21 ms at 48kHz — plenty of
    /// headroom for typical IOProc buffer sizes (256-1024 frames).
    private static let scratchSamples = 2048

    private static func captureCallback(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gains: UnsafeMutablePointer<Float>,
        smoothedGains: UnsafeMutablePointer<Float>,
        slotCount: Int,
        voiceIndex: Int,
        voiceLevel: UnsafeMutablePointer<Float>,
        ring: FloatRingBuffer,
        counters: UnsafeMutablePointer<UInt64>,
        didLog: UnsafeMutablePointer<UInt32>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        if didLog.pointee == 0 {
            didLog.pointee = 1
            var msg = "[capture] inputBuffers=\(inList.count)"
            for (i, b) in inList.enumerated() {
                msg += " in[\(i)]: ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            msg += " | outputBuffers=\(outList.count)"
            for (i, b) in outList.enumerated() {
                msg += " out[\(i)]: ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)"
            }
            msg += "\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        // Always zero outputData — we don't drive audio from this device.
        for b in outList {
            if let m = b.mData {
                let f = m.assumingMemoryBound(to: Float.self)
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                f.update(repeating: 0, count: n)
            }
        }

        // Determine the mix length from the largest tap buffer.
        var mixSamples = 0
        let tapCount = min(inList.count, slotCount)
        // A physical device with an input stream may precede the process taps.
        // Never remix that microphone stream into the headphones.
        let tapOffset = max(0, inList.count - slotCount)
        voiceLevel.pointee = 0
        for i in 0..<tapCount {
            let s = Int(inList[tapOffset + i].mDataByteSize) / MemoryLayout<Float>.size
            if s > mixSamples { mixSamples = s }
        }
        if mixSamples == 0 { return }
        mixSamples = min(mixSamples, scratchSamples)

        // Stack-allocate the mix scratch buffer (no heap alloc on realtime thread).
        withUnsafeTemporaryAllocation(of: Float.self, capacity: mixSamples) { mixBuf in
            // Zero.
            mixBuf.update(repeating: 0)

            var totalIn: UInt64 = 0

            for i in 0..<tapCount {
                let inB = inList[tapOffset + i]
                guard let mData = inB.mData else { continue }
                let inFloats = mData.assumingMemoryBound(to: Float.self)
                let inSamples = Int(inB.mDataByteSize) / MemoryLayout<Float>.size
                totalIn &+= UInt64(inSamples)

                if i == voiceIndex {
                    var sum: Float = 0
                    let count = max(1, min(inSamples, mixSamples))
                    for j in 0..<count { let value = inFloats[j]; sum += value * value }
                    voiceLevel.pointee = sqrtf(sum / Float(count))
                    continue // voice remains on the normal output; never remix it
                }
                let target = gains.advanced(by: i).pointee
                var gain = smoothedGains.advanced(by: i).pointee
                let n = min(inSamples, mixSamples)
                // Stereo samples at roughly 48 kHz: quick fade down, gentle fade up.
                let step: Float = target < gain ? 1.0 / 19200.0 : 1.0 / 96000.0
                for f in 0..<n {
                    if gain < target { gain = min(target, gain + step) }
                    else if gain > target { gain = max(target, gain - step) }
                    mixBuf[f] += inFloats[f] * gain
                }
                smoothedGains.advanced(by: i).pointee = gain
            }

            // Soft clip to prevent overshoot.
            for f in 0..<mixSamples {
                let s = mixBuf[f]
                if s > 1.0 { mixBuf[f] = 1.0 }
                else if s < -1.0 { mixBuf[f] = -1.0 }
            }

            // Publish to ring buffer for the playback IOProc to consume.
            let written = ring.write(mixBuf.baseAddress!, count: mixSamples)

            counters[0] &+= totalIn
            counters[1] &+= UInt64(written)
            if written < mixSamples {
                counters[2] &+= UInt64(mixSamples - written)
            }
        }
    }

    // MARK: - Helpers

    /// Read the UID property of a tap object via `kAudioTapPropertyUID`.
    private static func tapUID(for tapID: AudioObjectID) -> String? {
        return CAObject.readString(tapID, .tapUID)
    }
}

enum AggregateError: Error, CustomStringConvertible {
    case creationFailed(status: OSStatus)
    case ioProcCreationFailed(status: OSStatus)
    case startFailed(status: OSStatus)
    case noDefaultOutputDevice

    var description: String {
        switch self {
        case let .creationFailed(s):       return "AudioHardwareCreateAggregateDevice failed: \(s)"
        case let .ioProcCreationFailed(s): return "AudioDeviceCreateIOProcIDWithBlock failed: \(s)"
        case let .startFailed(s):          return "AudioDeviceStart failed: \(s)"
        case .noDefaultOutputDevice:       return "Could not read default output device"
        }
    }
}
