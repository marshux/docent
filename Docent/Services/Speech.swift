import AVFoundation
import Observation
import Speech

/// Splits streamed text into whole sentences so each can be spoken as soon as it is complete.
struct SentenceChunker {
    private var buffer = ""

    /// Adds streamed text and returns any sentences that are now complete.
    mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = Self.sentenceEnd(in: buffer) {
            let sentence = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    /// Returns whatever is left once the stream has ended.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Index just past the first ".", "!" or "?" that is followed by whitespace.
    private static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next < text.endIndex, text[next].isWhitespace {
                return next
            }
            index = next
        }
        return nil
    }
}

enum AudioSession {
    /// One category for the whole conversation, so listening and speaking don't fight over the session.
    /// `.playAndRecord` also keeps replies audible when the ring/silent switch is on silent.
    static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

/// Reads the guide's reply aloud, sentence by sentence, while it is still streaming in.
@MainActor
@Observable
final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var chunker = SentenceChunker()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func feed(_ text: String) {
        for sentence in chunker.append(text) { speak(sentence) }
    }

    func finish() {
        if let rest = chunker.flush() { speak(rest) }
    }

    func stop() {
        chunker = SentenceChunker()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speak(_ sentence: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        synthesizer.speak(utterance) // queues behind anything already being spoken
        isSpeaking = true
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }
}

/// Turns the visitor's speech into text with Apple's on-device/cloud speech recognition.
@MainActor
@Observable
final class SpeechRecognizer {
    enum RecognizerError: LocalizedError {
        case notAuthorized
        case unavailable

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Docent needs microphone and speech recognition access. Turn them on in Settings."
            case .unavailable: "Speech recognition isn't available right now. You can type your question instead."
            }
        }
    }

    private(set) var transcript = ""
    private(set) var isListening = false

    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var hasFinalResult = false

    func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        return speechAllowed && micAllowed
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw RecognizerError.unavailable }
        tearDown()
        transcript = ""
        hasFinalResult = false
        try AudioSession.configure()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal == true || error != nil
            Task { @MainActor in
                if let text { self?.transcript = text }
                if finished { self?.hasFinalResult = true }
            }
        }
        isListening = true
    }

    /// Stops listening and returns what was heard. Waits briefly for the recogniser's last words.
    func stop() async -> String {
        guard isListening else { return transcript }
        isListening = false
        stopAudio()
        request?.endAudio()
        for _ in 0..<15 where !hasFinalResult {
            try? await Task.sleep(for: .milliseconds(100))
        }
        tearDown()
        return transcript
    }

    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func tearDown() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }
}
