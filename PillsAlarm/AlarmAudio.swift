import AVFoundation
import CryptoKit
import Foundation
import PillCore

enum AlarmSoundMode: String, CaseIterable, Identifiable {
    case tone, spoken

    var id: String { rawValue }
    var label: String { self == .tone ? "Pípání" : "Pípání a hlas" }
}

struct AlarmSpeechContent: Equatable, Sendable {
    let lines: [String]

    init(group: ScheduledDoseAlarmGroup) {
        // Sort by spoken content, never by the date or generated dose IDs. Keep all dose entries.
        let entries: [(name: String, line: String)] = group.alarms.map { alarm in
            let name = alarm.dose.medicationName
            let line = "\(Self.amount(alarm.dose.amount, form: alarm.dose.medicationForm)) \(name)."
            return (name: name, line: line)
        }
        let sorted = entries.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.line < rhs.line }
            return lhs.name < rhs.name
        }
        lines = sorted.map { $0.line }
    }

    init(lines: [String]) { self.lines = lines }

    func fileName(voiceIdentifier: String) -> String {
        // Bump this version whenever the sound, pauses, rate or wording changes.
        let components = ["pillcare-spoken-v2", voiceIdentifier] + lines
        let data = try! JSONEncoder().encode(components)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "PillCare-\(key).caf"
    }

    private static func amount(_ text: String, form: MedicationForm) -> String {
        let value = DoseAmountFormatter.value(from: text, for: form)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "cs_CZ")
        formatter.numberStyle = .spellOut
        func number(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        switch form {
        case .tablet:
            let whole = Int(value)
            let fraction = Int((value * 4).rounded()) % 4
            let wholeText = whole == 1 ? "jedna" : whole == 2 ? "dvě" : number(whole)
            if fraction != 0 {
                let part = ["", "čtvrt", "půl", "tři čtvrtě"][fraction]
                return (whole == 0 ? "\(part) tablety" : "\(wholeText) a \(part) tablety").capitalizedFirst
            }
            let unit = whole == 1 ? "tableta" : (2...4).contains(whole) ? "tablety" : "tablet"
            return "\(wholeText) \(unit)".capitalizedFirst
        case .syrup:
            if value.rounded() == value {
                let whole = Int(value)
                let unit = whole == 1 ? "mililitr" : (2...4).contains(whole) ? "mililitry" : "mililitrů"
                return "\(number(whole)) \(unit)".capitalizedFirst
            }
            // Let the Czech voice read the decimal; expand the abbreviation explicitly.
            let decimal = String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
            return "\(decimal) mililitru"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

@MainActor
protocol AlarmSoundProviding {
    func soundName(for content: AlarmSpeechContent) async throws -> String
}

@MainActor
protocol AlarmSpeechRendering {
    var voiceIdentifier: String? { get }
    func render(_ content: AlarmSpeechContent, to url: URL) async throws
}

@MainActor
final class AlarmAudioCache: AlarmSoundProviding {
    private let directory: URL
    private let renderer: any AlarmSpeechRendering

    init(directory: URL? = nil, renderer: (any AlarmSpeechRendering)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        self.renderer = renderer ?? SystemAlarmSpeechRenderer()
    }

    func soundName(for content: AlarmSpeechContent) async throws -> String {
        try Task.checkCancellation()
        guard let voice = renderer.voiceIdentifier else { throw AlarmAudioError.voiceUnavailable }
        let name = content.fileName(voiceIdentifier: voice)
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path),
           let file = try? AVAudioFile(forReading: destination), file.length > 0 { return name }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await renderer.render(content, to: temporary)
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: temporary)
        guard file.length > 0 else { throw AlarmAudioError.emptySpeech }
        // A failed or interrupted render must never become a reusable cache entry.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path
        )
        var excluded = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return name
    }
}

enum AlarmAudioError: LocalizedError {
    case voiceUnavailable, emptySpeech, invalidAudio, tooLong

    var errorDescription: String? {
        switch self {
        case .voiceUnavailable: "Český hlas není na zařízení dostupný."
        case .emptySpeech: "Nepodařilo se vytvořit hlasové hlášení."
        case .invalidAudio: "Zvuk hlasového alarmu se nepodařilo zpracovat."
        case .tooLong: "Celé hlasové hlášení se nevejde do zvuku alarmu."
        }
    }
}

@MainActor
final class SystemAlarmSpeechRenderer: AlarmSpeechRendering {
    private var synthesizer: AVSpeechSynthesizer?
    private lazy var voice = AVSpeechSynthesisVoice(language: "cs-CZ")
    var voiceIdentifier: String? { voice?.identifier }

    func render(_ content: AlarmSpeechContent, to url: URL) async throws {
        guard let voice else { throw AlarmAudioError.voiceUnavailable }
        guard !content.lines.isEmpty else { throw AlarmAudioError.emptySpeech }
        var recordings: [AlarmSpeechSamples] = []
        for line in content.lines {
            try Task.checkCancellation()
            recordings.append(try await synthesize(line, voice: voice))
        }
        guard let beepURL = Bundle.main.url(forResource: "DoseAlarm", withExtension: "wav") else {
            throw AlarmAudioError.invalidAudio
        }
        try AlarmAudioComposer.write(recordings: recordings, beepURL: beepURL, to: url)
    }

