import Foundation
import SwiftData

/// Rechnet aus Bestand + Wochenplan, ob ein Produkt bis zum nächsten Einkauf reicht.
struct Forecast {
    let products: [Product]
    let plan: [PlanEntry]
    let settings: AppSettings
    /// Mahlzeiten-Einträge (es reichen die von heute).
    let logs: [MealLog]
    var now: Date = Date()

    private var cal: Calendar { Calendar.current }

    enum Level { case ok, knapp, leer }

    struct Status {
        let level: Level
        /// Erwarteter Bestand am Tag des nächsten Einkaufs.
        let projected: Double
        let restockDate: Date
        /// Benötigte Packungen (0, wenn nichts nötig ist).
        let packages: Int
        /// Menge, die dadurch dazukommt.
        let orderAmount: Double
        var needsRestock: Bool { packages > 0 }
    }

    // MARK: Termine

    /// Nächster Tag mit diesem Wochentag (nach heute).
    func nextDate(isoWeekday: Int, after date: Date) -> Date {
        let start = cal.startOfDay(for: date)
        for i in 1...7 {
            let d = cal.date(byAdding: .day, value: i, to: start)!
            if cal.isoWeekday(d) == isoWeekday { return d }
        }
        return start
    }

    var nextDelivery: Date { nextDate(isoWeekday: settings.deliveryWeekday, after: now) }
    var nextMetzger: Date { nextDate(isoWeekday: settings.metzgerWeekday, after: now) }

    func restockDate(for p: Product) -> Date {
        p.source == .metzger ? nextMetzger : nextDelivery
    }

    // MARK: Verbrauch

    private var loggedPlanSlotsToday: Set<String> {
        Set(logs.filter { $0.fromPlan && cal.isDate($0.date, inSameDayAs: now) }.map(\.slotRaw))
    }

    /// Geplanter Verbrauch eines Produkts von jetzt bis (exklusive) `end`.
    func plannedUse(of p: Product, until end: Date) -> Double {
        let done = loggedPlanSlotsToday
        var total = 0.0
        var day = cal.startOfDay(for: now)
        while day < end {
            let iso = cal.isoWeekday(day)
            let isToday = cal.isDate(day, inSameDayAs: now)
            for entry in plan where entry.weekday == iso {
                if isToday && done.contains(entry.slotRaw) { continue }
                guard let t = entry.template else { continue }
                for ing in t.ingredients where ing.product?.persistentModelID == p.persistentModelID {
                    total += ing.amount
                }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return total
    }

    func status(_ p: Product) -> Status {
        let date = restockDate(for: p)
        let projected = p.stock - plannedUse(of: p, until: date)
        let eps = 0.0001
        let needs = projected <= p.warnAt + eps || p.stock <= p.warnAt + eps
        let level: Level = p.stock <= eps ? .leer : (needs ? .knapp : .ok)
        var packages = 0
        var amount = 0.0
        if needs {
            let need = max(p.refillTo - max(projected, 0), 0)
            let size = max(p.packageSize, eps)
            packages = max(1, Int((need / size).rounded(.up)))
            amount = Double(packages) * size
        }
        return Status(level: level, projected: projected, restockDate: date, packages: packages, orderAmount: amount)
    }

    // MARK: Listen

    func shoppingList(for source: Source) -> [(product: Product, status: Status)] {
        products
            .filter { $0.source == source }
            .map { ($0, status($0)) }
            .filter { $0.1.needsRestock }
            .sorted { $0.0.sortIndex < $1.0.sortIndex }
            .map { (product: $0.0, status: $0.1) }
    }

    /// Produkte für den täglichen Check: nur die, bei denen die Rechnung unsicher ist.
    func checkCandidates(limit: Int = 6) -> [Product] {
        let soon = cal.date(byAdding: .day, value: 3, to: now)!
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now)!
        let inTwoDays = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!

        func score(_ p: Product) -> Int {
            var s = 0
            if status(p).level != .ok { s += 4 }
            if let bb = p.bestBefore, bb <= soon { s += 3 }
            if let c = p.lastCorrectedAt, c >= weekAgo { s += 2 }
            if plannedUse(of: p, until: inTwoDays) > 0 { s += 1 }
            return s
        }

        var picked = products
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        if picked.count < 3 {
            let rest = products
                .filter { p in !picked.contains { $0.persistentModelID == p.persistentModelID } }
                .sorted { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }
            picked += rest.prefix(3 - picked.count)
        }
        return Array(picked.prefix(limit))
    }

    // MARK: Tageswerte

    func todayTotals() -> (nutrition: Nutrition, cost: Double) {
        logs.filter { cal.isDate($0.date, inSameDayAs: now) }.reduce((Nutrition(), 0.0)) { acc, l in
            (acc.0 + Nutrition(kcal: l.kcal, protein: l.protein, carbs: l.carbs, fat: l.fat), acc.1 + l.cost)
        }
    }
}

// MARK: - Budget

struct BudgetStats {
    let monthStart: Date
    let spent: Double
    let bySource: [Source: Double]
    let forecast: Double
    let budget: Double
    let isCurrentMonth: Bool
    let perWeek: Double
    var remaining: Double { budget - spent }

    static func make(purchases: [Purchase], budget: Double, month: Date, now: Date = Date()) -> BudgetStats {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let end = cal.date(byAdding: .month, value: 1, to: start)!
        let inMonth = purchases.filter { $0.date >= start && $0.date < end }
        let spent = inMonth.reduce(0) { $0 + $1.total }
        var by: [Source: Double] = [:]
        for p in inMonth { by[p.source, default: 0] += p.total }

        let isCurrent = now >= start && now < end
        let daysInMonth = Double(cal.range(of: .day, in: .month, for: start)?.count ?? 30)
        let daysElapsed: Double = isCurrent ? Double(cal.component(.day, from: now)) : daysInMonth
        let forecast = isCurrent ? spent / max(daysElapsed, 1) * daysInMonth : spent
        let perWeek = spent / max(daysElapsed / 7, 1)

        return BudgetStats(monthStart: start, spent: spent, bySource: by, forecast: forecast, budget: budget,
                           isCurrentMonth: isCurrent, perWeek: perWeek)
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
}
