import Foundation
import SwiftData
import SwiftUI

// MARK: - Enums (als Strings gespeichert, damit SwiftData sie problemlos ablegt)

enum Source: String, CaseIterable, Identifiable, Codable {
    case rewe, metzger, sonstiges
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rewe: "REWE"
        case .metzger: "Metzger"
        case .sonstiges: "Sonstiges"
        }
    }
    var listName: String {
        switch self {
        case .rewe: "REWE-Liste"
        case .metzger: "Metzger-Liste"
        case .sonstiges: "Einkaufsliste"
        }
    }
}

enum StockUnit: String, CaseIterable, Identifiable, Codable {
    case stueck, gramm, milliliter, becher, packung
    var id: String { rawValue }
    var short: String {
        switch self {
        case .stueck: "Stk"
        case .gramm: "g"
        case .milliliter: "ml"
        case .becher: "Becher"
        case .packung: "Pkg"
        }
    }
    var label: String {
        switch self {
        case .stueck: "Stück"
        case .gramm: "Gramm"
        case .milliliter: "Milliliter"
        case .becher: "Becher"
        case .packung: "Packung"
        }
    }
    /// Gramm/Milliliter: Nährwerte direkt pro Menge, sonst über "Gramm pro Einheit".
    var isMass: Bool { self == .gramm || self == .milliliter }
    /// Sinnvolle Schrittweite für Plus/Minus.
    var step: Double { isMass ? 50 : 1 }
}

enum MealSlot: String, CaseIterable, Identifiable, Codable {
    case fruehstueck, mittag, snack, abend
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fruehstueck: "Frühstück"
        case .mittag: "Mittag"
        case .snack: "Snack"
        case .abend: "Abendessen"
        }
    }
    var order: Int { MealSlot.allCases.firstIndex(of: self) ?? 0 }
    /// Passender Slot für die aktuelle Uhrzeit.
    static func forNow(_ date: Date = Date()) -> MealSlot {
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case ..<11: return .fruehstueck
        case ..<15: return .mittag
        case ..<17: return .snack
        default: return .abend
        }
    }
}

struct Nutrition {
    var kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
    static func + (a: Nutrition, b: Nutrition) -> Nutrition {
        Nutrition(kcal: a.kcal + b.kcal, protein: a.protein + b.protein, carbs: a.carbs + b.carbs, fat: a.fat + b.fat)
    }
}

// MARK: - Produkt

@Model
final class Product {
    var uuid: UUID = UUID()
    var name: String = ""
    var emoji: String = "🛒"
    var tintHex: String = "EFEEE9"
    var sourceRaw: String = Source.rewe.rawValue
    var unitRaw: String = StockUnit.stueck.rawValue
    /// Aktueller Bestand in der Einheit des Produkts.
    var stock: Double = 0
    /// Ab diesem Bestand (jetzt oder zur Lieferung) wird gewarnt.
    var warnAt: Double = 1
    /// Auf diese Menge wird nach der Lieferung aufgefüllt.
    var refillTo: Double = 3
    /// Menge pro Packung (in der Einheit des Produkts).
    var packageSize: Double = 1
    /// Gramm pro Einheit (nur für Stück/Becher/Packung relevant).
    var gramsPerUnit: Double = 100
    var kcal100: Double = 0
    var protein100: Double = 0
    var carbs100: Double = 0
    var fat100: Double = 0
    /// Preis pro Packung, 0 = unbekannt.
    var price: Double = 0
    var reweArticleNumber: String = ""
    var reweURL: String = ""
    var barcode: String = ""
    var fallbackName: String = ""
    var sortIndex: Int = 0
    var lastCheckedAt: Date? = nil
    var lastCorrectedAt: Date? = nil
    var lowNotifiedAt: Date? = nil
    var bestBefore: Date? = nil
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \PriceRecord.product)
    var priceHistory: [PriceRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.product)
    var usedIn: [Ingredient] = []

    init(name: String, emoji: String = "🛒", source: Source = .rewe, unit: StockUnit = .stueck) {
        self.name = name
        self.emoji = emoji
        self.sourceRaw = source.rawValue
        self.unitRaw = unit.rawValue
        self.tintHex = Theme.tintHex(for: name)
        self.createdAt = Date()
    }

    var source: Source {
        get { Source(rawValue: sourceRaw) ?? .rewe }
        set { sourceRaw = newValue.rawValue }
    }
    var unit: StockUnit {
        get { StockUnit(rawValue: unitRaw) ?? .stueck }
        set { unitRaw = newValue.rawValue }
    }
    var tint: Color { Color(hex: tintHex) }

    func grams(for amount: Double) -> Double { unit.isMass ? amount : amount * gramsPerUnit }

    func nutrition(for amount: Double) -> Nutrition {
        let f = grams(for: amount) / 100
        return Nutrition(kcal: kcal100 * f, protein: protein100 * f, carbs: carbs100 * f, fat: fat100 * f)
    }

    func cost(for amount: Double) -> Double {
        guard price > 0, packageSize > 0 else { return 0 }
        return price / packageSize * amount
    }

    /// Preis ändern und im Verlauf festhalten.
    func updatePrice(_ newPrice: Double, context: ModelContext) {
        guard newPrice > 0, abs(newPrice - price) > 0.001 else { return }
        price = newPrice
        let record = PriceRecord(date: Date(), price: newPrice)
        context.insert(record)
        record.product = self
    }
}

