import Foundation
import SwiftData

/// Beispiel-Basics zum Ausprobieren. Nährwerte sind grobe Richtwerte und lassen sich pro Produkt anpassen.
@MainActor
enum SampleData {
    static func load(into context: ModelContext) {
        func make(_ name: String, _ emoji: String, _ source: Source, _ unit: StockUnit,
                  stock: Double, warn: Double, refill: Double, pack: Double, gPerUnit: Double = 100,
                  kcal: Double, p: Double, c: Double, f: Double, index: Int) -> Product {
            let prod = Product(name: name, emoji: emoji, source: source, unit: unit)
            prod.setStock(stock)
            prod.warnAt = warn
            prod.refillTo = refill
            prod.packageSize = pack
            prod.gramsPerUnit = gPerUnit
            prod.kcal100 = kcal
            prod.protein100 = p
            prod.carbs100 = c
            prod.fat100 = f
            prod.sortIndex = index
            context.insert(prod)
            return prod
        }

        let eier = make("Eier", "🥚", .rewe, .stueck, stock: 6, warn: 4, refill: 10, pack: 10, gPerUnit: 60,
                        kcal: 155, p: 13, c: 1, f: 11, index: 0)
        let milch = make("Milch", "🥛", .rewe, .milliliter, stock: 0, warn: 500, refill: 2000, pack: 1000,
                         kcal: 64, p: 3.4, c: 4.8, f: 3.5, index: 1)
        let hafer = make("Haferflocken", "🌾", .rewe, .gramm, stock: 750, warn: 250, refill: 1000, pack: 500,
                         kcal: 370, p: 13.5, c: 59, f: 7, index: 2)
        let haehnchen = make("Hähnchenbrust", "🍗", .metzger, .gramm, stock: 0, warn: 300, refill: 1200, pack: 100,
                             kcal: 110, p: 23, c: 0, f: 1.5, index: 3)
        let reis = make("Reis", "🍚", .rewe, .gramm, stock: 900, warn: 300, refill: 1000, pack: 1000,
                        kcal: 350, p: 7, c: 78, f: 0.6, index: 4)
        let brokkoli = make("Brokkoli", "🥦", .rewe, .stueck, stock: 1, warn: 1, refill: 4, pack: 1, gPerUnit: 400,
                            kcal: 34, p: 2.8, c: 4, f: 0.4, index: 5)
        let apfel = make("Äpfel", "🍎", .rewe, .stueck, stock: 3, warn: 2, refill: 6, pack: 6, gPerUnit: 180,
                         kcal: 52, p: 0.3, c: 12, f: 0.2, index: 6)
        let skyr = make("Skyr", "🥣", .rewe, .becher, stock: 2, warn: 1, refill: 3, pack: 1, gPerUnit: 450,
                        kcal: 63, p: 11, c: 4, f: 0.2, index: 7)
        let avocado = make("Avocado", "🥑", .rewe, .stueck, stock: 2, warn: 1, refill: 3, pack: 1, gPerUnit: 150,
                           kcal: 160, p: 2, c: 2, f: 15, index: 8)

        func template(_ name: String, _ emoji: String, _ items: [(Product, Double)]) -> MealTemplate {
            let t = MealTemplate(name: name, emoji: emoji)
            context.insert(t)
            for (prod, amount) in items {
                let ing = Ingredient(amount: amount)
                context.insert(ing)
                ing.product = prod
                ing.template = t
            }
            return t
        }

        let fruehstueck = template("Haferflocken mit Skyr & Apfel", "🥣", [(hafer, 80), (skyr, 0.5), (apfel, 1), (milch, 150)])
        let bowl = template("Hähnchen-Reis-Bowl", "🍗", [(haehnchen, 200), (reis, 100), (brokkoli, 0.5)])
        let snack = template("3 Eier & Avocado", "🥚", [(eier, 3), (avocado, 0.5)])

        for day in 1...7 {
            let e1 = PlanEntry(weekday: day, slot: .fruehstueck); context.insert(e1); e1.template = fruehstueck
            let e2 = PlanEntry(weekday: day, slot: .mittag); context.insert(e2); e2.template = bowl
            let e3 = PlanEntry(weekday: day, slot: .snack); context.insert(e3); e3.template = snack
        }
        Notifier.evaluate(context)
    }
}
