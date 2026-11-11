import SwiftUI
import SwiftData
import WebKit

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// REWE-Warenkorb direkt aus Kammer befüllen (über rewe.de in der App).
struct ReweCartView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var runner = ReweCartRunner()
    @State private var showList = false
    @AppStorage("rewe.setupDone") private var setupDone = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebViewHost(webView: runner.webView)
                    .overlay(alignment: .top) {
                        if !setupDone && !runner.running && !runner.finished { setupHint }
                    }
                panel
            }
            .navigationTitle("REWE-Warenkorb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        runner.pause()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showList = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Artikelliste")
                }
            }
            .sheet(isPresented: $showList) { jobList }
            .onAppear {
                runner.prepare(context: context)
                runner.openHome()
            }
        }
    }

    // MARK: Teile

    private var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Einmalig: bei REWE anmelden").font(.system(size: 15, weight: .bold))
            Text("Melde dich unten auf der REWE-Seite an und wähle den Lieferservice mit deiner Adresse. Der Login bleibt in Kammer gespeichert.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Button("Erledigt") { setupDone = true }
                .font(.system(size: 14, weight: .bold))
                .frame(minHeight: 36)
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(12)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runner.jobs.isEmpty {
                Text("Die REWE-Liste ist leer – es gibt nichts in den Warenkorb zu legen.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            } else if runner.finished {
                finishedPanel
            } else {
                let i = min(runner.current, runner.jobs.count - 1)
                let job = runner.jobs[i]
                HStack {
                    Text("Artikel \(runner.current + 1) von \(runner.jobs.count)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    ProgressView(value: Double(runner.current), total: Double(runner.jobs.count))
                        .frame(width: 120)
                        .tint(Theme.accent)
                }
                Text("\(job.packages)× \(job.name)").font(.system(size: 17, weight: .bold))
                statusLine(job.status)

                if runner.waitingForUser {
                    HStack(spacing: 8) {
                        Button("Überspringen") { runner.skip() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                        Button("Im Korb – weiter") { runner.userDidAdd() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                } else if runner.running {
                    Button("Pause") { runner.pause() }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                } else {
                    Button(runner.current == 0 ? "Warenkorb füllen" : "Weitermachen") {
                        setupDone = true
                        runner.start()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(16)
        .background(Theme.ground)
    }

    private var finishedPanel: some View {
        let added = runner.jobs.filter { if case .added = $0.status { return true }; return false }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Fertig: \(added) von \(runner.jobs.count) im Warenkorb").font(.system(size: 17, weight: .bold))
            Text("Prüf den Korb kurz in der REWE-App, wähle das Lieferfenster und bestelle.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Button("Liste ansehen") { showList = true }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                Button("Zur REWE-App") {
                    // Universeller Link – öffnet die REWE-App, wenn sie installiert ist.
                    if let url = URL(string: "https://www.rewe.de/shop/") { openURL(url) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ s: CartJob.Status) -> some View {
        switch s {
        case .waiting: Label("Wartet", systemImage: "clock").foregroundStyle(Theme.muted)
        case .working: Label("Lege in den Korb …", systemImage: "cart.badge.plus").foregroundStyle(Theme.accent)
        case .added(let n): Label("Im Korb (\(n))", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .manual(let hint): Label(hint, systemImage: "hand.tap").foregroundStyle(Theme.warnText)
        case .skipped: Label("Übersprungen", systemImage: "forward").foregroundStyle(Theme.muted)
        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warnText)
        }
    }

    private var jobList: some View {
        NavigationStack {
            List(runner.jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(job.packages)× \(job.name)").font(.system(size: 15, weight: .semibold))
                    statusLine(job.status).font(.system(size: 13))
                }
            }
            .navigationTitle("Artikel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showList = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}
