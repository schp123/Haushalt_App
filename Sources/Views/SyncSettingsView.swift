import SwiftUI
import CoreImage.CIFilterBuiltins

/// Gemeinsame Nutzung: Supabase verbinden, Haushalt anlegen oder per QR-Code beitreten.
struct SyncSettingsView: View {
    private let engine = SyncEngine.shared

    @State private var url = ""
    @State private var key = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showScanner = false
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            if let config = engine.config {
                connectedSections(config)
            } else {
                setupSections
            }
        }
        .navigationTitle("Gemeinsam nutzen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            BarcodeScannerView(symbologies: [.qr]) { value in
                showScanner = false
                code = value
                Task { await join() }
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Verbindung trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Trennen", role: .destructive) { engine.disconnect() }
        } message: {
            Text("Die Daten bleiben auf diesem iPhone, werden aber nicht mehr abgeglichen.")
        }
    }

    // MARK: Verbunden

    @ViewBuilder
    private func connectedSections(_ config: SyncConfig) -> some View {
        Section {
            HStack {
                Image(systemName: engine.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(engine.lastError == nil ? Theme.accent : Theme.warnText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.lastError == nil ? "Synchronisiert" : "Problem beim Abgleich").fontWeight(.semibold)
                    if let e = engine.lastError {
                        Text(e).font(.footnote).foregroundStyle(Theme.warnText)
                    } else if let d = engine.lastSync {
                        Text("Zuletzt \(d.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                if engine.isSyncing { ProgressView() }
            }
            Button("Jetzt abgleichen") { Task { await engine.sync() } }
                .disabled(engine.isSyncing)
        }

        Section {
            if let qr = qrImage(config.inviteCode) {
                HStack {
                    Spacer()
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .accessibilityLabel("QR-Code zum Beitreten")
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            ShareLink(item: config.inviteCode) {
                Label("Code teilen", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Zweites iPhone einladen")
        } footer: {
            Text("Auf dem anderen iPhone: Kammer installieren → Einstellungen → Gemeinsam nutzen → „QR-Code scannen“. Am besten dort vorher keine eigenen Produkte anlegen.")
        }

        Section {
            Button("Verbindung trennen", role: .destructive) { confirmDisconnect = true }
        }
    }

    // MARK: Einrichten

    @ViewBuilder
    private var setupSections: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("QR-Code scannen", systemImage: "qrcode.viewfinder")
            }
            .disabled(!BarcodeScannerView.isAvailable)
            HStack {
                TextField("…oder Code einfügen (KAMMER-…)", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Beitreten") { Task { await join() } }
                    .disabled(code.isEmpty || busy)
            }
        } header: {
            Text("Haushalt beitreten")
        } footer: {
            Text("Wenn auf dem anderen iPhone schon alles eingerichtet ist.")
        }

        Section {
            TextField("Project URL (https://….supabase.co)", text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("anon / publishable key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button {
                Task { await create() }
            } label: {
                HStack {
                    Text("Haushalt anlegen")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(url.isEmpty || key.isEmpty || busy)
        } header: {
            Text("Neuen Haushalt anlegen")
        } footer: {
            Text("1. Kostenloses Projekt auf supabase.com anlegen.\n2. Im SQL-Editor die Datei supabase/schema.sql aus dem Repository ausführen.\n3. Unter Project Settings → API die URL und den anon- bzw. publishable-Key hier eintragen.")
        }

        if let error {
            Section { Text(error).foregroundStyle(Theme.warnText) }
        }
    }

    // MARK: Aktionen

    private func create() async {
        busy = true
        defer { busy = false }
        error = nil
        let c = SyncConfig(url: url.trimmingCharacters(in: .whitespaces), key: key.trimmingCharacters(in: .whitespaces), household: UUID())
        do { try await engine.connect(c) } catch { self.error = error.localizedDescription }
    }

    private func join() async {
        guard let c = SyncConfig(inviteCode: code) else {
            error = "Das ist kein gültiger Kammer-Code."
            return
        }
        busy = true
        defer { busy = false }
        error = nil
        do { try await engine.connect(c) } catch { self.error = error.localizedDescription }
    }

    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