@Model
final class PriceRecord {
    var date: Date = Date()
    var price: Double = 0
    var product: Product?
    init(date: Date, price: Double) {
        self.date = date
        self.price = price
    }
}

// MARK: - Mahlzeiten & Wochenplan

@Model
final class MealTemplate {
    var uuid: UUID = UUID()
    var name: String = ""
    var emoji: String = "🍽️"
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.template)
    var ingredients: [Ingredient] = []

    @Relationship(deleteRule: .cascade, inverse: \PlanEntry.template)
    var planEntries: [PlanEntry] = []

    init(name: String, emoji: String = "🍽️") {
        self.name = name
        self.emoji = emoji
        self.createdAt = Date()
    }

    var nutrition: Nutrition {
        ingredients.reduce(Nutrition()) { acc, ing in
            guard let p = ing.product else { return acc }
            return acc + p.nutrition(for: ing.amount)
        }
    }
    var cost: Double {
        ingredients.reduce(0) { $0 + ($1.product?.cost(for: $1.amount) ?? 0) }
    }
}

@Model
final class Ingredient {
    var amount: Double = 0
    var product: Product?
    var template: MealTemplate?
    init(amount: Double) { self.amount = amount }
}

@Model
final class PlanEntry {
    /// 1 = Montag … 7 = Sonntag
    var weekday: Int = 1
    var slotRaw: String = MealSlot.mittag.rawValue
    var template: MealTemplate?
    init(weekday: Int, slot: MealSlot) {
        self.weekday = weekday
        self.slotRaw = slot.rawValue
    }
    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .mittag }
}

@Model
final class MealLog {
    var date: Date = Date()
    var slotRaw: String = MealSlot.mittag.rawValue
    var name: String = ""
    var emoji: String = "🍽️"
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var cost: Double = 0
    var fromPlan: Bool = false
    init(date: Date, slot: MealSlot, name: String, emoji: String, nutrition: Nutrition, cost: Double, fromPlan: Bool) {
        self.date = date
        self.slotRaw = slot.rawValue
        self.name = name
        self.emoji = emoji
        self.kcal = nutrition.kcal
        self.protein = nutrition.protein
        self.carbs = nutrition.carbs
        self.fat = nutrition.fat
        self.cost = cost
        self.fromPlan = fromPlan
    }
    var slot: MealSlot { MealSlot(rawValue: slotRaw) ?? .mittag }
}

// MARK: - Ausgaben

@Model
final class Purchase {
    var date: Date = Date()
    var sourceRaw: String = Source.rewe.rawValue
    var total: Double = 0
    var itemCount: Int = 0
    var note: String = ""
    init(date: Date, source: Source, total: Double, itemCount: Int = 0, note: String = "") {
        self.date = date
        self.sourceRaw = source.rawValue
        self.total = total
        self.itemCount = itemCount
        self.note = note
    }
    var source: Source { Source(rawValue: sourceRaw) ?? .rewe }
}

// MARK: - Einstellungen

@Model
final class AppSettings {
    // REWE (Wochentage: 1 = Montag … 7 = Sonntag)
    var orderWeekday: Int = 4
    var deliveryWeekday: Int = 5
    var deliveryWindow: String = "8–10 Uhr"
    var cartFillWeekday: Int = 3
    var cartFillHour: Int = 20
    var cartFillMinute: Int = 0
    // Metzger
    var metzgerWeekday: Int = 6
    var metzgerHour: Int = 9
    // Budget
    var budget: Double = 800
    var budgetWarnPercent: Double = 90
    var lastBudgetWarnKey: String = ""
    // Erinnerungen
    var checkEnabled: Bool = true
    var checkHour: Int = 18
    var checkMinute: Int = 0
    var lowStockEnabled: Bool = true
    // Tagesziele
    var kcalGoal: Double = 2200
    var proteinGoal: Double = 160
    var carbsGoal: Double = 230
    var fatGoal: Double = 70

    init() {}

    @MainActor
    static func current(_ context: ModelContext) -> AppSettings {
        if let s = try? context.fetch(FetchDescriptor<AppSettings>()).first { return s }
        let s = AppSettings()
        context.insert(s)
        try? context.save()
        return s
    }
}
