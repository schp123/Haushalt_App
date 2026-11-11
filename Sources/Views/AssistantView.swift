import SwiftUI
import SwiftData

/// Sprach-Assistent: Text (diktiert mit Wispr Flow oder der iPhone-Diktierfunktion) → OmniRoute → Aktionen.
struct AssistantView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    struct Turn: Identifiable {
        let id = UUID()
        var text: String
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

    private var configured: Bool { AssistantConfig.load().isConfigured }

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
                                    .id("busy")
                            }
                            if let error {
                                Text(error).font(.system(size: 14)).foregroundStyle(Theme.warnText).card(14, radius: 18)
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: turns.count) { _, _ in
                        if let id = turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    }
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
            .onAppear {
                speech.onFinished = { text in
                    input = text
                    send()
                }
                // Direkt zuhören, sobald der Assistent aufgeht
                if configured { Task { await speech.start() } } else { showSettings = true }
            }
            .onDisappear { speech.stop() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sag einfach, was zu tun ist").font(.system(size: 20, weight: .heavy))
            Text("Tippe auf das Mikrofon und sprich – nach einer kurzen Pause wird automatisch gesendet. Tippen geht natürlich auch (auch mit Wispr Flow).")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["„Milch ist leer, Eier haben wir noch vier“",
                         "„Setz zwei Zitronen und Backpapier auf die Liste“",
                         "„Neues Produkt Waschmittel vom Biomarkt, 60 Wäschen, wir brauchen 6 pro Woche“",
                         "„Rosmarinöl von Amazon auf die Wunschliste, bis Ende des Monats“",
                         "„Mittags hatte ich die Hähnchen-Bowl“",
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
            if !t.reply.isEmpty || !t.done.isEmpty || !t.failed.isEmpty || !t.pendingDeletes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !t.reply.isEmpty {
                        Text(t.reply).font(.system(size: 15, weight: .medium))
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
            if speech.isListening {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.warn)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(speech.transcript.isEmpty ? "Ich höre zu …" : speech.transcript)
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
                speech.toggle()
            } label: {
                Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(speech.isListening ? Theme.warn : Theme.ink, in: Circle())
            }
            .disabled(!configured || busy)
            .accessibilityLabel(speech.isListening ? "Zuhören beenden" : "Sprechen")
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

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""
        error = nil
        turns.append(Turn(text: text))
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let (result, raw) = try await Assistant.run(text, history: history, context: context)
                if let i = turns.indices.last {
                    turns[i].reply = result.reply
                    turns[i].done = result.done
                    turns[i].failed = result.failed
                    turns[i].pendingDeletes = result.pendingDeletes
                    if result.reply.isEmpty && result.done.isEmpty && result.failed.isEmpty && result.pendingDeletes.isEmpty {
                        turns[i].reply = "Erledigt."
                    }
                }
                history.append(ChatMessage(role: "user", content: text))
                history.append(ChatMessage(role: "assistant", content: raw))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
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

    var body: some View {
        Form {
            Section {
                TextField("Adresse, z. B. http://192.168.1.20:20128/v1", text: $config.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API-Key (falls gesetzt)", text: $config.apiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Modell(e), z. B. gemini-3.8-flash, gemini-3.5-flash", text: $config.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("KI-Verbindung")
            } footer: {
                Text("Jede OpenAI-kompatible Schnittstelle geht – z. B. Gemini (https://generativelanguage.googleapis.com/v1beta/openai) oder OmniRoute. Mehrere Modelle mit Komma trennen: Ist eins überlastet, nimmt die App automatisch das nächste. Die Daten bleiben nur auf diesem iPhone.")
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
                Text("Diktieren: In den Assistenten tippen, dann in der Tastatur auf Wispr Flow wechseln (Globus-Taste) und sprechen. Die normale iPhone-Diktierfunktion (Mikrofon unten rechts) geht genauso.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            } header: {
                Text("Sprache")
            }
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
