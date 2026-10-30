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

/// Energy-based voice detector fed with ~250 ms chunks. Adapts to the room's noise floor so
/// a fan or hum doesn't count as speech.
struct VoiceActivity {
    static let minimumThreshold: Float = 0.01   // ≈ -40 dBFS RMS; normal speech sits well above
    private(set) var noiseFloor: Float = 0.002

    mutating func isVoice(_ rms: Float) -> Bool {
        let voice = rms > max(Self.minimumThreshold, noiseFloor * 4)
        if rms < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + rms * 0.1        // fall quickly
        } else if !voice {
            noiseFloor = noiseFloor * 0.995 + rms * 0.005    // rise slowly
        }
        noiseFloor = max(noiseFloor, 0.0005)
        return voice
    }
}

/// Manual pause plus auto-pause after a stretch of silence (auto-resumes when speech returns).
struct PauseLogic {
    enum Event: Equatable { case none, autoPaused, autoResumed }

    var autoPauseEnabled: Bool
    let autoPauseFrames: Int
    private(set) var manualPaused = false
    private(set) var autoPaused = false
    private var framesSeen = 0
    private var lastVoiceFrame = 0
    private var recentVoice: [Bool] = []
    private var vad = VoiceActivity()

    var isPaused: Bool { manualPaused || autoPaused }

    init(autoPauseEnabled: Bool, autoPauseSeconds: Double, sampleRate: Double = 16_000) {
        self.autoPauseEnabled = autoPauseEnabled
        self.autoPauseFrames = Int(autoPauseSeconds * sampleRate)
    }

    mutating func pause() { manualPaused = true }

    /// Manual resume also clears an auto-pause and restarts the silence countdown.
    mutating func resume() {
        manualPaused = false
        autoPaused = false
        lastVoiceFrame = framesSeen
        recentVoice.removeAll()
    }

    /// Feed one chunk; returns whether this chunk flipped the auto-pause state.
    mutating func process(rms: Float, frames: Int) -> Event {
        framesSeen += frames
        let voice = vad.isVoice(rms)
        if voice { lastVoiceFrame = framesSeen }
        recentVoice.append(voice)
        if recentVoice.count > 4 { recentVoice.removeFirst() }

        if autoPaused && !manualPaused {
            // Two voiced chunks within ~1 s, so a single click or cough doesn't resume.
            if recentVoice.filter({ $0 }).count >= 2 {
                autoPaused = false
                return .autoResumed
            }
        } else if !isPaused && autoPauseEnabled && framesSeen - lastVoiceFrame >= autoPauseFrames {
            autoPaused = true
            return .autoPaused
        }
        return .none
    }
}

/// Records microphone (+ optionally system audio) into one mono AAC file.
///
/// The microphone is the master clock: every 250 ms we write exactly as many frames as the
/// microphone delivered, mixing in whatever system audio is available.
public final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onLevel: ((Float) -> Void)?
    /// Called on a background queue when recording pauses/resumes. `auto` = triggered by silence detection.
    public var onPauseChange: ((_ paused: Bool, _ auto: Bool) -> Void)?
    public static let autoPauseSeconds: Double = 30
    public private(set) var systemAudioActive = false
    /// Why system audio isn't being captured (nil when it is, or when it wasn't requested).
    public private(set) var systemAudioProblem: SystemAudioProblem?

    public enum SystemAudioProblem { case permissionDenied, failed(String) }

    private let engine = AVAudioEngine()
    private let micQueue = SampleQueue()
    private let sysQueue = SampleQueue()
    private let micResampler = PCMResampler()
    private let sysResampler = PCMResampler()
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var stream: SCStream?
    private var tap: AnyObject?   // SystemAudioTap (macOS 14.2+)
    private let writeQueue = DispatchQueue(label: "hypernote2.recorder.write")
    private let sysQueueGCD = DispatchQueue(label: "hypernote2.recorder.system")
    private var framesWritten = 0
    private var pauseLogic: PauseLogic
    /// Audio from just before an auto-resume, so the first words aren't cut off.
    private var preRoll: [[Float]] = []
    private let statsLock = NSLock()
    private var recordedFrames = 0

    public init(autoPause: Bool = true) {
        pauseLogic = PauseLogic(autoPauseEnabled: autoPause, autoPauseSeconds: Self.autoPauseSeconds)
        super.init()
    }

    /// Seconds of audio written so far (excludes paused time).
    public var recordedSeconds: Double {
        statsLock.lock(); defer { statsLock.unlock() }
        return Double(recordedFrames) / 16_000
    }

    public func pause() {
        writeQueue.async {
            guard !self.pauseLogic.manualPaused else { return }
            let wasPaused = self.pauseLogic.isPaused
            self.pauseLogic.pause()
            if !wasPaused { self.preRoll.removeAll() }
            self.onPauseChange?(true, false)
        }
    }

    public func resume() {
        writeQueue.async {
            guard self.pauseLogic.isPaused else { return }
            self.pauseLogic.resume()
            self.preRoll.removeAll()
            self.onPauseChange?(false, false)
        }
    }

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
            } catch HypernoteError.message(let m) where m == Self.deniedMarker {
                systemAudioProblem = .permissionDenied   // mic-only fallback
            } catch {
                systemAudioProblem = .failed(error.localizedDescription)
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
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
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
        guard n > 0, file != nil else { return }
        let mic = micQueue.take(n)
        let sys = sysQueue.take(n)
        sysQueue.trim(keep: 16_000)   // never let system audio drift more than 1 s behind
        let mixed = AudioMixer.mix(mic, sys, count: n)
        let rms = AudioMixer.rms(mixed)
        onLevel?(rms)

        switch pauseLogic.process(rms: rms, frames: n) {
        case .autoPaused:
            preRoll.removeAll()
            onPauseChange?(true, true)
        case .autoResumed:
            preRoll.forEach(write)
            preRoll.removeAll()
            onPauseChange?(false, true)
        case .none:
            break
        }

        if pauseLogic.isPaused {
            preRoll.append(mixed)
            while preRoll.reduce(0, { $0 + $1.count }) > 16_000 { preRoll.removeFirst() }   // keep ~1 s
        } else {
            write(mixed)
        }
    }

    private func write(_ samples: [Float]) {
        let n = samples.count
        guard n > 0, let file,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))
        else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: n)
        }
        do {
            try file.write(from: buffer)
            framesWritten += n
            statsLock.lock(); recordedFrames = framesWritten; statsLock.unlock()
        } catch {
            // Disk errors surface as a short recording; nothing safe to do on the audio thread.
        }
    }

    // MARK: System audio

    private static let deniedMarker = "system-audio-permission-denied"

    private func startSystemAudio() async throws {
        if #available(macOS 14.2, *) {
            // Core Audio process tap: only needs "System Audio Recording Only" permission.
            guard await SystemAudioPermission.request() else {
                throw HypernoteError.message(Self.deniedMarker)
            }
            let tap = SystemAudioTap()
            try tap.start { [weak self] pcm in
                guard let self else { return }
                self.sysQueue.append(self.sysResampler.convert(pcm))
            }
            self.tap = tap
        } else {
            try await startScreenCaptureAudio()
        }
    }

    /// Fallback for macOS 14.0–14.1 (requires Screen Recording permission).
    private func startScreenCaptureAudio() async throws {
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
