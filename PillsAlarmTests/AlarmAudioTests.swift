import AVFoundation
import XCTest
import PillCore
@testable import PillsAlarm

@MainActor
final class AlarmAudioTests: XCTestCase {
    func testSpeechIncludesAllDosesAndUsesCzechAmountsAndUnits() {
        let content = AlarmSpeechContent(group: group([
            dose("Ospolut", amount: "½"), dose("Trelema", amount: "1"),
            dose("Sirup", amount: "2,5ml", form: .syrup)
        ]))
        XCTAssertEqual(Set(content.lines), ["Půl tablety Ospolut.", "Jedna tableta Trelema.", "2,5 mililitru Sirup."])
        for (amount, expected) in [
            ("¼", "Čtvrt tablety"), ("¾", "Tři čtvrtě tablety"), ("1 ½", "Jedna a půl tablety"),
            ("2", "Dvě tablety"), ("5", "Pět tablet")
        ] {
            XCTAssertEqual(AlarmSpeechContent(group: group([dose("Lék", amount: amount)])).lines, ["\(expected) Lék."])
        }
        XCTAssertEqual(AlarmSpeechContent(group: group([dose("Sirup", amount: "1ml", form: .syrup)])).lines, ["Jeden mililitr Sirup."])
    }

    func testKeyIgnoresDatesIDsOrderAndPhaseNamesButTracksEverySpokenChange() {
        let first = dose("Ospolut", amount: "½")
        let second = dose("Trelema", amount: "1")
        let content = AlarmSpeechContent(group: group([first, second]))
        var tomorrow = first
        tomorrow.id = UUID().uuidString
        tomorrow.medicationId = UUID()
        tomorrow.scheduledDate = first.scheduledDate.addingTimeInterval(86_400)
        tomorrow.phaseTitle = "Další fáze"
        let equivalent = AlarmSpeechContent(group: group([second, tomorrow]))
        XCTAssertEqual(content.fileName(voiceIdentifier: "cs"), equivalent.fileName(voiceIdentifier: "cs"))
        XCTAssertNotEqual(content.fileName(voiceIdentifier: "cs"), content.fileName(voiceIdentifier: "other"))
        var changed = first
        changed.amount = "1"
        let changedDose = AlarmSpeechContent(group: group([changed, second]))
        XCTAssertNotEqual(content.fileName(voiceIdentifier: "cs"), changedDose.fileName(voiceIdentifier: "cs"))
        XCTAssertNotEqual(content.fileName(voiceIdentifier: "cs"), AlarmSpeechContent(group: group([first])).fileName(voiceIdentifier: "cs"))
        changed = first
        changed.medicationForm = .syrup
        XCTAssertNotEqual(content.fileName(voiceIdentifier: "cs"), AlarmSpeechContent(group: group([changed, second])).fileName(voiceIdentifier: "cs"))
        // Equal names never cause distinct doses to disappear.
        XCTAssertEqual(AlarmSpeechContent(group: group([first, first])).lines.count, 2)
    }

