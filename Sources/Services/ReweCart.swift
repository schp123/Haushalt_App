import Foundation
import WebKit
import SwiftData
import Observation

/// Ein Artikel, der in den REWE-Warenkorb soll.
struct CartJob: Identifiable {
    enum Status: Equatable { case waiting, working, added(String), manual(String), skipped, failed(String) }

    let id = UUID()
    var name: String
    var packages: Int
    var url: URL?
    var searchTerm: String
    /// Vorratsprodukt (dann werden Link, Nummer und Preis gelernt) – bei freien Listeneinträgen nil.
    var product: Product?
    var status: Status = .waiting

    var isDone: Bool {
        switch status {
        case .added, .skipped: return true
        default: return false
        }
    }
}

/// Steuert die eingebaute rewe.de-Seite und legt die Artikel nacheinander in den Warenkorb.
@MainActor
@Observable
final class ReweCartRunner: NSObject, WKNavigationDelegate {
    var jobs: [CartJob] = []
    var current: Int = 0
    var running = false
    /// Wartet darauf, dass du den aktuellen Artikel selbst in den Korb legst.
    var waitingForUser = false
    var finished = false
    var pageURL: URL?

    let webView: WKWebView
    @ObservationIgnored private var loadContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var context: ModelContext?

    static let home = URL(string: "https://www.rewe.de/shop/")!

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // Login bleibt gespeichert
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: Liste vorbereiten

    func prepare(context: ModelContext) {
        self.context = context
        let products = ((try? context.fetch(FetchDescriptor<Product>())) ?? []).filter { !$0.isDeleted }
        let plan = ((try? context.fetch(FetchDescriptor<PlanEntry>())) ?? []).filter { !$0.isDeleted }
        let logs = ((try? context.fetch(FetchDescriptor<MealLog>())) ?? []).filter { !$0.isDeleted }
        let f = Forecast(products: products, plan: plan, settings: AppSettings.current(context), logs: logs)

        var list: [CartJob] = f.shoppingList(for: .rewe).map { e in
            CartJob(name: e.product.name, packages: e.status.packages, url: Self.productURL(for: e.product),
                    searchTerm: e.product.name, product: e.product)
        }
        let extra = ((try? context.fetch(FetchDescriptor<ListItem>())) ?? []).filter { !$0.isDeleted && !$0.done && $0.source == .rewe }
        for li in extra {
            let n = Int(li.quantity.prefix { $0.isNumber }) ?? 1
            list.append(CartJob(name: li.quantity.isEmpty ? li.name : "\(li.quantity) \(li.name)",
                                packages: max(1, min(n, 20)), url: nil, searchTerm: li.name, product: nil))
        }
        jobs = list
        current = 0
        finished = false
        waitingForUser = false
    }

    static func productURL(for p: Product) -> URL? {
        if !p.reweURL.isEmpty, let u = URL(string: p.reweURL) { return u }
        if !p.reweArticleNumber.isEmpty { return URL(string: "https://www.rewe.de/shop/p/produkt/\(p.reweArticleNumber)") }
        return nil
    }

    static func searchURL(_ term: String) -> URL? {
        var c = URLComponents(string: "https://www.rewe.de/shop/productList")
        c?.queryItems = [URLQueryItem(name: "search", value: term)]
        return c?.url
    }

    // MARK: Ablauf

    func openHome() {
        webView.load(URLRequest(url: Self.home))
    }

    func start() {
        guard !running, !jobs.isEmpty else { return }
        running = true
        loop?.cancel()
        loop = Task { @MainActor in await self.runLoop() }
    }

    func pause() {
        running = false
        loop?.cancel()
    }

    /// Du hast den Artikel selbst in den Korb gelegt.
    func userDidAdd() {
        guard current < jobs.count else { return }
        learn(from: webView.url, job: current)
        jobs[current].status = .added("von Hand")
        advance()
    }

    func skip() {
        guard current < jobs.count else { return }
        jobs[current].status = .skipped
        advance()
    }

    private func advance() {
        waitingForUser = false
        current += 1
        if current >= jobs.count {
            complete()
        } else if running {
            loop?.cancel()
            loop = Task { @MainActor in await self.runLoop() }
        }
    }

    private func runLoop() async {
        while running, current < jobs.count, !Task.isCancelled {
            let i = current
            jobs[i].status = .working
            let job = jobs[i]

            if let url = job.url {
                _ = await load(url)
                try? await Task.sleep(for: .milliseconds(800))
                let result = await addToCart(packages: job.packages)
                if result.ok {
                    learn(from: webView.url, job: i, price: result.price)
                    jobs[i].status = .added(result.note ?? "\(job.packages)×")
                    current += 1
                    continue
                }
                jobs[i].status = .manual(result.note ?? "Bitte selbst in den Korb legen")
            } else {
                if let url = Self.searchURL(job.searchTerm) { _ = await load(url) }
                jobs[i].status = .manual("Passendes Produkt antippen und \(job.packages)× in den Korb legen")
            }
            // Auf dich warten
            waitingForUser = true
            return
        }
        if current >= jobs.count { complete() }
    }

