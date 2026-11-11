import Foundation
import SwiftData
import CryptoKit
import Observation

// MARK: - Lokaler Sync-Stand (nur auf diesem Gerät)

@Model
final class SyncMeta {
    @Attribute(.unique) var key: String = ""
    var hash: String = ""
    init(key: String, hash: String) {
        self.key = key
        self.hash = hash
    }
}

// MARK: - Verbindung (Supabase-URL, Schlüssel, Haushalt)

struct SyncConfig: Codable, Equatable {
    var url: String
    var key: String
    var household: UUID

    private static let storeKey = "sync.config"

    static func load() -> SyncConfig? {
        guard let d = UserDefaults.standard.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(SyncConfig.self, from: d)
    }

    static func save(_ c: SyncConfig?) {
        if let c, let d = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(d, forKey: storeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storeKey)
        }
        UserDefaults.standard.removeObject(forKey: "sync.cursor")
    }

    /// Einladungscode für das zweite iPhone (enthält URL, Schlüssel und Haushalt).
    var inviteCode: String {
        let payload = ["u": url, "k": key, "h": household.uuidString]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return "KAMMER-" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init(url: String, key: String, household: UUID) {
        self.url = url
        self.key = key
        self.household = household
    }

    init?(inviteCode raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("KAMMER-") else { return nil }
        s = String(s.dropFirst(7)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let u = obj["u"], let k = obj["k"], let hs = obj["h"], let h = UUID(uuidString: hs) else { return nil }
        self.init(url: u, key: k, household: h)
    }
}

// MARK: - Datenformat in der Datenbank

enum RecordKind: String, CaseIterable {
    case settings, product, template, plan, meallog, purchase, wish, shoppinglist
    /// Reihenfolge beim Einspielen (Produkte vor Vorlagen vor Wochenplan).
    var order: Int { RecordKind.allCases.firstIndex(of: self) ?? 99 }
}

struct PricePoint: Codable { var date: Date; var price: Double }

struct ProductDTO: Codable {
    var name, emoji, tintHex, source, unit: String
    var stock: Double
    var stockSetAt: Date?
    var warnAt, refillTo, packageSize, gramsPerUnit: Double
    var kcal100, protein100, carbs100, fat100, price: Double
    var reweArticleNumber, reweURL, barcode, fallbackName: String
    var sortIndex: Int
    var lastCheckedAt, lastCorrectedAt, bestBefore: Date?
    var isFood: Bool
    var storeName, linkURL: String
    var photo: String?
    var usagePerWeek: Double
    var leadDays: Int
    var prices: [PricePoint]
}

struct IngredientDTO: Codable { var product: UUID; var amount: Double }
struct TemplateDTO: Codable { var name, emoji: String; var ingredients: [IngredientDTO] }
struct PlanDTO: Codable { var weekday: Int; var slot: String; var template: UUID? }
struct MealLogDTO: Codable {
    var date: Date; var slot, name, emoji: String
    var kcal, protein, carbs, fat, cost: Double
    var fromPlan: Bool
}
struct PurchaseDTO: Codable { var date: Date; var source: String; var total: Double; var itemCount: Int; var note: String }
struct WishDTO: Codable {
    var name, note, storeName, linkURL: String
    var photo: String?
    var price: Double
    var dueDate: Date?
    var done: Bool
    var doneAt: Date?
    var createdAt: Date
}
struct SettingsDTO: Codable {
    var orderWeekday, deliveryWeekday: Int
    var deliveryWindow: String
    var cartFillWeekday, cartFillHour, cartFillMinute, metzgerWeekday, metzgerHour: Int
    var budget, budgetWarnPercent: Double
    var checkEnabled: Bool
    var checkHour, checkMinute: Int
    var lowStockEnabled: Bool
    var kcalGoal, proteinGoal, carbsGoal, fatGoal: Double
}

/// Für die REWE-Automatik: die aktuelle Einkaufsliste (wird nur hochgeladen).
struct ShoppingItemDTO: Codable {
    var product: UUID
    var name: String
    var reweArticleNumber: String
    var reweURL: String
    var packages: Int
    var packageSize: Double
    var unit: String
    var fallbackName: String
    var store: String
    var link: String
}
struct ShoppingListDTO: Codable {
    var deliveryDate: Date
    var deliveryWindow: String
    var rewe: [ShoppingItemDTO]
    var metzger: [ShoppingItemDTO]
    var andere: [ShoppingItemDTO]
}

private struct LocalRecord {
    var kind: RecordKind
    var id: UUID
    var data: Data
    var hash: String
    var key: String { "\(kind.rawValue):\(id.uuidString)" }
}

// MARK: - Hilfen

enum StableID {
    /// Gleiche ID auf beiden iPhones, z. B. für „Montag Mittag“ oder die Einstellungen.
    static func make(_ name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func plan(_ weekday: Int, _ slot: String) -> UUID { make("plan-\(weekday)-\(slot)") }
    static let settings = make("settings")
    static let shoppingList = make("shoppinglist")
}

private enum Coding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncError: LocalizedError {
    case http(Int, String)
    case badURL
    var errorDescription: String? {
        switch self {
        case .badURL: return "Die Supabase-URL ist ungültig."
        case .http(let code, let body):
            if code == 404 || body.contains("records") && body.contains("does not exist") {
                return "Tabelle nicht gefunden – bitte zuerst supabase/schema.sql im SQL-Editor ausführen."
            }
            if code == 401 || code == 403 { return "Zugriff verweigert – Schlüssel prüfen (anon / publishable key)." }
            return "Server-Fehler \(code): \(body.prefix(160))"
        }
    }
}

// MARK: - Supabase (REST, ohne zusätzliche Bibliothek)

struct SupabaseClient {
    let config: SyncConfig

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                         prefer: String? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))) else { throw SyncError.badURL }
        comps.path = "/rest/v1/" + path
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw SyncError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(config.key, forHTTPHeaderField: "apikey")
        if config.key.hasPrefix("eyJ") { req.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        req.setValue(config.household.uuidString.lowercased(), forHTTPHeaderField: "x-household")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SyncError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    struct Remote {
        var kind: String
        var id: UUID
        var data: Data
        var deleted: Bool
        var updatedAt: String
    }

    func pull(since cursor: String?) async throws -> [Remote] {
        var q = [URLQueryItem(name: "select", value: "kind,id,data,deleted,updated_at"),
                 URLQueryItem(name: "household_id", value: "eq.\(config.household.uuidString.lowercased())"),
                 URLQueryItem(name: "order", value: "updated_at.asc"),
                 URLQueryItem(name: "limit", value: "5000")]
        if let cursor { q.append(URLQueryItem(name: "updated_at", value: "gt.\(cursor)")) }
        let data = try await send(try request("records", query: q))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let kind = row["kind"] as? String,
                  let ids = row["id"] as? String, let id = UUID(uuidString: ids),
                  let obj = row["data"],
                  let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return Remote(kind: kind, id: id, data: d, deleted: row["deleted"] as? Bool ?? false,
                          updatedAt: row["updated_at"] as? String ?? "")
        }
    }

    func push(_ items: [(kind: String, id: UUID, data: Data?, deleted: Bool)]) async throws {
        guard !items.isEmpty else { return }
        let rows: [[String: Any]] = items.map { item in
            var obj: Any = [String: Any]()
            if let d = item.data, let parsed = try? JSONSerialization.jsonObject(with: d) { obj = parsed }
            return ["household_id": config.household.uuidString.lowercased(), "kind": item.kind,
                    "id": item.id.uuidString.lowercased(), "data": obj, "deleted": item.deleted]
        }
        // In Paketen senden, damit Fotos die Anfrage nicht zu groß machen.
        var start = 0
        while start < rows.count {
            let chunk = Array(rows[start..<min(start + 40, rows.count)])
            let body = try JSONSerialization.data(withJSONObject: chunk)
            _ = try await send(try request("records", query: [URLQueryItem(name: "on_conflict", value: "household_id,id")],
                                           method: "POST", body: body, prefer: "resolution=merge-duplicates,return=minimal"))
            start += 40
        }
    }

    func check() async throws {
        _ = try await send(try request("records", query: [URLQueryItem(name: "select", value: "id"), URLQueryItem(name: "limit", value: "1")]))
    }
}

