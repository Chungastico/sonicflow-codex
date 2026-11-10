import Foundation
import AVFoundation

@MainActor
final class MicrophoneMonitor {
    private let engine = AVAudioEngine()
    private var lastAudible = Date.distantPast
    private var current = false
    private var timer: Timer?
    private var onChange: ((Bool) -> Void)?

    func start(_ onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.startEngine() }
        }
    }
    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        Self.installInputTap(input, format: format, monitor: self)
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let audible = Date().timeIntervalSince(self.lastAudible) < 2.0
                if audible != self.current { self.current = audible; self.onChange?(audible) }
            }
        }
    }
    nonisolated private static func installInputTap(_ input: AVAudioInputNode, format: AVAudioFormat, monitor: MicrophoneMonitor) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak monitor] buffer, _ in
            guard let samples = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var energy: Float = 0
            for index in 0..<count { energy += samples[index] * samples[index] }
            if sqrt(energy / Float(count)) > 0.025 {
                Task { @MainActor [weak monitor] in monitor?.lastAudible = Date() }
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        if current { current = false; onChange?(false) }
    }
}