    private func synthesize(
        _ text: String, voice: AVSpeechSynthesisVoice
    ) async throws -> AlarmSpeechSamples {
        // Create lazily: the existing tone mode never initializes the speech engine.
        let engine: AVSpeechSynthesizer
        if let synthesizer { engine = synthesizer } else {
            engine = AVSpeechSynthesizer()
            synthesizer = engine
        }
        let collector = AlarmSpeechCollector()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.48
        return try await withTaskCancellationHandler {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    collector.start(continuation)
                    engine.write(utterance) { buffer in collector.append(buffer) }
                }
            } catch {
                engine.stopSpeaking(at: .immediate)
                throw error
            }
        } onCancel: {
            collector.finish(.failure(CancellationError()))
        }
    }
}

struct AlarmSpeechSamples: Sendable {
    let values: [Float]
    let sampleRate: Double
}

// AVSpeechSynthesizer invokes its buffer callback off the main actor. All mutable state is locked.
private final class AlarmSpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double?
    private var result: Result<AlarmSpeechSamples, Error>?
    private var continuation: CheckedContinuation<AlarmSpeechSamples, Error>?

    func start(_ continuation: CheckedContinuation<AlarmSpeechSamples, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func append(_ buffer: AVAudioBuffer) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            lock.unlock()
            finish(.failure(AlarmAudioError.invalidAudio))
            return
        }
        if pcm.frameLength == 0 {
            let audio = AlarmSpeechSamples(values: samples, sampleRate: sampleRate ?? 0)
            lock.unlock()
            finish(audio.values.isEmpty ? .failure(AlarmAudioError.emptySpeech) : .success(audio))
            return
        }
        guard pcm.format.channelCount == 1, let channel = pcm.floatChannelData?[0],
              sampleRate == nil || sampleRate == pcm.format.sampleRate else {
            lock.unlock()
            finish(.failure(AlarmAudioError.invalidAudio))
            return
        }
        sampleRate = pcm.format.sampleRate
        guard Double(samples.count + Int(pcm.frameLength)) / pcm.format.sampleRate < 30 else {
            lock.unlock()
            finish(.failure(AlarmAudioError.tooLong))
            return
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        lock.unlock()
    }

    func finish(_ result: Result<AlarmSpeechSamples, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum AlarmAudioComposer {
    static let sampleRate = 44_100.0
    // The original sound's first three beeps finish before 0.8 s. At 1.5 s,
    // the next group is already sounding and would be cut off mid-beep.
    static let beepSeconds = 0.8
    static let pauseSeconds = 0.45
    static let durationSeconds = 29.5

    static func write(recordings: [AlarmSpeechSamples], beepURL: URL, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let beepFile = try AVAudioFile(forReading: beepURL)
        guard beepFile.processingFormat == format else { throw AlarmAudioError.invalidAudio }
        let beepBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * beepSeconds))!
        try beepFile.read(into: beepBuffer)
        guard beepBuffer.frameLength > 0 else { throw AlarmAudioError.invalidAudio }
        let beep = Array(UnsafeBufferPointer(start: beepBuffer.floatChannelData![0], count: Int(beepBuffer.frameLength)))
        let pause = [Float](repeating: 0, count: Int(sampleRate * pauseSeconds))
        let beepPhrase = beep + pause
        var cycle = beepPhrase
        for recording in recordings {
            cycle += try resample(recording, format: format)
            cycle += pause
        }
        let frameCount = Int(sampleRate * durationSeconds)
        guard !recordings.isEmpty, cycle.count <= frameCount else { throw AlarmAudioError.tooLong }
        // Repeat complete spoken lists, separated by the original beeps. Never cut off a medication.
        var samples: [Float] = []
        while samples.count + cycle.count <= frameCount { samples += cycle }
        // Fill the remainder with complete beep phrases, including their pause.
        // Leave the final fraction silent instead of cutting off another beep.
        while samples.count + beepPhrase.count <= frameCount { samples += beepPhrase }
        samples += [Float](repeating: 0, count: frameCount - samples.count)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        output.frameLength = AVAudioFrameCount(frameCount)
        samples.withUnsafeBufferPointer { output.floatChannelData![0].update(from: $0.baseAddress!, count: frameCount) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: output)
    }

    private static func resample(_ audio: AlarmSpeechSamples, format: AVAudioFormat) throws -> [Float] {
        guard !audio.values.isEmpty, audio.sampleRate > 0 else { throw AlarmAudioError.emptySpeech }
        if audio.sampleRate == sampleRate { return audio.values }
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1)!
        let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(audio.values.count))!
        input.frameLength = input.frameCapacity
        audio.values.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: audio.values.count)
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw AlarmAudioError.invalidAudio }
        let capacity = AVAudioFrameCount(ceil(Double(audio.values.count) * sampleRate / audio.sampleRate)) + 32
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { throw error ?? AlarmAudioError.invalidAudio }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
