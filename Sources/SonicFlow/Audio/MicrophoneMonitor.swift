import Foundation
import AVFoundation
import SoundAnalysis
import CoreMedia

private final class SpeechObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    let detected: @Sendable () -> Void
    init(detected: @escaping @Sendable () -> Void) { self.detected = detected }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let score = result.classifications.first(where: { $0.identifier.lowercased() == "speech" })?.confidence ?? 0
        let music = result.classifications.filter { ["music", "singing"].contains($0.identifier.lowercased()) }.map(\.confidence).max() ?? 0
        if score > 0.55 && score > music * 1.05 { detected() }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) { NSLog("Speech analysis failed: %@", String(describing: error)) }
    func requestDidComplete(_ request: SNRequest) {}
}
private final class SpeechAnalyzer: @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer
    private let observer: SpeechObserver
    private let queue = DispatchQueue(label: "com.sonicflow.speech-analysis")
    init(format: AVAudioFormat, detected: @escaping @Sendable () -> Void) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        observer = SpeechObserver(detected: detected)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.0, preferredTimescale: 16000)
        request.overlapFactor = 0.75
        try analyzer.add(request, withObserver: observer)
    }
    func submit(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(sources, destinations) {
            if let src = source.mData, let dst = destination.mData { memcpy(dst, src, Int(source.mDataByteSize)) }
        }
        let position = time.sampleTime
        let submitted = Date()
        queue.async { [self] in
            let delay = Date().timeIntervalSince(submitted)
            if delay > 0.5 { NSLog("SonicFlow diagnostics: analysis backlog %.2f seconds", delay) }
            analyzer.analyze(copy, atAudioFramePosition: position)
        }
    }
}
@MainActor final class MicrophoneMonitor {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
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
        do {
            let classifier = try SpeechAnalyzer(format: format) { [weak self] in
                Task { @MainActor [weak self] in self?.lastAudible = Date() }
            }
            analyzer = classifier
            Self.installInputTap(input, format: format, classifier: classifier)
            try engine.start()
        } catch { NSLog("Speech detector startup failed: %@", String(describing: error)); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let audible = Date().timeIntervalSince(self.lastAudible) < 2.0
                if audible != self.current { self.current = audible; self.onChange?(audible) }
            }
        }
    }
    nonisolated private static func installInputTap(_ input: AVAudioInputNode, format: AVAudioFormat, classifier: SpeechAnalyzer) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in classifier.submit(buffer, time: time) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        analyzer = nil
        if current { current = false; onChange?(false) }
    }
}
