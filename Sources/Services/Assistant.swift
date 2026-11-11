import Foundation
import SwiftData

// MARK: - Verbindung zu OmniRoute (OpenAI-kompatibel)

struct AssistantConfig: Codable, Equatable {
    var baseURL: String = ""
    var apiKey: String = ""
    var model: String = ""

    private static let storeKey = "assistant.config"

    static func load() -> AssistantConfig {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let c = try? JSONDecoder().decode(AssistantConfig.self, from: d) else { return AssistantConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
    }

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty }

    /// „http://host:20128“ → „http://host:20128/v1/chat/completions“
    var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if let u = URL(string: base), u.path.isEmpty || u.path == "/" { base += "/v1" }
        return URL(string: base + "/chat/completions")
    }
}

enum AssistantError: LocalizedError {
    case notConfigured, badResponse(String), http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Bitte zuerst die KI-Verbindung in den Einstellungen eintragen."
        case .badResponse(let s): return "Antwort nicht verstanden: \(s.prefix(160))"
        case .http(let c, let s):
            if c == 503 || c == 429 {
                return "Das KI-Modell ist gerade überlastet (\(c)). Bitte gleich noch einmal versuchen oder in den Einstellungen ein Ersatzmodell ergänzen."
            }
            return "KI-Fehler \(c): \(s.prefix(200))"
        }
    }
}

struct ChatMessage: Codable {
    var role: String
    var content: String
}

enum AssistantClient {
    /// Überlastete Modelle werden ein paar Minuten lang hinten angestellt.
    @MainActor private static var cooldown: [String: Date] = [:]
    /// Modelle, die den Parameter „reasoning_effort“ nicht kennen.
    @MainActor private static var noReasoningParam: Set<String> = []
    /// Zuletzt erfolgreiches Modell – wird zuerst versucht.
    @MainActor private static var lastGood: String?

    static func complete(_ messages: [ChatMessage], config: AssistantConfig, timeout: TimeInterval = 15) async throws -> String {
        try await complete(raw: messages.map { ["role": $0.role, "content": $0.content] }, config: config, timeout: timeout)
    }

    /// Mehrere Modelle durch Komma getrennt. Bei Überlastung, Fehler oder zu langer Antwortzeit
    /// geht es sofort zum nächsten Modell – ohne Wartepause.
    @MainActor
    static func complete(raw messages: [[String: Any]], config: AssistantConfig, timeout: TimeInterval = 15) async throws -> String {
        let all = config.model.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !all.isEmpty else { throw AssistantError.notConfigured }
        let now = Date()
        // Reihenfolge: zuletzt erfolgreiches zuerst, überlastete ans Ende
        let fresh = all.filter { (cooldown[$0] ?? .distantPast) < now }
        let cooling = all.filter { (cooldown[$0] ?? .distantPast) >= now }
        var order = fresh
        if let good = lastGood, let i = order.firstIndex(of: good) { order.insert(order.remove(at: i), at: 0) }
        order += cooling

        var lastError: Error = AssistantError.notConfigured
        for model in order {
            do {
                let text = try await completeOnce(messages, config: config, model: model, timeout: timeout)
                lastGood = model
                cooldown[model] = nil
                return text
            } catch let e as AssistantError {
                lastError = e
                if case .http(let code, _) = e, [404, 400].contains(code) == false {
                    cooldown[model] = Date().addingTimeInterval(180)
                }
                continue
            } catch let e as URLError where e.code == .timedOut {
                lastError = AssistantError.http(504, "Zeitüberschreitung bei \(model)")
                cooldown[model] = Date().addingTimeInterval(120)
                continue
            }
        }
        throw lastError
    }

