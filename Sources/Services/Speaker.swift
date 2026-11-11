import Foundation
import AVFoundation

/// Sprachausgabe auf Deutsch (beste installierte Stimme).
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private var onDone: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String, then done: (() -> Void)? = nil) {
        stop()
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { done?(); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.bestGermanVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        onDone = done
        synth.speak(u)
    }

    func stop() {
        onDone = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private static var bestGermanVoice: AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    private func finished() {
        let done = onDone
        onDone = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        done?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}

/// Erkennt ein gesprochenes „Ja“ oder „Nein“ für die Freigabe.
enum VoiceConfirm {
    enum Answer { case yes, no }

    private static let yes = ["ja", "jap", "jo", "jawohl", "okay", "ok", "passt", "mach", "machs", "mach's", "genau",
                              "los", "ausführen", "bestätigt", "bestätigen", "richtig", "gerne", "klar", "yes"]
    private static let no = ["nein", "nö", "ne", "nee", "abbrechen", "stopp", "stop", "verwerfen", "falsch", "lass", "nicht"]

    static func detect(_ text: String) -> Answer? {
        let words = text.lowercased(with: Fmt.de)
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        if words.contains(where: { no.contains($0) }) { return .no }
        if words.contains(where: { yes.contains($0) }) { return .yes }
        return nil
    }
}