    func testCacheSurvivesRecreationAndWorksAfterGenerationBudgetExpires() async throws {
        let directory = temporaryDirectory()
        let renderer = StubSpeechRenderer()
        let content = AlarmSpeechContent(lines: ["Půl tablety Ospolut."])
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let name = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(1)))
        let recreated = AlarmAudioCache(directory: directory, renderer: renderer)
        let reused = try await recreated.soundName(for: content, deadline: .now.advanced(by: .seconds(-1)))
        XCTAssertEqual(name, reused)
        XCTAssertEqual(renderer.calls, 1)
        let changed = AlarmSpeechContent(lines: ["Jedna tableta Ospolut."])
        let changedName = try await cache.soundName(for: changed, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertNotEqual(changedName, name)
        XCTAssertEqual(renderer.calls, 2)
    }

    func testFailedAndCorruptFilesAreNotReused() async throws {
        let directory = temporaryDirectory()
        let renderer = StubSpeechRenderer()
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let content = AlarmSpeechContent(lines: ["Test."])
        renderer.fail = true
        do {
            _ = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(1)))
            XCTFail("Expected failure")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        renderer.fail = false
        let name = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(1)))
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent(name))
        _ = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(renderer.calls, 3)
    }

    func testExpiredBudgetDoesNotStartSynthesis() async throws {
        let renderer = StubSpeechRenderer()
        let cache = AlarmAudioCache(directory: temporaryDirectory(), renderer: renderer)
        do {
            _ = try await cache.soundName(for: .test, deadline: .now.advanced(by: .seconds(-1)))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error.localizedDescription, AlarmAudioError.timedOut.localizedDescription) }
        XCTAssertEqual(renderer.calls, 0)
    }

    func testComposedAudioStartsWithOriginalBeepAndSeparatesEveryMedicationWithSilence() throws {
        let url = temporaryDirectory().appendingPathComponent("composed.caf")
        let beepURL = try XCTUnwrap(Bundle.main.url(forResource: "DoseAlarm", withExtension: "wav"))
        let first = AlarmSpeechSamples(values: [Float](repeating: 0.2, count: 4_410), sampleRate: 44_100)
        let second = AlarmSpeechSamples(values: [Float](repeating: 0.4, count: 2_205), sampleRate: 22_050)
        try AlarmAudioComposer.write(recordings: [first, second], beepURL: beepURL, to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 29.5, accuracy: 0.001)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let beepFile = try AVAudioFile(forReading: beepURL)
        let beep = AVAudioPCMBuffer(pcmFormat: beepFile.processingFormat, frameCapacity: 66_150)!
        try beepFile.read(into: beep)
        for index in stride(from: 0, to: 66_150, by: 101) {
            XCTAssertEqual(samples[index], beep.floatChannelData![0][index], accuracy: 0.0001)
        }
        let pause = Int(AlarmAudioComposer.pauseSeconds * 44_100)
        let speechStart = 66_150 + pause
        XCTAssertEqual(samples[speechStart - 100], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[speechStart + 100], 0.2, accuracy: 0.0001)
        XCTAssertEqual(samples[speechStart + 4_410 + 100], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[speechStart + 4_410 + pause + 300], 0.4, accuracy: 0.001)
    }

    func testLongListFallsBackAsAWholeInsteadOfTruncatingMedicationNames() throws {
        let url = temporaryDirectory().appendingPathComponent("too-long.caf")
        let beepURL = try XCTUnwrap(Bundle.main.url(forResource: "DoseAlarm", withExtension: "wav"))
        let recording = AlarmSpeechSamples(values: [Float](repeating: 0.2, count: 20 * 44_100), sampleRate: 44_100)
        XCTAssertThrowsError(try AlarmAudioComposer.write(recordings: [recording, recording], beepURL: beepURL, to: url)) {
            XCTAssertEqual($0.localizedDescription, AlarmAudioError.tooLong.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRealCzechSpeechRender() async throws {
        guard ProcessInfo.processInfo.environment["PILLCARE_SPEECH_SMOKE_TEST"] == "1" else {
            throw XCTSkip("Opt-in test of the installed Czech speech voice")
        }
        let renderer = SystemAlarmSpeechRenderer()
        XCTAssertNotNil(renderer.voiceIdentifier, "Install a Czech voice in the simulator")
        let content = AlarmSpeechContent(lines: ["Půl tablety Ospolutu.", "Jedna tableta Trelema."])
        let directory = temporaryDirectory()
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let name = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(8)))
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        let reused = try await cache.soundName(for: content, deadline: .now.advanced(by: .seconds(-1)))
        XCTAssertEqual(name, reused)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "Czech spoken alarm"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func dose(_ name: String, amount: String, form: MedicationForm = .tablet) -> GeneratedDose {
        GeneratedDose(
            id: UUID().uuidString, baseEventId: "", workspaceId: "", isShared: false, workspaceName: "",
            medicationId: UUID(), medicationName: name, medicationNote: "", medicationColorHex: "",
            medicationForm: form, timeId: UUID(), timeLabel: "Ráno", scheduledDate: Date(),
            scheduledTime: TimeOfDay(hour: 8, minute: 0), amount: amount, phaseTitle: "Fáze 1"
        )
    }

    private func group(_ doses: [GeneratedDose]) -> ScheduledDoseAlarmGroup {
        ScheduledDoseAlarmGroup(scheduledDate: Date(), alarms: doses.map {
            ScheduledDoseAlarm(dose: $0, scheduledDate: $0.scheduledDate, repeatIndex: 0)
        })
    }
}

@MainActor
private final class StubSpeechRenderer: AlarmSpeechRendering {
    var voiceIdentifier: String? = "test-czech-voice"
    var calls = 0
    var fail = false

    func render(_ content: AlarmSpeechContent, to url: URL, deadline: ContinuousClock.Instant) async throws {
        calls += 1
        if fail {
            try Data("partial render".utf8).write(to: url)
            throw AlarmAudioError.emptySpeech
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 100)
        try file.write(from: buffer)
    }
}