// MARK: - Sync-Engine

@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var config: SyncConfig? = SyncConfig.load()
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var pending: Task<Void, Never>?
    private var cursor: String? {
        get { UserDefaults.standard.string(forKey: "sync.cursor") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.cursor") }
    }

    var isConfigured: Bool { config != nil }

    func attach(_ context: ModelContext) { self.context = context }

    func connect(_ c: SyncConfig) async throws {
        try await SupabaseClient(config: c).check()
        SyncConfig.save(c)
        config = c
        if let ctx = context {
            // Alles neu abgleichen
            for m in (try? ctx.fetch(FetchDescriptor<SyncMeta>())) ?? [] { ctx.delete(m) }
            try? ctx.save()
        }
        await sync()
    }

    func disconnect() {
        SyncConfig.save(nil)
        config = nil
        lastSync = nil
        lastError = nil
        if let ctx = context {
            for m in (try? ctx.fetch(FetchDescriptor<SyncMeta>())) ?? [] { ctx.delete(m) }
            try? ctx.save()
        }
    }

    /// Kurz warten und dann abgleichen – mehrere Änderungen werden gebündelt.
    func scheduleSync() {
        guard isConfigured else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard let config, let ctx = context, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let client = SupabaseClient(config: config)
        do {
            ensureIDs(ctx)
            try await pull(client, ctx)
            try await push(client, ctx)
            try? ctx.save()
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: IDs

    private func ensureIDs(_ ctx: ModelContext) {
        var seen: Set<UUID> = []
        for e in (try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? [] {
            let id = StableID.plan(e.weekday, e.slotRaw)
            if seen.contains(id) { ctx.delete(e); continue }
            seen.insert(id)
            if e.uuid != id { e.uuid = id }
        }
        for l in (try? ctx.fetch(FetchDescriptor<MealLog>())) ?? [] where l.uuid == nil { l.uuid = UUID() }
        for p in (try? ctx.fetch(FetchDescriptor<Purchase>())) ?? [] where p.uuid == nil { p.uuid = UUID() }
    }

    // MARK: Lokale Daten → Datensätze

    private func localRecords(_ ctx: ModelContext) -> [LocalRecord] {
        var out: [LocalRecord] = []
        func add<T: Encodable>(_ kind: RecordKind, _ id: UUID, _ dto: T) {
            guard let data = try? Coding.encoder.encode(dto) else { return }
            out.append(LocalRecord(kind: kind, id: id, data: data, hash: Coding.hash(data)))
        }
        let products = (try? ctx.fetch(FetchDescriptor<Product>())) ?? []
        for p in products { add(.product, p.uuid, dto(p)) }
        for t in (try? ctx.fetch(FetchDescriptor<MealTemplate>())) ?? [] {
            let ings = t.ingredients.compactMap { i in i.product.map { IngredientDTO(product: $0.uuid, amount: i.amount) } }
                .sorted { ($0.product.uuidString, $0.amount) < ($1.product.uuidString, $1.amount) }
            add(.template, t.uuid, TemplateDTO(name: t.name, emoji: t.emoji, ingredients: ings))
        }
        let plan = (try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? []
        for e in plan {
            add(.plan, e.uuid ?? StableID.plan(e.weekday, e.slotRaw), PlanDTO(weekday: e.weekday, slot: e.slotRaw, template: e.template?.uuid))
        }
        let logs = (try? ctx.fetch(FetchDescriptor<MealLog>())) ?? []
        for l in logs {
            guard let id = l.uuid else { continue }
            add(.meallog, id, MealLogDTO(date: l.date, slot: l.slotRaw, name: l.name, emoji: l.emoji, kcal: l.kcal,
                                         protein: l.protein, carbs: l.carbs, fat: l.fat, cost: l.cost, fromPlan: l.fromPlan))
        }
        for p in (try? ctx.fetch(FetchDescriptor<Purchase>())) ?? [] {
            guard let id = p.uuid else { continue }
            add(.purchase, id, PurchaseDTO(date: p.date, source: p.sourceRaw, total: p.total, itemCount: p.itemCount, note: p.note))
        }
        for w in (try? ctx.fetch(FetchDescriptor<WishItem>())) ?? [] {
            add(.wish, w.uuid, WishDTO(name: w.name, note: w.note, storeName: w.storeName, linkURL: w.linkURL,
                                       photo: w.photo?.base64EncodedString(), price: w.price, dueDate: w.dueDate,
                                       done: w.done, doneAt: w.doneAt, createdAt: w.createdAt))
        }
        let s = AppSettings.current(ctx)
        add(.settings, StableID.settings, dto(s))

        // Einkaufsliste für die REWE-Automatik
        let f = Forecast(products: products, plan: plan, settings: s, logs: logs)
        func items(_ src: Source) -> [ShoppingItemDTO] {
            f.shoppingList(for: src).map { e in
                ShoppingItemDTO(product: e.product.uuid, name: e.product.name, reweArticleNumber: e.product.reweArticleNumber,
                                reweURL: e.product.reweURL, packages: e.status.packages, packageSize: e.product.packageSize,
                                unit: e.product.unit.label, fallbackName: e.product.fallbackName,
                                store: e.product.whereToBuy, link: e.product.linkURL)
            }
        }
        add(.shoppinglist, StableID.shoppingList,
            ShoppingListDTO(deliveryDate: f.nextDelivery, deliveryWindow: s.deliveryWindow,
                            rewe: items(.rewe), metzger: items(.metzger), andere: items(.sonstiges)))
        return out
    }

    private func dto(_ p: Product) -> ProductDTO {
        ProductDTO(name: p.name, emoji: p.emoji, tintHex: p.tintHex, source: p.sourceRaw, unit: p.unitRaw,
                   stock: p.stock, stockSetAt: p.stockSetAt, warnAt: p.warnAt, refillTo: p.refillTo,
                   packageSize: p.packageSize, gramsPerUnit: p.gramsPerUnit, kcal100: p.kcal100,
                   protein100: p.protein100, carbs100: p.carbs100, fat100: p.fat100, price: p.price,
                   reweArticleNumber: p.reweArticleNumber, reweURL: p.reweURL, barcode: p.barcode,
                   fallbackName: p.fallbackName, sortIndex: p.sortIndex, lastCheckedAt: p.lastCheckedAt,
                   lastCorrectedAt: p.lastCorrectedAt, bestBefore: p.bestBefore, isFood: p.isFood,
                   storeName: p.storeName, linkURL: p.linkURL, photo: p.photo?.base64EncodedString(),
                   usagePerWeek: p.usagePerWeek, leadDays: p.leadDays,
                   prices: p.priceHistory.sorted { $0.date < $1.date }.map { PricePoint(date: $0.date, price: $0.price) })
    }

    private func dto(_ s: AppSettings) -> SettingsDTO {
        SettingsDTO(orderWeekday: s.orderWeekday, deliveryWeekday: s.deliveryWeekday, deliveryWindow: s.deliveryWindow,
                    cartFillWeekday: s.cartFillWeekday, cartFillHour: s.cartFillHour, cartFillMinute: s.cartFillMinute,
                    metzgerWeekday: s.metzgerWeekday, metzgerHour: s.metzgerHour, budget: s.budget,
                    budgetWarnPercent: s.budgetWarnPercent, checkEnabled: s.checkEnabled, checkHour: s.checkHour,
                    checkMinute: s.checkMinute, lowStockEnabled: s.lowStockEnabled, kcalGoal: s.kcalGoal,
                    proteinGoal: s.proteinGoal, carbsGoal: s.carbsGoal, fatGoal: s.fatGoal)
    }

    // MARK: Pull

    private func pull(_ client: SupabaseClient, _ ctx: ModelContext) async throws {
        var since: String? = nil
        if let c = cursor, let d = Self.parse(c) {
            since = Self.format(d.addingTimeInterval(-10))
        }
        let rows = try await client.pull(since: since)
        guard !rows.isEmpty else { return }

        let local = Dictionary(localRecords(ctx).map { ($0.key, $0.hash) }, uniquingKeysWith: { a, _ in a })
        let metas = Dictionary(((try? ctx.fetch(FetchDescriptor<SyncMeta>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        var products = Dictionary(((try? ctx.fetch(FetchDescriptor<Product>())) ?? []).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var templates = Dictionary(((try? ctx.fetch(FetchDescriptor<MealTemplate>())) ?? []).map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })

        let sorted = rows.sorted { (RecordKind(rawValue: $0.kind)?.order ?? 99) < (RecordKind(rawValue: $1.kind)?.order ?? 99) }
        var newest = cursor ?? ""
        for r in rows where r.updatedAt > newest { newest = r.updatedAt }
        var skipped: Set<String> = []

        for r in sorted {
            guard let kind = RecordKind(rawValue: r.kind), kind != .shoppinglist else { continue }
            let key = "\(kind.rawValue):\(r.id.uuidString)"
            let meta = metas[key]
            // Lokal geändert und noch nicht hochgeladen? Dann gewinnt die lokale Änderung.
            if let lh = local[key], meta == nil || meta?.hash != lh {
                skipped.insert(key)
                continue
            }
            if r.deleted {
                delete(kind, r.id, ctx, products: &products, templates: &templates)
                if let meta { ctx.delete(meta) }
                continue
            }
            apply(kind, r.id, r.data, ctx, products: &products, templates: &templates)
        }
        try? ctx.save()

        // Sync-Stand für alles Eingespielte festhalten
        let afterLocal = Dictionary(localRecords(ctx).map { ($0.key, $0.hash) }, uniquingKeysWith: { a, _ in a })
        let metasNow = Dictionary(((try? ctx.fetch(FetchDescriptor<SyncMeta>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for r in sorted {
            guard let kind = RecordKind(rawValue: r.kind), kind != .shoppinglist, !r.deleted else { continue }
            let key = "\(kind.rawValue):\(r.id.uuidString)"
            guard let h = afterLocal[key] else { continue }
            if skipped.contains(key) { continue } // lokal geändert – wird gleich hochgeladen
            if let m = metasNow[key] { m.hash = h } else { ctx.insert(SyncMeta(key: key, hash: h)) }
        }
        if !newest.isEmpty { cursor = newest }
        try? ctx.save()
    }

    private func apply(_ kind: RecordKind, _ id: UUID, _ data: Data, _ ctx: ModelContext,
                       products: inout [UUID: Product], templates: inout [UUID: MealTemplate]) {
        let dec = Coding.decoder
        switch kind {
        case .product:
            guard let d = try? dec.decode(ProductDTO.self, from: data) else { return }
            let p = products[id] ?? {
                let n = Product(name: d.name)
                n.uuid = id
                ctx.insert(n)
                return n
            }()
            products[id] = p
            p.name = d.name; p.emoji = d.emoji; p.tintHex = d.tintHex; p.sourceRaw = d.source; p.unitRaw = d.unit
            p.stock = d.stock; p.stockSetAt = d.stockSetAt; p.warnAt = d.warnAt; p.refillTo = d.refillTo
            p.packageSize = d.packageSize; p.gramsPerUnit = d.gramsPerUnit
            p.kcal100 = d.kcal100; p.protein100 = d.protein100; p.carbs100 = d.carbs100; p.fat100 = d.fat100
            p.price = d.price; p.reweArticleNumber = d.reweArticleNumber; p.reweURL = d.reweURL; p.barcode = d.barcode
            p.fallbackName = d.fallbackName; p.sortIndex = d.sortIndex; p.lastCheckedAt = d.lastCheckedAt
            p.lastCorrectedAt = d.lastCorrectedAt; p.bestBefore = d.bestBefore; p.isFood = d.isFood
            p.storeName = d.storeName; p.linkURL = d.linkURL; p.photo = d.photo.flatMap { Data(base64Encoded: $0) }
            p.usagePerWeek = d.usagePerWeek; p.leadDays = d.leadDays
            let existing = p.priceHistory.sorted { $0.date < $1.date }.map { PricePoint(date: $0.date, price: $0.price) }
            if existing.map(\.price) != d.prices.map(\.price) {
                for r in p.priceHistory { ctx.delete(r) }
                for pp in d.prices {
                    let r = PriceRecord(date: pp.date, price: pp.price)
                    ctx.insert(r)
                    r.product = p
                }
            }
        case .template:
            guard let d = try? dec.decode(TemplateDTO.self, from: data) else { return }
            let t = templates[id] ?? {
                let n = MealTemplate(name: d.name)
                n.uuid = id
                ctx.insert(n)
                return n
            }()
            templates[id] = t
            t.name = d.name; t.emoji = d.emoji
            for i in t.ingredients { ctx.delete(i) }
            for i in d.ingredients {
                guard let p = products[i.product] else { continue }
                let ing = Ingredient(amount: i.amount)
                ctx.insert(ing)
                ing.product = p
                ing.template = t
            }
        case .plan:
            guard let d = try? dec.decode(PlanDTO.self, from: data) else { return }
            let all = (try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? []
            let e = all.first { $0.uuid == id || ($0.weekday == d.weekday && $0.slotRaw == d.slot) } ?? {
                let n = PlanEntry(weekday: d.weekday, slot: MealSlot(rawValue: d.slot) ?? .mittag)
                ctx.insert(n)
                return n
            }()
            e.uuid = id
            e.template = d.template.flatMap { templates[$0] }
        case .meallog:
            guard let d = try? dec.decode(MealLogDTO.self, from: data) else { return }
            let all = (try? ctx.fetch(FetchDescriptor<MealLog>())) ?? []
            let l = all.first { $0.uuid == id } ?? {
                let n = MealLog(date: d.date, slot: MealSlot(rawValue: d.slot) ?? .mittag, name: d.name, emoji: d.emoji,
                                nutrition: Nutrition(), cost: 0, fromPlan: d.fromPlan)
                n.uuid = id
                ctx.insert(n)
                return n
            }()
            l.date = d.date; l.slotRaw = d.slot; l.name = d.name; l.emoji = d.emoji
            l.kcal = d.kcal; l.protein = d.protein; l.carbs = d.carbs; l.fat = d.fat; l.cost = d.cost; l.fromPlan = d.fromPlan
        case .purchase:
            guard let d = try? dec.decode(PurchaseDTO.self, from: data) else { return }
            let all = (try? ctx.fetch(FetchDescriptor<Purchase>())) ?? []
            let p = all.first { $0.uuid == id } ?? {
                let n = Purchase(date: d.date, source: Source(rawValue: d.source) ?? .rewe, total: d.total)
                n.uuid = id
                ctx.insert(n)
                return n
            }()
            p.date = d.date; p.sourceRaw = d.source; p.total = d.total; p.itemCount = d.itemCount; p.note = d.note
        case .wish:
            guard let d = try? dec.decode(WishDTO.self, from: data) else { return }
            let all = (try? ctx.fetch(FetchDescriptor<WishItem>())) ?? []
            let w = all.first { $0.uuid == id } ?? {
                let n = WishItem(name: d.name)
                n.uuid = id
                ctx.insert(n)
                return n
            }()
            w.name = d.name; w.note = d.note; w.storeName = d.storeName; w.linkURL = d.linkURL
            w.photo = d.photo.flatMap { Data(base64Encoded: $0) }; w.price = d.price; w.dueDate = d.dueDate
            w.done = d.done; w.doneAt = d.doneAt; w.createdAt = d.createdAt
        case .settings:
            guard let d = try? dec.decode(SettingsDTO.self, from: data) else { return }
            let s = AppSettings.current(ctx)
            s.orderWeekday = d.orderWeekday; s.deliveryWeekday = d.deliveryWeekday; s.deliveryWindow = d.deliveryWindow
            s.cartFillWeekday = d.cartFillWeekday; s.cartFillHour = d.cartFillHour; s.cartFillMinute = d.cartFillMinute
            s.metzgerWeekday = d.metzgerWeekday; s.metzgerHour = d.metzgerHour; s.budget = d.budget
            s.budgetWarnPercent = d.budgetWarnPercent; s.checkEnabled = d.checkEnabled; s.checkHour = d.checkHour
            s.checkMinute = d.checkMinute; s.lowStockEnabled = d.lowStockEnabled; s.kcalGoal = d.kcalGoal
            s.proteinGoal = d.proteinGoal; s.carbsGoal = d.carbsGoal; s.fatGoal = d.fatGoal
        case .shoppinglist:
            break
        }
    }

    private func delete(_ kind: RecordKind, _ id: UUID, _ ctx: ModelContext,
                        products: inout [UUID: Product], templates: inout [UUID: MealTemplate]) {
        switch kind {
        case .product:
            if let p = products[id] { ctx.delete(p); products[id] = nil }
        case .template:
            if let t = templates[id] { ctx.delete(t); templates[id] = nil }
        case .plan:
            if let e = ((try? ctx.fetch(FetchDescriptor<PlanEntry>())) ?? []).first(where: { $0.uuid == id }) { ctx.delete(e) }
        case .meallog:
            if let l = ((try? ctx.fetch(FetchDescriptor<MealLog>())) ?? []).first(where: { $0.uuid == id }) { ctx.delete(l) }
        case .purchase:
            if let p = ((try? ctx.fetch(FetchDescriptor<Purchase>())) ?? []).first(where: { $0.uuid == id }) { ctx.delete(p) }
        case .wish:
            if let w = ((try? ctx.fetch(FetchDescriptor<WishItem>())) ?? []).first(where: { $0.uuid == id }) { ctx.delete(w) }
        case .settings, .shoppinglist:
            break
        }
    }

    // MARK: Push

    private func push(_ client: SupabaseClient, _ ctx: ModelContext) async throws {
        let records = localRecords(ctx)
        let metaList = (try? ctx.fetch(FetchDescriptor<SyncMeta>())) ?? []
        let metas = Dictionary(metaList.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let localKeys = Set(records.map(\.key))

        var changed: [LocalRecord] = []
        for r in records where metas[r.key]?.hash != r.hash { changed.append(r) }

        var deletions: [(kind: String, id: UUID)] = []
        for m in metaList where !localKeys.contains(m.key) {
            let parts = m.key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = UUID(uuidString: parts[1]) { deletions.append((parts[0], id)) }
        }

        let payload: [(kind: String, id: UUID, data: Data?, deleted: Bool)] = changed.map { (kind: $0.kind.rawValue, id: $0.id, data: Optional($0.data), deleted: false) }
            + deletions.map { (kind: $0.kind, id: $0.id, data: Data?.none, deleted: true) }
        try await client.push(payload)

        for r in changed {
            if let m = metas[r.key] { m.hash = r.hash } else { ctx.insert(SyncMeta(key: r.key, hash: r.hash)) }
        }
        for m in metaList where !localKeys.contains(m.key) { ctx.delete(m) }
    }

    // MARK: Zeit

    /// Server-Zeitstempel (z. B. 2026-11-11T10:51:20.123456+00:00) – auf Sekunden genau reicht.
    private static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    private static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
