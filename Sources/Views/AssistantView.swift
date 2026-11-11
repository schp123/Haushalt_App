import SwiftUI
import SwiftData

/// Sprach-Assistent: zuhören → verstehen → vorlesen → nach Freigabe (Knopf oder „Ja“) ausführen.
struct AssistantView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("assistant.speak") private var speakBack = true
    @AppStorage("assistant.confirm") private var confirmFirst = true

    enum Phase { case thinking, awaiting, done, discarded }

    struct Turn: Identifiable {
        let id = UUID()
        var text: String
        var state: Phase = .thinking
        var plan: AssistantPlan?
        var reply: String = ""
        var done: [String] = []
        var failed: [String] = []
        var pendingDeletes: [Product] = []
        var deletesConfirmed = false
    }

    @State private var input = ""
    @State private var turns: [Turn] = []
    @State private var history: [ChatMessage] = []
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false
    @FocusState private var focused: Bool
    @State private var speech = SpeechInput()
    /// Hört gerade auf „Ja“/„Nein“ für die Freigabe.
    @State private var confirming = false

    private var configured: Bool { AssistantConfig.load().isConfigured }
    private var awaitingIndex: Int? { turns.lastIndex { $0.state == .awaiting } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if turns.isEmpty { intro }
                            ForEach($turns) { $turn in
                                turnView($turn).id(turn.id)
                            }
                            if busy {
                                HStack(spacing: 8) { ProgressView(); Text("Denke nach …").foregroundStyle(Theme.muted) }
                                    .font(.system(size: 14))
                            }
                            if let error {
                                Text(error).font(.system(size: 14)).foregroundStyle(Theme.warnText).card(14, radius: 18)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(20)
                    }
                    .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: busy) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                inputBar
            }
            .background(Theme.ground)
            .navigationTitle("Assistent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { close() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Assistent einrichten")
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { AssistantSettingsView() }
            }
            .onAppear(perform: setUp)
            .onDisappear {
                speech.stop()
                Speaker.shared.stop()
            }
        }
    }

    // MARK: Teile

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sag einfach, was zu tun ist").font(.system(size: 20, weight: .heavy))
            Text("Sprich so lange du willst und tippe auf den roten Knopf, wenn du fertig bist. \(confirmFirst ? "Ich lese dir vor, was ich verstanden habe – mit „Ja“ oder per Knopf gibst du es frei." : "")")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["„Milch ist leer, Eier haben wir noch vier“",
                         "„Setz zwei Zitronen und Backpapier auf die Liste“",
                         "„Neues Produkt Waschmittel vom Biomarkt, 60 Wäschen, wir brauchen 6 pro Woche“",
                         "„Rosmarinöl von Amazon auf die Wunschliste, bis Ende des Monats“",
                         "„Was fehlt für Freitag?“"], id: \.self) { ex in
                    Button { input = String(ex.dropFirst().dropLast()); focused = true } label: {
                        Text(ex).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func turnView(_ turn: Binding<Turn>) -> some View {
        let t = turn.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 40)
                Text(t.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if t.state != .thinking {
                VStack(alignment: .leading, spacing: 8) {
                    if !t.reply.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(t.reply).font(.system(size: 15, weight: .medium))
                            Spacer(minLength: 0)
                            Button { Speaker.shared.speak(t.reply) } label: {
                                Image(systemName: "speaker.wave.2").font(.system(size: 15, weight: .semibold))
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Vorlesen")
                        }
                    }

                    if t.state == .awaiting, let plan = t.plan {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.descriptions, id: \.self) { d in
                                Label(d, systemImage: "circle.dotted")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Verwerfen") { discard() }
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.warnText)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.warnBorder, lineWidth: 2))
                            Button("Ausführen") { approve() }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                        if confirming {
                            Label("Sag „Ja“ oder „Nein“", systemImage: "waveform")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    if t.state == .discarded {
                        Label("Verworfen", systemImage: "xmark.circle")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    ForEach(t.done, id: \.self) { d in
                        Label(d, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    ForEach(t.failed, id: \.self) { f in
                        Label(f, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.warnText)
                    }
                    if !t.pendingDeletes.isEmpty && !t.deletesConfirmed {
                        Button(role: .destructive) {
                            Assistant.confirmDeletes(t.pendingDeletes, context: context)
                            turn.wrappedValue.deletesConfirmed = true
                            turn.wrappedValue.done.append("Gelöscht: \(t.pendingDeletes.map(\.name).joined(separator: ", "))")
                        } label: {
                            Text("Löschen bestätigen: \(t.pendingDeletes.map(\.name).joined(separator: ", "))")
                                .font(.system(size: 14, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.warnText)
                    }
                }
                .card(14, radius: 18)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if speech.isListening && !confirming {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.warn)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(speech.transcript.isEmpty ? "Ich höre zu … tippe auf den roten Knopf, wenn du fertig bist." : speech.transcript)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(speech.transcript.isEmpty ? Theme.muted : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Abbrechen") { speech.stop() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if let e = speech.error {
                Text(e).font(.system(size: 13)).foregroundStyle(Theme.warnText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    focused = false
                    if confirming {
                        // Während der Freigabe etwas anderes gesagt → als neuen Auftrag senden
                        confirming = false
                        if speech.transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                            speech.stop()
                            listen()
                        } else {
                            speech.finish()
                        }
                    } else if speech.isListening {
                        speech.finish()
                    } else {
                        listen()
                    }
                } label: {
                    Image(systemName: speech.isListening && !confirming ? "paperplane.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(speech.isListening && !confirming ? Theme.warn : Theme.ink, in: Circle())
                }
                .disabled(!configured || busy)
                .accessibilityLabel(speech.isListening ? "Fertig – senden" : "Sprechen")
                TextField(configured ? "Sprechen oder tippen …" : "Erst KI-Verbindung einrichten", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(canSend ? Theme.accent : Theme.line, in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.ground)
    }

    private var canSend: Bool { !busy && configured && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Ablauf

    private func setUp() {
        speech.onFinished = { text in
            input = text
            send()
        }
        speech.onInterrupted = { text in
            if confirming { return }
            input = text
            speech.error = "Aufnahme beendet – prüfen und mit dem Pfeil senden oder weitersprechen."
        }
        speech.onPartial = { text in
            guard confirming, let answer = VoiceConfirm.detect(text) else { return }
            stopConfirmListening()
            switch answer {
            case .yes: approve()
            case .no: discard()
            }
        }
        if configured { listen() } else { showSettings = true }
    }

    private func listen() {
        Speaker.shared.stop()
        Task { await speech.start() }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        // Neuer Auftrag statt Freigabe → offenen Vorschlag verwerfen
        if let i = awaitingIndex { turns[i].state = .discarded }
        input = ""
        error = nil
        turns.append(Turn(text: text))
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let plan = try await Assistant.plan(text, history: history, context: context)
                history.append(ChatMessage(role: "user", content: text))
                history.append(ChatMessage(role: "assistant", content: plan.raw))
                guard let i = turns.indices.last else { return }
                turns[i].plan = plan
                turns[i].reply = plan.reply
                if plan.actions.isEmpty {
                    turns[i].state = .done
                    if turns[i].reply.isEmpty { turns[i].reply = "Dazu habe ich nichts gefunden." }
                    say(turns[i].reply)
                } else if confirmFirst {
                    turns[i].state = .awaiting
                    let question = (plan.reply.isEmpty ? plan.descriptions.joined(separator: ", ") : plan.reply) + " Soll ich das machen?"
                    say(question) { startConfirmListening() }
                } else {
                    run(i)
                    say(turns[i].reply.isEmpty ? "Erledigt." : turns[i].reply)
                }
            } catch {
                if let i = turns.indices.last { turns[i].state = .done }
                self.error = error.localizedDescription
                say("Das hat leider nicht geklappt.")
            }
        }
    }

    private func run(_ i: Int) {
        guard let plan = turns[i].plan else { return }
        let result = Assistant.execute(plan, context: context, confirmDeletes: confirmFirst)
        turns[i].done = result.done
        turns[i].failed = result.failed
        turns[i].pendingDeletes = result.pendingDeletes
        turns[i].state = .done
    }

    private func approve() {
        guard let i = awaitingIndex else { return }
        stopConfirmListening()
        run(i)
        say(turns[i].failed.isEmpty ? "Erledigt." : "Erledigt, aber nicht alles hat geklappt.")
    }

    private func discard() {
        guard let i = awaitingIndex else { return }
        stopConfirmListening()
        turns[i].state = .discarded
        say("Okay, verworfen.")
    }

    private func startConfirmListening() {
        guard awaitingIndex != nil else { return }
        confirming = true
        Task { await speech.start() }
    }

    private func stopConfirmListening() {
        confirming = false
        if speech.isListening { speech.stop() }
    }

    private func say(_ text: String, then done: (() -> Void)? = nil) {
        if speakBack {
            Speaker.shared.speak(text, then: done)
        } else {
            done?()
        }
    }

    private func close() {
        speech.stop()
        Speaker.shared.stop()
        dismiss()
        if Router.shared.openCheckAfterAssistant {
            Router.shared.openCheckAfterAssistant = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                Router.shared.showCheck = true
            }
        }
    }
}

// MARK: - Einrichtung

struct AssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = AssistantConfig.load()
    @State private var testing = false
    @State private var testResult: String?
    @AppStorage("assistant.speak") private var speakBack = true
    @AppStorage("assistant.confirm") private var confirmFirst = true

    var body: some View {
        Form {
            Section {
                TextField("Adresse, z. B. https://generativelanguage.googleapis.com/v1beta/openai", text: $config.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API-Key", text: $config.apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Modell(e), z. B. gemini-3.8-flash, gemini-3.6-flash", text: $config.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("KI-Verbindung")
            } footer: {
                Text("Jede OpenAI-kompatible Schnittstelle geht – z. B. Gemini oder OmniRoute. Mehrere Modelle mit Komma trennen: Ist eins überlastet, nimmt die App automatisch das nächste. Die Daten bleiben nur auf diesem iPhone.")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Verbindung testen")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(!config.isConfigured || testing)
                if let testResult {
                    Text(testResult).font(.footnote)
                        .foregroundStyle(testResult.hasPrefix("✓") ? Theme.accent : Theme.warnText)
                        .textSelection(.enabled)
                }
            }

            Section {
                Toggle("Antworten vorlesen", isOn: $speakBack)
                NavigationLink {
                    VoicePickerView()
                } label: {
                    LabeledContent("Stimme", value: Speaker.selectedVoice?.name ?? "Standard")
                }
                Toggle("Vor dem Ausführen nachfragen", isOn: $confirmFirst)
            } header: {
                Text("Sprache")
            } footer: {
                Text("Mit Nachfragen liest der Assistent vor, was er verstanden hat. Freigeben mit „Ja“ (oder „passt“, „mach“) bzw. per Knopf, verwerfen mit „Nein“. Etwas anderes sagen = neuer Auftrag.")
            }
            .tint(Theme.accent)
        }
        .navigationTitle("Assistent einrichten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    config.save()
                    dismiss()
                }
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await AssistantClient.complete(
                [ChatMessage(role: "user", content: "Antworte nur mit: OK")], config: config)
            testResult = "✓ Verbindung steht – Antwort: \(reply.prefix(60))"
            config.save()
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }
}


// MARK: - Stimme wählen

struct VoicePickerView: View {
    @AppStorage("assistant.voice") private var voiceID = ""
    @AppStorage("assistant.rate") private var rate = 1.05

    var body: some View {
        let voices = Speaker.germanVoices
        List {
            Section {
                ForEach(voices, id: \.identifier) { v in
                    HStack(spacing: 12) {
                        Button {
                            voiceID = v.identifier
                            Speaker.shared.speak("Hallo, ich bin \(v.name). So klinge ich als dein Kammer-Assistent.")
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name).foregroundStyle(Theme.ink)
                                    Text("\(Speaker.qualityLabel(v)) · \(Speaker.regionLabel(v))")
                                        .font(.footnote).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if v.identifier == (Speaker.selectedVoice?.identifier ?? "") {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.bold)
                                }
                            }
                        }
                        Button {
                            let saved = voiceID
                            voiceID = v.identifier
                            Speaker.shared.speak("Hallo, ich bin \(v.name).") { voiceID = saved }
                        } label: {
                            Image(systemName: "play.circle").font(.system(size: 22))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Probehören")
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text("Antippen zum Auswählen")
            } footer: {
                Text("Natürlicher klingen die Stimmen „Premium“ und „Erweitert“. Mehr davon kannst du kostenlos laden: iPhone-Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch (z. B. Anna oder Helena, jeweils Premium). Danach erscheinen sie hier. Die Siri-Stimmen selbst gibt Apple für andere Apps nicht frei.")
            }

            Section("Sprechtempo") {
                Slider(value: $rate, in: 0.8...1.4, step: 0.05) {
                    Text("Tempo")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                Button("Probehören") { Speaker.shared.speak("Ich setze Milch auf leer und packe zwei Zitronen auf die Liste.") }
            }
        }
        .navigationTitle("Stimme")
        .navigationBarTitleDisplayMode(.inline)
    }
}
