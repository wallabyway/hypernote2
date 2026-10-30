import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// "System Audio Recording Only" permission (kTCCServiceAudioCapture), used by Core Audio process taps.
/// There is no public API to query/request it, so — like hyprnote and AudioCap — we call into TCC.framework.
public enum SystemAudioPermission {
    public enum Status { case granted, denied, unknown }

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString

    public static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFunc.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Returns whether access is granted.
    public static func request() async -> Bool {
        switch status {
        case .granted: return true
        case .denied: return false
        case .unknown: break
        }
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(sym, to: RequestFunc.self)
        return await withCheckedContinuation { c in
            request(service, nil) { granted in c.resume(returning: granted) }
        }
    }

    public static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

/// Captures everything the Mac plays (Zoom, Meet, Teams…) via a Core Audio process tap (macOS 14.2+).
/// Needs only "System Audio Recording Only" permission — no Screen Recording.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hypernote2.recorder.tap", qos: .userInitiated)

    /// Called on a background queue with each buffer in the tap's native format.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        desc.uuid = UUID()
        desc.name = "Hypernote2 system audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        try getProperty(tapID, kAudioTapPropertyFormat, &asbd, "read tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw HypernoteError.message("Unsupported system audio format.")
        }

        var outputID = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                        &outputID, "find output device")
        var outputUID: CFString = "" as CFString
        try getProperty(outputID, kAudioDevicePropertyDeviceUID, &outputUID, "read output device UID")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hypernote2 Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  pcm.frameLength > 0 else { return }
            onBuffer(pcm)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Our own Core Audio process object, so the tap never records Hypernote2 itself.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ value: inout T, _ what: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), what)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            stop()
            throw HypernoteError.message("System audio: could not \(what) (OSStatus \(status)).")
        }
    }
}