    @MainActor
    private static func completeOnce(_ messages: [[String: Any]], config: AssistantConfig, model: String,
                                     timeout: TimeInterval) async throws -> String {
        guard config.isConfigured, let url = config.endpoint else { throw AssistantError.notConfigured }
        let isGemini = url.host?.contains("googleapis") == true
        var body: [String: Any] = ["model": model, "temperature": 0.1, "messages": messages]
        // Bei Gemini das „Nachdenken“ kurz halten – deutlich schnellere Antworten.
        if isGemini && !noReasoningParam.contains(model) { body["reasoning_effort"] = "low" }

        func send(_ body: [String: Any]) async throws -> (Data, Int) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = config.apiKey.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var (data, code) = try await send(body)
        if code == 400, body["reasoning_effort"] != nil {
            // Modell kennt den Parameter nicht → ohne erneut
            noReasoningParam.insert(model)
            body["reasoning_effort"] = nil
            (data, code) = try await send(body)
        }
        guard (200..<300).contains(code) else { throw AssistantError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw AssistantError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return content
    }
}

// MARK: - Verstandener Auftrag (vor der Freigabe)

struct AssistantPlan {
    var reply: String
    var actions: [[String: Any]]
    var descriptions: [String]
    var raw: String
}

// MARK: - Ergebnis eines Auftrags

struct AssistantResult {
    var reply: String
    var done: [String] = []
    var failed: [String] = []
    /// Löschen wird erst nach Bestätigung ausgeführt.
    var pendingDeletes: [Product] = []
}

// MARK: - Assistent: Text → Aktionen → ausführen

@MainActor
enum Assistant {

    /// Schritt 1: Auftrag verstehen – noch nichts ausführen.
    static func plan(_ text: String, history: [ChatMessage], context: ModelContext) async throws -> AssistantPlan {
        let config = AssistantConfig.load()
        let system = systemPrompt(context: context)
        let messages = [ChatMessage(role: "system", content: system)] + history.suffix(6) + [ChatMessage(role: "user", content: text)]
        let raw = try await AssistantClient.complete(messages, config: config)
        guard let json = extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return AssistantPlan(reply: raw.trimmingCharacters(in: .whitespacesAndNewlines), actions: [], descriptions: [], raw: raw)
        }
        let actions = obj["actions"] as? [[String: Any]] ?? []
        return AssistantPlan(reply: obj["reply"] as? String ?? "", actions: actions,
                             descriptions: actions.map { describe($0, context: context) }, raw: raw)
    }

    /// Schritt 2: freigegebene Aktionen ausführen.
    static func execute(_ plan: AssistantPlan, context: ModelContext, confirmDeletes: Bool) -> AssistantResult {
        var result = AssistantResult(reply: plan.reply)
        for a in plan.actions { execute(a, context: context, result: &result) }
        if confirmDeletes, !result.pendingDeletes.isEmpty {
            let names = result.pendingDeletes.map(\.name)
            Self.confirmDeletes(result.pendingDeletes, context: context)
            result.pendingDeletes = []
            result.done.append("Gelöscht: \(names.joined(separator: ", "))")
        }
        Notifier.evaluate(context)
        return result
    }

    /// Kurze Beschreibung einer Aktion für die Freigabe.
    static func describe(_ a: [String: Any], context ctx: ModelContext) -> String {
        let type = a["type"] as? String ?? ""
        let pName = findProduct(a["product"], ctx)?.name ?? (str(a["product"]) ?? "?")
        switch type {
        case "set_stock":
            return "\(pName) auf \(Fmt.number(num(a["amount"]) ?? 0)) setzen"
        case "change_stock":
            let d = num(a["delta"]) ?? 0
            return "\(pName) \(d >= 0 ? "+" : "−")\(Fmt.number(abs(d)))"
        case "add_product": return "Neues Produkt: \(str(a["name"]) ?? "?")"
        case "update_product": return "\(pName) ändern"
        case "delete_product": return "\(pName) löschen"
        case "add_list_item":
            let q = str(a["quantity"]) ?? numString(a["quantity"]) ?? ""
            return "Auf die Einkaufsliste: \(q.isEmpty ? "" : q + " ")\(str(a["name"]) ?? "?")"
        case "check_list_item": return "\(findListItem(a["item"], ctx)?.name ?? "Eintrag") abhaken"
        case "remove_list_item": return "\(findListItem(a["item"], ctx)?.name ?? "Eintrag") von der Liste nehmen"
        case "clear_list": return (a["only_done"] as? Bool) == false ? "Einkaufsliste komplett leeren" : "Erledigte von der Liste entfernen"
        case "add_wish": return "Auf die Wunschliste: \(str(a["name"]) ?? "?")"
        case "complete_wish": return "\(findWish(a["wish"], ctx)?.name ?? "Wunsch") als gekauft markieren"
        case "log_meal": return "Mahlzeit eintragen: \(findTemplate(a["template"], ctx)?.name ?? str(a["name"]) ?? "?")"
        case "add_template": return "Vorlage anlegen: \(str(a["name"]) ?? "?")"
        case "set_plan":
            let day = int(a["weekday"]).map { Fmt.weekdayName($0) } ?? "?"
            let slot = MealSlot(rawValue: str(a["slot"]) ?? "")?.label ?? "?"
            return "Wochenplan \(day) \(slot): \(findTemplate(a["template"], ctx)?.name ?? "nichts")"
        case "add_purchase": return "Ausgabe buchen: \(Fmt.euro(num(a["amount"]) ?? 0))"
        case "update_settings": return "Einstellungen ändern"
        case "navigate": return "Öffnen: \(str(a["tab"]) ?? "?")"
        default: return type
        }
    }

