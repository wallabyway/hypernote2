import AVFoundation
import Foundation

/// Plays a note's recording natively (the web view can't read files in Application Support).
/// Reports position to the UI so the transcript can follow along.
@MainActor
final class AudioPlayback: NSObject, AVAudioPlayerDelegate {
    /// Called with `{id, playing, position, duration}` whenever playback state changes, and ~5×/s while playing.
    var onUpdate: (([String: Any]) -> Void)?
    private var player: AVAudioPlayer?
    private(set) var sessionId: String?
    private var timer: Timer?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Starts (or continues) playback of `url`. `at` seeks first; nil keeps the current position.
    func play(id: String, url: URL, at seconds: Double?) throws {
        if sessionId != id || player == nil {
            stop()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            sessionId = id
        }
        guard let player else { return }
        if let seconds { player.currentTime = clamp(seconds, player) }
        else if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        startTimer()
        report()
    }

    func pause() {
        player?.pause()
        stopTimer()
        report()
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = clamp(seconds, player)
        report()
    }

    func stop() {
        let id = sessionId
        player?.stop()
        player = nil
        sessionId = nil
        stopTimer()
        if let id { onUpdate?(["id": id, "playing": false, "position": 0, "duration": 0, "stopped": true]) }
    }

    func state() -> [String: Any] {
        guard let player, let sessionId else { return ["id": NSNull(), "playing": false, "position": 0, "duration": 0] }
        return ["id": sessionId, "playing": player.isPlaying, "position": player.currentTime, "duration": player.duration]
    }

    private func clamp(_ s: Double, _ p: AVAudioPlayer) -> Double { max(0, min(s, max(0, p.duration - 0.05))) }

    private func report() { onUpdate?(state()) }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.report()
        }
    }
}
