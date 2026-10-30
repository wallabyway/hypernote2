import XCTest
@testable import HypernoteCore

final class PauseLogicTests: XCTestCase {
    private let chunk = 4_000            // 250 ms at 16 kHz
    private let quiet: Float = 0.001
    private let speech: Float = 0.08

    private func feed(_ logic: inout PauseLogic, rms: Float, seconds: Double) -> [PauseLogic.Event] {
        (0..<Int(seconds * 4)).map { _ in logic.process(rms: rms, frames: chunk) }.filter { $0 != .none }
    }

    func testAutoPausesAfter30SecondsOfSilence() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        XCTAssertEqual(feed(&logic, rms: speech, seconds: 5), [])
        XCTAssertEqual(feed(&logic, rms: quiet, seconds: 29.5), [])
        XCTAssertFalse(logic.isPaused)
        XCTAssertEqual(feed(&logic, rms: quiet, seconds: 0.5), [.autoPaused])
        XCTAssertTrue(logic.isPaused)
    }

    func testSpeechResetsTheSilenceCountdown() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        _ = feed(&logic, rms: quiet, seconds: 25)
        _ = feed(&logic, rms: speech, seconds: 1)
        XCTAssertEqual(feed(&logic, rms: quiet, seconds: 25), [])
        XCTAssertFalse(logic.isPaused)
    }

    func testAutoResumesOnSpeechButNotOnASingleClick() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        _ = feed(&logic, rms: quiet, seconds: 30)
        XCTAssertTrue(logic.autoPaused)
        XCTAssertEqual(logic.process(rms: speech, frames: chunk), .none)    // one blip
        _ = feed(&logic, rms: quiet, seconds: 2)
        XCTAssertTrue(logic.isPaused)
        XCTAssertEqual(feed(&logic, rms: speech, seconds: 0.5), [.autoResumed])
        XCTAssertFalse(logic.isPaused)
    }

    func testManualPauseIsNotAutoResumed() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        logic.pause()
        XCTAssertEqual(feed(&logic, rms: speech, seconds: 3), [])
        XCTAssertTrue(logic.isPaused)
        logic.resume()
        XCTAssertFalse(logic.isPaused)
    }

    func testManualResumeRestartsCountdown() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        _ = feed(&logic, rms: quiet, seconds: 30)
        logic.resume()
        XCTAssertEqual(feed(&logic, rms: quiet, seconds: 29), [])
        XCTAssertFalse(logic.isPaused)
    }

    func testDisabledAutoPauseNeverPauses() {
        var logic = PauseLogic(autoPauseEnabled: false, autoPauseSeconds: 30)
        XCTAssertEqual(feed(&logic, rms: quiet, seconds: 120), [])
        XCTAssertFalse(logic.isPaused)
    }

    func testSteadyBackgroundNoiseCountsAsSilence() {
        var logic = PauseLogic(autoPauseEnabled: true, autoPauseSeconds: 30)
        XCTAssertEqual(feed(&logic, rms: 0.006, seconds: 30), [.autoPaused])   // fan/hum below threshold
    }

    func testOldSettingsFileKeepsValuesAndDefaultsAutoPauseOn() throws {
        let json = #"{"captureSystemAudio":false,"defaultTemplateId":"x","deepseekModel":"m"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(Settings.self, from: json)
        XCTAssertFalse(s.captureSystemAudio)
        XCTAssertEqual(s.defaultTemplateId, "x")
        XCTAssertTrue(s.autoPause)
    }
}