    static func confirmDeletes(_ products: [Product], context: ModelContext) {
        for p in products where !p.isDeleted { context.delete(p) }
        Notifier.evaluate(context)
    }

    // MARK: Prompt

    private static func systemPrompt(context ctx: ModelContext) -> String {
        let products = ((try? ctx.fetch(FetchDescriptor<Product>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []).filter { !$0.isDeleted }
        let templates = ((try? ctx.fetch(FetchDescriptor<MealTemplate>())) ?? []).filter { !$0.isDeleted }
        let list = ((try? ctx.fetch(FetchDescriptor<ListItem>())) ?? []).filter { !$0.isDeleted }
        let wishes = ((try? ctx.fetch(FetchDescriptor<WishItem>())) ?? []).filter { !$0.isDeleted && !$0.done }
        let plan = ((try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? []).filter { !$0.isDeleted }
        let s = AppSettings.current(ctx)

        func short(_ u: UUID) -> String { String(u.uuidString.lowercased().prefix(8)) }
        func n(_ v: Double) -> String { Fmt.number(v, maxFraction: 2).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }

        let productLines = products.map {
            "\(short($0.uuid)) | \($0.name) | Bestand \(n($0.currentStock())) \($0.unit.rawValue) | Quelle \($0.sourceRaw)\($0.storeName.isEmpty ? "" : " (\($0.storeName))") | warnen ab \(n($0.warnAt)) | auffüllen auf \(n($0.refillTo)) | Packung \(n($0.packageSize)) | \($0.isFood ? "Lebensmittel" : "Haushalt")"
        }.joined(separator: "\n")
        let templateLines = templates.map { "\(short($0.uuid)) | \($0.emoji) \($0.name)" }.joined(separator: "\n")
        let listLines = list.map { "\(short($0.uuid)) | \($0.quantity) \($0.name) | \($0.sourceRaw)\($0.done ? " | erledigt" : "")" }.joined(separator: "\n")
        let wishLines = wishes.map { "\(short($0.uuid)) | \($0.name)\($0.storeName.isEmpty ? "" : " | \($0.storeName)")" }.joined(separator: "\n")
        let planLines = plan.compactMap { e in e.template.map { "\(Fmt.weekdayName(e.weekday)) \(e.slotRaw): \($0.name)" } }.joined(separator: "\n")
        let today = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "sv_SE")))

        return """
        Du bist der Assistent der iPhone-App „Kammer“ (Vorrat, Einkauf, Mahlzeiten, Haushalt) eines deutschen Haushalts.
        Der Nutzer diktiert Aufträge per Sprache; der Text kann Tippfehler oder Umgangssprache enthalten.
        Heute ist \(Fmt.weekdayName(Calendar.current.isoWeekday(Date()))), \(today).

        Antworte AUSSCHLIESSLICH mit einem JSON-Objekt, ohne Markdown:
        {"reply": "kurze Antwort auf Deutsch (1–2 Sätze)", "actions": [ ... ]}
        "reply" wird laut vorgelesen: natürlich gesprochen, ohne Listen, Emojis oder IDs. Bei Aktionen fasst "reply" in einem Satz zusammen, was du tun wirst (z. B. „Ich setze Milch auf leer und packe zwei Zitronen auf die Liste.“) – der Nutzer bestätigt danach.
        Wenn nichts zu tun ist (z. B. eine Frage), ist "actions" leer und "reply" beantwortet die Frage anhand der Daten unten.

        Produkte/Einträge referenzierst du mit ihrer ID (8 Zeichen) aus den Listen unten, sonst mit dem Namen.
        Mengen immer in der Einheit des Produkts (Einheiten: stueck, gramm, milliliter, becher, packung, anwendung).
        Quellen: "rewe", "metzger", "sonstiges" (andere Läden wie Biomarkt, Amazon, dm – dann "store" angeben).
        Wochentage: 1 = Montag … 7 = Sonntag. Mahlzeiten (slot): fruehstueck, mittag, snack, abend. Datum: JJJJ-MM-TT.

        Mögliche Aktionen:
        {"type":"set_stock","product":ID,"amount":Zahl}
        {"type":"change_stock","product":ID,"delta":Zahl}   (negativ = verbraucht)
        {"type":"add_product","name":"…","emoji":"…","source":"rewe","store":"…","unit":"stueck","stock":0,"warn_at":1,"refill_to":3,"package_size":1,"grams_per_unit":100,"usage_per_week":0,"is_food":true,"price":0,"kcal100":0,"protein100":0,"carbs100":0,"fat100":0,"link":"…","lead_days":7}
           (nur die bekannten Felder angeben; bei Lebensmitteln Nährwerte pro 100 g grob schätzen, wenn nicht genannt)
        {"type":"update_product","product":ID, …beliebige Felder wie bei add_product, auch "name"}
        {"type":"delete_product","product":ID}
        {"type":"add_list_item","name":"…","quantity":"2","source":"rewe","store":"…"}
        {"type":"check_list_item","item":ID,"done":true}
        {"type":"remove_list_item","item":ID}
        {"type":"clear_list","only_done":true}
        {"type":"add_wish","name":"…","store":"…","link":"…","due_date":"JJJJ-MM-TT","price":0,"note":"…"}
        {"type":"complete_wish","wish":ID,"price":0}
        {"type":"log_meal","template":ID,"slot":"mittag"}  oder  {"type":"log_meal","name":"…","kcal":0,"protein":0,"carbs":0,"fat":0,"cost":0,"slot":"abend"}
        {"type":"add_template","name":"…","emoji":"…","ingredients":[{"product":ID,"amount":Zahl}]}
        {"type":"set_plan","weekday":1,"slot":"mittag","template":ID oder null}
        {"type":"add_purchase","source":"rewe","amount":Zahl,"note":"…","date":"JJJJ-MM-TT"}
        {"type":"update_settings","order_weekday":4,"delivery_weekday":5,"delivery_window":"8–10 Uhr","cart_fill_weekday":3,"cart_fill_time":"20:00","metzger_weekday":6,"budget":800,"check_time":"18:00","check_enabled":true,"low_stock_enabled":true,"kcal_goal":2200,"protein_goal":160,"carbs_goal":230,"fat_goal":70}
        {"type":"navigate","tab":"vorrat|mahlzeiten|plan|einkauf|ausgaben|check"}

        Regeln: „Milch ist leer“ → set_stock 0. „Wir haben noch 3 Eier“ → set_stock 3. „Setz X auf die Liste“ → add_list_item.
        „Neues Produkt …“ → add_product. Fehlt ein Produkt, das gesetzt werden soll, lege es mit add_product an.
        Mehrere Aufträge in einem Satz → mehrere Aktionen.

        PRODUKTE (ID | Name | Bestand | Quelle | Warnen ab | Auffüllen auf | Packung | Art):
        \(productLines.isEmpty ? "(keine)" : productLines)

        VORLAGEN (ID | Name):
        \(templateLines.isEmpty ? "(keine)" : templateLines)

        EINKAUFSLISTE (ID | Menge Name | Quelle):
        \(listLines.isEmpty ? "(leer)" : listLines)

        WUNSCHLISTE (ID | Name | Laden):
        \(wishLines.isEmpty ? "(leer)" : wishLines)

        WOCHENPLAN:
        \(planLines.isEmpty ? "(leer)" : planLines)

        EINSTELLUNGEN: Bestelltag \(s.orderWeekday), Liefertag \(s.deliveryWeekday) \(s.deliveryWindow), Metzger \(s.metzgerWeekday), Budget \(Int(s.budget)) €, Check \(Fmt.time(s.checkHour, s.checkMinute)).
        """
    }

