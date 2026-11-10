import AppKit
import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

let recorderLog = Logger(subsystem: "com.hypernote2.app", category: "recorder")

/// Monotonic clock in seconds (does not advance while the Mac sleeps).
func uptimeSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Thread-safe FIFO of 16 kHz mono samples. Remembers when audio last arrived so a dead
/// input (unplugged device, engine stopped by Core Audio) can be detected.
final class SampleQueue {
    private var samples: [Float] = []
    private var lastAppend: Double
    private let lock = NSLock()

    init(now: Double = uptimeSeconds()) { lastAppend = now }

    var count: Int { lock.lock(); defer { lock.unlock() }; return samples.count }

    /// Seconds since audio last arrived (or since `markAlive`).
    func secondsSinceLastAppend(now: Double = uptimeSeconds()) -> Double {
        lock.lock(); defer { lock.unlock() }
        return now - lastAppend
    }

    /// Restarts the stall clock, e.g. right after (re)starting the device.
    func markAlive(now: Double = uptimeSeconds()) {
        lock.lock(); lastAppend = now; lock.unlock()
    }

    func append(_ new: [Float], now: Double = uptimeSeconds()) {
        lock.lock(); samples.append(contentsOf: new); lastAppend = now; lock.unlock()
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

    func removeAll() { lock.lock(); samples.removeAll(); lock.unlock() }
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
/// a fan or hum doesn't count as speech — but the floor is capped, so hours of steady noise
/// (HVAC, a quiet radio) can never push the threshold above normal speech.
struct VoiceActivity {
    static let minimumThreshold: Float = 0.008   // ≈ -42 dBFS RMS; normal speech sits well above
    static let maximumNoiseFloor: Float = 0.005  // ⇒ threshold never exceeds ≈ -36 dBFS
    private(set) var noiseFloor: Float = 0.002

    var threshold: Float { max(Self.minimumThreshold, noiseFloor * 3) }

    mutating func isVoice(_ rms: Float) -> Bool {
        let voice = rms > threshold
        if rms < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + rms * 0.1        // fall quickly
        } else if !voice {
            noiseFloor = noiseFloor * 0.995 + rms * 0.005    // rise slowly
        }
        noiseFloor = min(max(noiseFloor, 0.0005), Self.maximumNoiseFloor)
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
                lastVoiceFrame = framesSeen
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
/// Normally the microphone is the master clock: every 250 ms we write exactly as many frames as
/// the microphone delivered, mixing in whatever system audio is available. Core Audio stops the
/// engine whenever the input device changes (headphones, AirPods, docks, sleep/wake), so:
///  - configuration changes and wake rebuild the microphone engine,
///  - a watchdog rebuilds it if no microphone audio arrives for 2 s,
///  - while the microphone is down the wall clock drives the timeline (system audio + silence),
///    so the other side of the call is still recorded and auto-pause keeps working.
public final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onLevel: ((Float) -> Void)?
    /// Called on a background queue when recording pauses/resumes. `auto` = triggered by silence detection.
    public var onPauseChange: ((_ paused: Bool, _ auto: Bool) -> Void)?
    /// Called on a background queue when the microphone stops delivering audio (`false`) and when it recovers (`true`).
    public var onMicrophoneHealth: ((_ ok: Bool) -> Void)?
    public static let autoPauseSeconds: Double = 30
    public private(set) var systemAudioActive = false
    /// Why system audio isn't being captured (nil when it is, or when it wasn't requested).
    public private(set) var systemAudioProblem: SystemAudioProblem?

    public enum SystemAudioProblem { case permissionDenied, failed(String) }

    static let micStallSeconds = 2.0
    static let sysStallSeconds = 3.0
    static let restartIntervalSeconds = 4.0

    // Microphone engine; touched only on `controlQueue`.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var micRestartScheduled = false

    private let micQueue = SampleQueue()
    private let sysQueue = SampleQueue()
    private let sysResampler = PCMResampler()
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var stream: SCStream?
    private var tap: AnyObject?   // SystemAudioTap (macOS 14.2+); touched on `controlQueue` after start
    private var tapWanted = false
    private var wakeObserver: NSObjectProtocol?
    private let writeQueue = DispatchQueue(label: "hypernote2.recorder.write")
    private let controlQueue = DispatchQueue(label: "hypernote2.recorder.control")
    private let sysQueueGCD = DispatchQueue(label: "hypernote2.recorder.system")

    // State owned by `writeQueue`.
    private var framesWritten = 0
    private var pauseLogic: PauseLogic
    /// Audio from just before an auto-resume, so the first words aren't cut off.
    private var preRoll: [[Float]] = []
    private var lastFlush = uptimeSeconds()
    private var micHealthy = true
    private var lastMicRecovery = 0.0
    private var lastSysRecovery = 0.0

    private let statsLock = NSLock()
    private var recordedFrames = 0
    private var active = false

    public init(autoPause: Bool = true) {
        pauseLogic = PauseLogic(autoPauseEnabled: autoPause, autoPauseSeconds: Self.autoPauseSeconds)
        super.init()
    }

    private var isActive: Bool {
        get { statsLock.lock(); defer { statsLock.unlock() }; return active }
        set { statsLock.lock(); active = newValue; statsLock.unlock() }
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
        isActive = true

        do {
            try controlQueue.sync { try self.startMicEngine() }
        } catch {
            isActive = false
            file = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }

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

        // Sleep stops Core Audio IO; rebuild everything on wake instead of waiting for the watchdog.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            recorderLog.notice("Woke from sleep; restarting audio inputs")
            self?.requestMicRestart(after: 1.0)
            self?.requestSystemAudioRestart(after: 1.0)
        }

        writeQueue.sync { lastFlush = uptimeSeconds() }
        let t = DispatchSource.makeTimerSource(queue: writeQueue)
        t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    /// Stops capture, flushes remaining audio and returns the recorded duration in seconds.
    public func stop() async -> Double {
        isActive = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        timer?.cancel()
        timer = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            controlQueue.async {
                self.stopMicEngine()
                self.stopTap()
                c.resume()
            }
        }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await withCheckedContinuation { (c: CheckedContinuation<Double, Never>) in
            writeQueue.async {
                self.flush(final: true)
                self.file = nil   // closing the file finalizes the m4a
                c.resume(returning: Double(self.framesWritten) / 16_000)
            }
        }
    }

    // MARK: Microphone engine (controlQueue)

    /// Builds a fresh engine for the current default input. A new `AVAudioEngine` is used every
    /// time: after a device change the old one often refuses to restart (HAL error 35).
    private func startMicEngine() throws {
        stopMicEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw HypernoteError.message("No microphone input available.")
        }
        let resampler = PCMResampler()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.micQueue.append(resampler.convert(buffer))
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            recorderLog.notice("Audio engine configuration changed (input device switched); restarting microphone")
            self?.requestMicRestart(after: 0.5)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        configObserver = observer
        micQueue.markAlive()
        recorderLog.notice("Microphone started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    private func stopMicEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Coalesces restart requests (config changes often arrive in bursts).
    private func requestMicRestart(after delay: Double) {
        controlQueue.async {
            guard self.isActive, !self.micRestartScheduled else { return }
            self.micRestartScheduled = true
            self.controlQueue.asyncAfter(deadline: .now() + delay) {
                self.micRestartScheduled = false
                guard self.isActive else { return }
                do { try self.startMicEngine() }
                catch { recorderLog.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)") }
                // On failure the watchdog in flush() tries again.
            }
        }
    }

    private func requestSystemAudioRestart(after delay: Double) {
        controlQueue.asyncAfter(deadline: .now() + delay) {
            guard self.isActive, self.tapWanted else { return }
            if #available(macOS 14.2, *) {
                self.stopTap()
                do {
                    try self.startTap()
                    self.sysQueue.markAlive()
                    recorderLog.notice("System audio tap restarted")
                } catch {
                    recorderLog.error("System audio restart failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: Writing (writeQueue)

    private func flush(final: Bool = false) {
        guard file != nil else { return }
        let now = uptimeSeconds()
        let elapsedFrames = min(32_000, max(0, Int((now - lastFlush) * 16_000)))
        lastFlush = now

        if !final { watchdog(now: now) }

        var n = micQueue.count
        if n == 0 && !micHealthy {
            // Microphone is down: let the wall clock drive the timeline so system audio is still
            // recorded (and silence detection keeps running) until the microphone is back.
            n = elapsedFrames
        }
        guard n > 0 else { return }
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

    private func watchdog(now: Double) {
        let micSilentFor = micQueue.secondsSinceLastAppend(now: now)
        let healthy = micSilentFor < Self.micStallSeconds
        if healthy != micHealthy {
            micHealthy = healthy
            if healthy { recorderLog.notice("Microphone audio is flowing again") }
            else { recorderLog.error("No microphone audio for \(micSilentFor, privacy: .public) s") }
            onMicrophoneHealth?(healthy)
        }
        if !healthy && now - lastMicRecovery >= Self.restartIntervalSeconds {
            lastMicRecovery = now
            requestMicRestart(after: 0)
        }
        // The tap delivers buffers continuously (silence included), so a gap means it died —
        // typically because its clock device (e.g. AirPods) went away.
        if tapWanted && sysQueue.secondsSinceLastAppend(now: now) > Self.sysStallSeconds
            && now - lastSysRecovery >= Self.restartIntervalSeconds {
            lastSysRecovery = now
            sysQueue.markAlive(now: now)
            requestSystemAudioRestart(after: 0)
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
            recorderLog.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
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
            try controlQueue.sync { try self.startTap() }
            sysQueue.markAlive()
            tapWanted = true
        } else {
            try await startScreenCaptureAudio()
        }
    }

    /// controlQueue only.
    @available(macOS 14.2, *)
    private func startTap() throws {
        let tap = SystemAudioTap()
        let resampler = PCMResampler()
        try tap.start { [weak self] pcm in
            guard let self else { return }
            self.sysQueue.append(resampler.convert(pcm))
        }
        self.tap = tap
    }

    /// controlQueue only.
    private func stopTap() {
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
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
