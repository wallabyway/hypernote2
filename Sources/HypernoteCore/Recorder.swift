import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Thread-safe FIFO of 16 kHz mono samples.
final class SampleQueue {
    private var samples: [Float] = []
    private let lock = NSLock()

    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    func append(_ new: [Float]) {
        lock.lock(); samples.append(contentsOf: new); lock.unlock()
    }

    /// Removes and returns up to `n` samples from the front.
    func take(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let k = min(n, samples.count)
        let out = Array(samples.prefix(k))
        samples.removeFirst(k)
        return out
    }

    /// Drops the oldest samples so at most `keep` remain (limits drift between clocks).
    func trim(keep: Int) {
        lock.lock(); defer { lock.unlock() }
        if samples.count > keep { samples.removeFirst(samples.count - keep) }
    }
}

enum AudioMixer {
    /// Sums two sources sample-by-sample into `count` frames; the shorter source is zero-padded.
    static func mix(_ a: [Float], _ b: [Float], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let s = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
            out[i] = max(-1, min(1, s))
        }
        return out
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

/// Converts arbitrary PCM buffers to 16 kHz mono Float32 samples.
final class PCMResampler {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            sourceFormat = buffer.format
        }
        guard let converter else { return [] }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Records microphone (+ optionally system audio) into one mono AAC file.
///
/// The microphone is the master clock: every 250 ms we write exactly as many frames as the
/// microphone delivered, mixing in whatever system audio is available.
public final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onLevel: ((Float) -> Void)?
    public private(set) var systemAudioActive = false

    private let engine = AVAudioEngine()
    private let micQueue = SampleQueue()
    private let sysQueue = SampleQueue()
    private let micResampler = PCMResampler()
    private let sysResampler = PCMResampler()
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var stream: SCStream?
    private let writeQueue = DispatchQueue(label: "hypernote2.recorder.write")
    private let sysQueueGCD = DispatchQueue(label: "hypernote2.recorder.system")
    private var framesWritten = 0

    public override init() { super.init() }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(to url: URL, captureSystemAudio: Bool) async throws {
        guard await Self.requestMicrophoneAccess() else {
            throw HypernoteError.message(
                "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.")
        }

        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
        framesWritten = 0

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw HypernoteError.message("No microphone input available.") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.micQueue.append(self.micResampler.convert(buffer))
        }
        engine.prepare()
        try engine.start()

        if captureSystemAudio {
            do {
                try await startSystemAudio()
                systemAudioActive = true
            } catch {
                systemAudioActive = false   // mic-only fallback; caller can read `systemAudioActive`
            }
        }

        let t = DispatchSource.makeTimerSource(queue: writeQueue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    /// Stops capture, flushes remaining audio and returns the recorded duration in seconds.
    public func stop() async -> Double {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        timer?.cancel()
        timer = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writeQueue.async { self.flush(); c.resume() }
        }
        file = nil   // closing the file finalizes the m4a
        return Double(framesWritten) / 16_000
    }

    private func flush() {
        let n = micQueue.count
        guard n > 0, let file else { return }
        let mic = micQueue.take(n)
        let sys = sysQueue.take(n)
        sysQueue.trim(keep: 16_000)   // never let system audio drift more than 1 s behind
        let mixed = AudioMixer.mix(mic, sys, count: n)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        mixed.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: n)
        }
        do {
            try file.write(from: buffer)
            framesWritten += n
        } catch {
            // Disk errors surface as a short recording; nothing safe to do on the audio thread.
        }
        onLevel?(AudioMixer.rms(mixed))
    }

    // MARK: System audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw HypernoteError.message("No display available for system audio capture.")
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQueueGCD)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sysQueueGCD)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        sysQueue.append(sysResampler.convert(pcm))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        systemAudioActive = false
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