    /// Erstes vollständiges JSON-Objekt aus der Antwort (auch wenn das Modell Text oder ```json drumherum schreibt).
    static func extractJSON(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: Ausführen

    private static func execute(_ a: [String: Any], context ctx: ModelContext, result: inout AssistantResult) {
        let type = a["type"] as? String ?? ""
        switch type {
        case "set_stock", "change_stock":
            guard let p = findProduct(a["product"], ctx) else { return fail("Produkt „\(a["product"] ?? "?")“ nicht gefunden", &result) }
            let value = type == "set_stock" ? (num(a["amount"]) ?? 0) : p.currentStock() + (num(a["delta"]) ?? 0)
            p.setStock(value)
            p.lastCorrectedAt = Date()
            p.lastCheckedAt = Date()
            p.lowNotifiedAt = nil
            result.done.append("\(p.emoji) \(p.name): \(Fmt.amount(p.currentStock(), p.unit))")

        case "add_product":
            guard let name = str(a["name"]), !name.isEmpty else { return fail("Produkt ohne Namen", &result) }
            let all = (try? ctx.fetch(FetchDescriptor<Product>())) ?? []
            let p = Product(name: name, emoji: str(a["emoji"]) ?? EmojiGuess.emoji(for: name),
                            source: Source(rawValue: str(a["source"]) ?? "") ?? .rewe,
                            unit: StockUnit(rawValue: str(a["unit"]) ?? "") ?? .stueck)
            p.sortIndex = (all.map(\.sortIndex).max() ?? -1) + 1
            ctx.insert(p)
            applyFields(a, to: p, ctx: ctx)
            if a["stock"] == nil { p.setStock(0) }
            result.done.append("Neu: \(p.emoji) \(p.name) (\(Fmt.amount(p.currentStock(), p.unit)))")

        case "update_product":
            guard let p = findProduct(a["product"], ctx) else { return fail("Produkt „\(a["product"] ?? "?")“ nicht gefunden", &result) }
            if let name = str(a["name"]), !name.isEmpty { p.name = name }
            if let e = str(a["emoji"]), !e.isEmpty { p.emoji = e }
            if let src = str(a["source"]).flatMap(Source.init(rawValue:)) { p.source = src }
            if let u = str(a["unit"]).flatMap(StockUnit.init(rawValue:)) { p.unit = u }
            applyFields(a, to: p, ctx: ctx)
            result.done.append("\(p.emoji) \(p.name) geändert")

        case "delete_product":
            guard let p = findProduct(a["product"], ctx) else { return fail("Produkt „\(a["product"] ?? "?")“ nicht gefunden", &result) }
            result.pendingDeletes.append(p)

        case "add_list_item":
            guard let name = str(a["name"]), !name.isEmpty else { return fail("Eintrag ohne Namen", &result) }
            let src = Source(rawValue: str(a["source"]) ?? "") ?? .rewe
            let item = ListItem(name: name, quantity: str(a["quantity"]) ?? numString(a["quantity"]) ?? "", source: src,
                                storeName: str(a["store"]) ?? "")
            ctx.insert(item)
            result.done.append("Auf der Liste: \(item.quantity.isEmpty ? "" : item.quantity + " ")\(item.name)")

        case "check_list_item":
            guard let li = findListItem(a["item"], ctx) else { return fail("Listeneintrag nicht gefunden", &result) }
            li.done = (a["done"] as? Bool) ?? true
            result.done.append("\(li.name) \(li.done ? "abgehakt" : "wieder offen")")

        case "remove_list_item":
            guard let li = findListItem(a["item"], ctx) else { return fail("Listeneintrag nicht gefunden", &result) }
            result.done.append("\(li.name) von der Liste entfernt")
            ctx.delete(li)

        case "clear_list":
            let onlyDone = (a["only_done"] as? Bool) ?? true
            let items = ((try? ctx.fetch(FetchDescriptor<ListItem>())) ?? []).filter { !onlyDone || $0.done }
            for li in items { ctx.delete(li) }
            result.done.append("\(items.count) Einträge entfernt")

        case "add_wish":
            guard let name = str(a["name"]), !name.isEmpty else { return fail("Wunsch ohne Namen", &result) }
            let w = WishItem(name: name)
            ctx.insert(w)
            w.storeName = str(a["store"]) ?? ""
            w.linkURL = str(a["link"]) ?? ""
            w.note = str(a["note"]) ?? ""
            w.price = num(a["price"]) ?? 0
            w.dueDate = date(a["due_date"])
            result.done.append("Wunschliste: \(w.name)\(w.dueDate.map { " bis \(Fmt.shortDate($0))" } ?? "")")

        case "complete_wish":
            guard let w = findWish(a["wish"], ctx) else { return fail("Wunsch nicht gefunden", &result) }
            w.done = true
            w.doneAt = Date()
            let price = num(a["price"]) ?? w.price
            if price > 0 {
                let p = Purchase(date: Date(), source: .sonstiges, total: price, itemCount: 1, note: w.name)
                p.uuid = UUID()
                ctx.insert(p)
            }
            result.done.append("\(w.name) gekauft")

        case "log_meal":
            let slot = MealSlot(rawValue: str(a["slot"]) ?? "") ?? .forNow()
            if let t = findTemplate(a["template"], ctx) {
                MealLogger.log(template: t, slot: slot, fromPlan: false, context: ctx)
                result.done.append("Gegessen: \(t.name)")
            } else if let name = str(a["name"]), !name.isEmpty {
                let log = MealLog(date: Date(), slot: slot, name: name, emoji: "🍽️",
                                  nutrition: Nutrition(kcal: num(a["kcal"]) ?? 0, protein: num(a["protein"]) ?? 0,
                                                       carbs: num(a["carbs"]) ?? 0, fat: num(a["fat"]) ?? 0),
                                  cost: num(a["cost"]) ?? 0, fromPlan: false)
                log.uuid = UUID()
                ctx.insert(log)
                result.done.append("Gegessen: \(name) (\(Fmt.kcal(log.kcal)) kcal)")
            } else {
                fail("Mahlzeit nicht erkannt", &result)
            }

        case "add_template":
            guard let name = str(a["name"]), !name.isEmpty else { return fail("Vorlage ohne Namen", &result) }
            let t = MealTemplate(name: name, emoji: str(a["emoji"]) ?? "🍽️")
            ctx.insert(t)
            let ings = (a["ingredients"] as? [[String: Any]] ?? []).compactMap { i -> (product: Product, amount: Double)? in
                guard let p = findProduct(i["product"], ctx), let amt = num(i["amount"]), amt > 0 else { return nil }
                return (product: p, amount: amt)
            }
            t.setIngredients(ings, context: ctx)
            result.done.append("Vorlage: \(t.emoji) \(t.name) (\(ings.count) Zutaten)")

        case "set_plan":
            guard let day = int(a["weekday"]), (1...7).contains(day),
                  let slot = MealSlot(rawValue: str(a["slot"]) ?? "") else { return fail("Wochenplan-Eintrag unklar", &result) }
            let template = findTemplate(a["template"], ctx)
            let entries = (try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? []
            if let e = entries.first(where: { $0.weekday == day && $0.slotRaw == slot.rawValue }) {
                if let template { e.template = template } else { ctx.delete(e) }
            } else if let template {
                let e = PlanEntry(weekday: day, slot: slot)
                ctx.insert(e)
                e.template = template
            }
            result.done.append("\(Fmt.weekdayName(day)) \(slot.label): \(template?.name ?? "nichts")")

        case "add_purchase":
            guard let amount = num(a["amount"]), amount > 0 else { return fail("Betrag fehlt", &result) }
            let src = Source(rawValue: str(a["source"]) ?? "") ?? .rewe
            let p = Purchase(date: date(a["date"]) ?? Date(), source: src, total: amount, note: str(a["note"]) ?? "")
            p.uuid = UUID()
            ctx.insert(p)
            result.done.append("Ausgabe: \(Fmt.euro(amount)) (\(src.label))")

        case "update_settings":
            let s = AppSettings.current(ctx)
            if let v = int(a["order_weekday"]) { s.orderWeekday = v }
            if let v = int(a["delivery_weekday"]) { s.deliveryWeekday = v }
            if let v = str(a["delivery_window"]) { s.deliveryWindow = v }
            if let v = int(a["cart_fill_weekday"]) { s.cartFillWeekday = v }
            if let t = time(a["cart_fill_time"]) { s.cartFillHour = t.0; s.cartFillMinute = t.1 }
            if let v = int(a["metzger_weekday"]) { s.metzgerWeekday = v }
            if let v = num(a["budget"]) { s.budget = v }
            if let t = time(a["check_time"]) { s.checkHour = t.0; s.checkMinute = t.1 }
            if let v = a["check_enabled"] as? Bool { s.checkEnabled = v }
            if let v = a["low_stock_enabled"] as? Bool { s.lowStockEnabled = v }
            if let v = num(a["kcal_goal"]) { s.kcalGoal = v }
            if let v = num(a["protein_goal"]) { s.proteinGoal = v }
            if let v = num(a["carbs_goal"]) { s.carbsGoal = v }
            if let v = num(a["fat_goal"]) { s.fatGoal = v }
            result.done.append("Einstellungen geändert")

        case "navigate":
            switch str(a["tab"]) ?? "" {
            case "vorrat": Router.shared.tab = .vorrat
            case "mahlzeiten": Router.shared.tab = .mahlzeiten
            case "plan": Router.shared.tab = .plan
            case "einkauf": Router.shared.tab = .einkauf
            case "ausgaben": Router.shared.tab = .ausgaben
            case "check": Router.shared.openCheckAfterAssistant = true
            default: break
            }

        default:
            if !type.isEmpty { fail("Unbekannte Aktion „\(type)“", &result) }
        }
    }

    private static func applyFields(_ a: [String: Any], to p: Product, ctx: ModelContext) {
        if let v = str(a["store"]) { p.storeName = v }
        if let v = str(a["link"]) { p.linkURL = v }
        if let v = num(a["warn_at"]) { p.warnAt = max(0, v) }
        if let v = num(a["refill_to"]) { p.refillTo = max(0, v) }
        if let v = num(a["package_size"]), v > 0 { p.packageSize = v }
        if let v = num(a["grams_per_unit"]) { p.gramsPerUnit = v }
        if let v = num(a["usage_per_week"]) { p.usagePerWeek = max(0, v) }
        if let v = a["is_food"] as? Bool { p.isFood = v }
        if let v = int(a["lead_days"]) { p.leadDays = max(1, v) }
        if let v = num(a["kcal100"]) { p.kcal100 = v }
        if let v = num(a["protein100"]) { p.protein100 = v }
        if let v = num(a["carbs100"]) { p.carbs100 = v }
        if let v = num(a["fat100"]) { p.fat100 = v }
        if let v = num(a["price"]) { p.updatePrice(v, context: ctx) }
        if let v = num(a["stock"]) { p.setStock(v) }
        if p.refillTo < p.warnAt { p.refillTo = p.warnAt }
        if p.unit.isMass { p.gramsPerUnit = 1 }
    }

    // MARK: Suchen

    private static func match(_ ref: Any?, id: UUID, name: String) -> Int {
        guard let r = (ref as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return 0 }
        let n = name.lowercased(with: Fmt.de)
        if id.uuidString.lowercased().hasPrefix(r) { return 4 }
        if n == r { return 3 }
        if n.contains(r) || r.contains(n) { return 2 }
        return 0
    }

    private static func best<T>(_ items: [T], _ ref: Any?, id: (T) -> UUID, name: (T) -> String) -> T? {
        items.map { ($0, match(ref, id: id($0), name: name($0))) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func findProduct(_ ref: Any?, _ ctx: ModelContext) -> Product? {
        best(((try? ctx.fetch(FetchDescriptor<Product>())) ?? []).filter { !$0.isDeleted }, ref, id: \.uuid, name: \.name)
    }
    private static func findTemplate(_ ref: Any?, _ ctx: ModelContext) -> MealTemplate? {
        best(((try? ctx.fetch(FetchDescriptor<MealTemplate>())) ?? []).filter { !$0.isDeleted }, ref, id: \.uuid, name: \.name)
    }
    private static func findListItem(_ ref: Any?, _ ctx: ModelContext) -> ListItem? {
        best(((try? ctx.fetch(FetchDescriptor<ListItem>())) ?? []).filter { !$0.isDeleted }, ref, id: \.uuid, name: \.name)
    }
    private static func findWish(_ ref: Any?, _ ctx: ModelContext) -> WishItem? {
        best(((try? ctx.fetch(FetchDescriptor<WishItem>())) ?? []).filter { !$0.isDeleted }, ref, id: \.uuid, name: \.name)
    }

    // MARK: Werte lesen

    private static func fail(_ s: String, _ r: inout AssistantResult) { r.failed.append(s) }

    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return NumberField.parse(s) }
        return nil
    }
    private static func numString(_ v: Any?) -> String? { num(v).map { Fmt.number($0) } }
    private static func int(_ v: Any?) -> Int? { num(v).map { Int($0) } }
    private static func date(_ v: Any?) -> Date? {
        guard let s = str(v) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
    private static func time(_ v: Any?) -> (Int, Int)? {
        guard let s = str(v) else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard let h = parts.first, (0...23).contains(h) else { return nil }
        return (h, parts.count > 1 ? min(max(parts[1], 0), 59) : 0)
    }
}
