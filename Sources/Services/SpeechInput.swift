import Foundation
import Speech
import AVFoundation
import Observation

/// Eingebaute Spracherkennung (Deutsch): zuhören und live mitschreiben, bis du selbst auf „Fertig“ tippst.
@MainActor
@Observable
final class SpeechInput {
    var transcript = ""
    var isListening = false
    var error: String?

    @ObservationIgnored var onFinished: ((String) -> Void)?
    /// iOS hat die Erkennung von sich aus beendet (z. B. Zeitlimit) – Text bleibt stehen, wird aber nicht gesendet.
    @ObservationIgnored var onInterrupted: ((String) -> Void)?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silence: Task<Void, Never>?

    func toggle() {
        if isListening { finish() } else { Task { await start() } }
    }

    func start() async {
        guard !isListening else { return }
        error = nil
        guard await Self.authorize() else {
            error = "Bitte Mikrofon und Spracherkennung für Kammer erlauben (iPhone-Einstellungen → Kammer)."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Spracherkennung ist gerade nicht verfügbar."
            return
        }
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(req))
            engine.prepare()
            try engine.start()
            isListening = true

            task = recognizer.recognitionTask(with: req, resultHandler: Self.resultHandler { [weak self] text, final, failed in
                guard let self, self.isListening else { return }
                if let text, !text.isEmpty { self.transcript = text }
                if final || failed { self.interrupted() }
            })
        } catch {
            self.error = "Das Mikrofon konnte nicht gestartet werden."
            stop()
        }
    }

    /// Zuhören beenden und den erkannten Text weitergeben.
    func finish() {
        guard isListening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onFinished?(text) }
    }

    private func interrupted() {
        guard isListening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onInterrupted?(text) }
    }

    /// Zuhören abbrechen, ohne etwas zu senden.
    func stop() {
        silence?.cancel()
        silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Hilfen außerhalb des Main Actors (Audio läuft auf eigenen Threads)

    nonisolated private static func tapBlock(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func resultHandler(
        _ handle: @escaping @MainActor (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in handle(text, final, failed) }
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