    private func complete() {
        running = false
        finished = true
        waitingForUser = false
        try? context?.save()
        let added = jobs.filter { if case .added = $0.status { return true }; return false }.count
        Notifier.notifyNow(id: "rewe-cart-done", title: "🛒 Warenkorb gefüllt",
                           body: "\(added) von \(jobs.count) Artikeln liegen im REWE-Warenkorb. Jetzt in der REWE-App prüfen und bestellen.")
        if let ctx = context { Notifier.evaluate(ctx) }
    }

    // MARK: Lernen (Link, Artikelnummer, Preis)

    private func learn(from url: URL?, job i: Int, price: Double? = nil) {
        guard i < jobs.count, let p = jobs[i].product, !p.isDeleted else { return }
        if let url, url.path.contains("/shop/p/") {
            p.reweURL = url.absoluteString
            if let nr = url.pathComponents.last(where: { $0.count >= 5 && $0.allSatisfy(\.isNumber) }) {
                p.reweArticleNumber = nr
            }
        }
        if let price, price > 0, let ctx = context { p.updatePrice(price, context: ctx) }
    }

    // MARK: Seite steuern

    private func load(_ url: URL) async -> Bool {
        loadContinuation?.resume(returning: false)
        loadContinuation = nil
        webView.load(URLRequest(url: url))
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.loadContinuation?.resume(returning: false)
            self.loadContinuation = nil
        }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in loadContinuation = c }
        timeout.cancel()
        return ok
    }

    struct AddResult {
        var ok: Bool
        var note: String?
        var price: Double?
    }

    /// Sucht auf der Produktseite den „In den Warenkorb“-Knopf und erhöht die Menge.
    private func addToCart(packages: Int) async -> AddResult {
        let script = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const vis = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
        const lab = e => ((e.getAttribute('aria-label') || '') + ' ' + (e.getAttribute('title') || '') + ' ' + (e.innerText || '')).toLowerCase().replace(/\\s+/g, ' ');
        const buttons = () => [...document.querySelectorAll('button,[role="button"]')].filter(vis);
        let add = null;
        for (let i = 0; i < 20 && !add; i++) {
          add = buttons().find(e => /(in den warenkorb|zum warenkorb|in den korb|in warenkorb)/.test(lab(e)) && !/(entfernen|merkliste|einkaufsliste)/.test(lab(e)));
          if (!add) await sleep(500);
        }
        if (!add) {
          const blocked = /(markt wählen|postleitzahl|plz|anmelden|einloggen)/.test(document.body.innerText.toLowerCase());
          return { ok: false, reason: blocked ? 'login' : 'nobutton' };
        }
        add.click();
        await sleep(1300);
        let added = 1;
        for (let k = 1; k < n; k++) {
          const plus = buttons().find(e => /(erhöhen|menge \\+|mehr hinzufügen|plus|anzahl erhöhen)/.test(lab(e)) && !/(verringern|weniger|entfernen)/.test(lab(e)));
          if (!plus) break;
          plus.click();
          added++;
          await sleep(900);
        }
        let price = null;
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
          try {
            const j = JSON.parse(s.textContent);
            for (const o of (Array.isArray(j) ? j : [j])) {
              const off = o && o.offers && (Array.isArray(o.offers) ? o.offers[0] : o.offers);
              if (off && off.price) price = parseFloat(String(off.price).replace(',', '.'));
            }
          } catch (e) {}
        }
        const title = (document.querySelector('h1') || {}).innerText || document.title;
        return { ok: true, added: added, price: price, title: title };
        """
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: ["n": max(1, packages)], contentWorld: .page)
            guard let dict = value as? [String: Any] else { return AddResult(ok: false, note: "Seite nicht erkannt – bitte selbst hinzufügen") }
            if (dict["ok"] as? Bool) == true {
                let added = (dict["added"] as? Int) ?? (dict["added"] as? Double).map(Int.init) ?? packages
                let price = (dict["price"] as? Double) ?? (dict["price"] as? Int).map(Double.init)
                let note = added < packages ? "\(added) von \(packages)× – Rest bitte selbst" : "\(added)×"
                return AddResult(ok: added >= packages, note: note, price: price)
            }
            let reason = dict["reason"] as? String
            return AddResult(ok: false, note: reason == "login"
                             ? "Bitte erst anmelden bzw. Markt/Lieferservice wählen"
                             : "Knopf nicht gefunden – bitte selbst in den Korb legen")
        } catch {
            return AddResult(ok: false, note: "Seite nicht bereit – bitte selbst hinzufügen")
        }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageURL = webView.url
            self.loadContinuation?.resume(returning: true)
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(returning: false)
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(returning: false)
            self.loadContinuation = nil
        }
    }
}
