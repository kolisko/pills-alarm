import AVFoundation
import AlarmKit
import UIKit
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

    func testCacheSurvivesRecreationAndReusesCompletedAudio() async throws {
        let directory = temporaryDirectory()
        let renderer = StubSpeechRenderer()
        let content = AlarmSpeechContent(lines: ["Půl tablety Ospolut."])
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let name = try await cache.soundName(for: content)
        let recreated = AlarmAudioCache(directory: directory, renderer: renderer)
        let reused = try await recreated.soundName(for: content)
        XCTAssertEqual(name, reused)
        XCTAssertEqual(renderer.calls, 1)
        let changed = AlarmSpeechContent(lines: ["Jedna tableta Ospolut."])
        let changedName = try await cache.soundName(for: changed)
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
            _ = try await cache.soundName(for: content)
            XCTFail("Expected failure")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        renderer.fail = false
        let name = try await cache.soundName(for: content)
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent(name))
        _ = try await cache.soundName(for: content)
        XCTAssertEqual(renderer.calls, 3)
    }

    func testSpeechCanFinishAfterFormerEightSecondLimit() async throws {
        let renderer = StubSpeechRenderer()
        renderer.delay = .seconds(8.1)
        let directory = temporaryDirectory()
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let name = try await cache.soundName(for: .test)
        XCTAssertEqual(renderer.calls, 1)
        XCTAssertGreaterThan(try AVAudioFile(forReading: directory.appendingPathComponent(name)).length, 0)
    }

    func testCancellingSpeechDiscardsIncompleteAudioAndAllowsRetry() async throws {
        let renderer = StubSpeechRenderer()
        renderer.delay = .seconds(30)
        let directory = temporaryDirectory()
        let cache = AlarmAudioCache(directory: directory, renderer: renderer)
        let task = Task { try await cache.soundName(for: .test) }
        while renderer.calls == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled speech must not become reusable")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        renderer.delay = nil
        _ = try await cache.soundName(for: .test)
        XCTAssertEqual(renderer.calls, 2)
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
        let name = try await cache.soundName(for: content)
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        let reused = try await cache.soundName(for: content)
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
    var delay: Duration?

    func render(_ content: AlarmSpeechContent, to url: URL) async throws {
        calls += 1
        if let delay { try await Task.sleep(for: delay) }
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

@MainActor
final class AlarmSchedulingBenchmarkTests: XCTestCase {
    func testColdAndReusedAudioWithSixtyRealAlarms() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PILLCARE_ALARM_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in timing benchmark; needs AlarmKit permission in an isolated simulator")
        }
        guard #available(iOS 26.0, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        await NotificationScheduler.shared.waitForPendingOperations()
        guard try AlarmManager.shared.alarms.isEmpty else { throw XCTSkip("Existing alarms must be preserved") }

        let suite = "AlarmBenchmark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        let renderer = SystemAlarmSpeechRenderer()
        let measured = MeasuredAlarmSounds(directory: directory, renderer: renderer)
        let scheduler = NotificationScheduler(defaults: defaults, alarmSounds: measured, removeLegacyNotifications: {})
        await scheduler.setAlarmsEnabled(true) { [] }
        guard scheduler.alarmsEnabled else {
            XCTFail("Allow AlarmKit in the isolated simulator before running the benchmark")
            return
        }
        scheduler.soundMode = .spoken

        let groupsStart = ContinuousClock.now
        let groups = benchmarkGroups()
        let groupingSeconds = groupsStart.duration(to: .now).secondsValue
        guard let voice = renderer.voiceIdentifier else { throw AlarmAudioError.voiceUnavailable }
        let names = Set(groups.map { AlarmSpeechContent(group: $0).fileName(voiceIdentifier: voice) })
        // Only this fixture's files are cleared; the benchmark refuses to run with existing alarms.
        for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        defer {
            for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }

        var rows: [[String: Any]] = []
        var failure: Error?
        do {
            for label in ["cold", "reuse_1", "reuse_2", "reuse_3", "tone_baseline"] {
                if label == "tone_baseline" { scheduler.soundMode = .tone }
                measured.reset()
                let start = ContinuousClock.now
                try await scheduler.rescheduleAlarmGroups(groups).value
                let elapsed = start.duration(to: .now).secondsValue
                let actualCount = try AlarmManager.shared.alarms.count
                XCTAssertEqual(actualCount, 60)
                if label != "tone_baseline" {
                    XCTAssertEqual(measured.failures, 0, "Every alarm must receive speech in the same pass")
                    if label == "cold" { XCTAssertEqual(measured.generated, names.count) }
                }
                rows.append([
                    "pass": label, "alarms": actualCount, "total_seconds": elapsed,
                    "audio_seconds": measured.seconds, "cache_hits": measured.hits,
                    "generated_files": measured.generated, "tone_fallbacks": measured.failures
                ])
            }
        } catch { failure = error }
        await scheduler.setAlarmsEnabled(false) { [] }
        XCTAssertTrue(try AlarmManager.shared.alarms.isEmpty)

        var report: [String: Any] = [
            "ios": UIDevice.current.systemVersion,
            "simulator": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
            "alarm_count": groups.count, "medications_per_alarm": 3, "unique_audio_contents": names.count,
            "fixture_seconds": groupingSeconds, "voice": voice, "passes": rows
        ]
        if let failure { report["error"] = failure.localizedDescription }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("ALARM_BENCHMARK\n\(String(decoding: data, as: UTF8.self))")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Alarm scheduling benchmark"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let failure { throw failure }
#else
        throw XCTSkip("Use an isolated simulator")
#endif
    }

    private func benchmarkGroups() -> [ScheduledDoseAlarmGroup] {
        let requested = Int(ProcessInfo.processInfo.environment["PILLCARE_BENCHMARK_UNIQUE_CONTENTS"] ?? "6") ?? 6
        let uniqueContents = min(60, max(1, requested))
        return (0..<60).map { index in
            let profile = index % uniqueContents
            let date = Date().addingTimeInterval(3_600 + Double(index * 900))
            let amounts = ["½", "1", "1 ½", "2", "¼", "¾"]
            let entries: [(String, String, MedicationForm)] = [
                ("Ospolut", amounts[profile % amounts.count], .tablet), ("Trelema", profile % 6 < 3 ? "1" : "2", .tablet),
                ("Testovací sirup", "\(profile + 1)ml", .syrup)
            ]
            let alarms = entries.map { name, amount, form in
                let dose = GeneratedDose(
                    id: UUID().uuidString, baseEventId: "", workspaceId: "benchmark", isShared: false,
                    workspaceName: "", medicationId: UUID(), medicationName: name, medicationNote: "",
                    medicationColorHex: "", medicationForm: form, timeId: UUID(), timeLabel: "Test",
                    scheduledDate: date, scheduledTime: TimeOfDay(hour: 8, minute: 0), amount: amount, phaseTitle: "Test"
                )
                return ScheduledDoseAlarm(dose: dose, scheduledDate: date, repeatIndex: index / 6)
            }
            return ScheduledDoseAlarmGroup(scheduledDate: date, alarms: alarms)
        }
    }
}

@MainActor
private final class MeasuredAlarmSounds: AlarmSoundProviding {
    private let directory: URL
    private let renderer: any AlarmSpeechRendering
    private let cache: AlarmAudioCache
    private(set) var seconds = 0.0
    private(set) var hits = 0
    private(set) var generated = 0
    private(set) var failures = 0

    init(directory: URL, renderer: any AlarmSpeechRendering) {
        self.directory = directory
        self.renderer = renderer
        cache = AlarmAudioCache(directory: directory, renderer: renderer)
    }

    func reset() { seconds = 0; hits = 0; generated = 0; failures = 0 }

    func soundName(for content: AlarmSpeechContent) async throws -> String {
        let start = ContinuousClock.now
        defer { seconds += start.duration(to: .now).secondsValue }
        let name = content.fileName(voiceIdentifier: renderer.voiceIdentifier ?? "unavailable")
        let existed = FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        do {
            let result = try await cache.soundName(for: content)
            if existed { hits += 1 } else { generated += 1 }
            return result
        } catch {
            failures += 1
            throw error
        }
    }
}

private extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
