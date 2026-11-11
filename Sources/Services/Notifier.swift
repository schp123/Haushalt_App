import Foundation
import SwiftData
import UserNotifications

/// Alle Benachrichtigungen sind lokal: sie funktionieren auch bei selbst installierten Apps.
@MainActor
enum Notifier {
    private static var center: UNUserNotificationCenter { .current() }

    static func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Nach jeder Änderung aufrufen: prüft Bestände, Budget, MHD und plant Erinnerungen neu.
    static func evaluate(_ context: ModelContext) {
        let settings = AppSettings.current(context)
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let plan = (try? context.fetch(FetchDescriptor<PlanEntry>())) ?? []
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let logs = (try? context.fetch(FetchDescriptor<MealLog>(predicate: #Predicate { $0.date >= startOfDay }))) ?? []
        let purchases = (try? context.fetch(FetchDescriptor<Purchase>())) ?? []
        let wishes = (try? context.fetch(FetchDescriptor<WishItem>())) ?? []
        let forecast = Forecast(products: products, plan: plan, settings: settings, logs: logs)

        scheduleDailyCheck(settings)
        scheduleCartFill(settings, count: forecast.shoppingList(for: .rewe).count)
        checkLowStock(products: products, forecast: forecast, settings: settings)
        scheduleBestBefore(products)
        scheduleMetzger(forecast: forecast, settings: settings)
        checkBudget(purchases: purchases, settings: settings)
        scheduleWishes(wishes)
        try? context.save()
        SyncEngine.shared.scheduleSync()
    }

    // MARK: Täglicher Check

    static func scheduleDailyCheck(_ s: AppSettings) {
        center.removePendingNotificationRequests(withIdentifiers: ["daily-check"])
        guard s.checkEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kurzer Vorrats-Check"
        content.body = "Was ist noch da? Dauert etwa 20 Sekunden."
        content.sound = .default
        content.userInfo = ["route": "check"]
        var dc = DateComponents()
        dc.hour = s.checkHour
        dc.minute = s.checkMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        center.add(UNNotificationRequest(identifier: "daily-check", content: content, trigger: trigger))
    }

    // MARK: REWE-Warenkorb (wöchentlich)

    static func scheduleCartFill(_ s: AppSettings, count: Int) {
        center.removePendingNotificationRequests(withIdentifiers: ["rewe-cart"])
        let content = UNMutableNotificationContent()
        content.title = "🛒 Zeit für den REWE-Warenkorb"
        content.body = count > 0
            ? "\(count) Artikel stehen auf der REWE-Liste. Tippen zum Befüllen."
            : "Tippen, um die REWE-Liste in den Warenkorb zu legen."
        content.sound = .default
        content.userInfo = ["route": "rewecart"]
        var dc = DateComponents()
        dc.weekday = s.cartFillWeekday % 7 + 1 // 1 = Sonntag bei Apple
        dc.hour = s.cartFillHour
        dc.minute = s.cartFillMinute
        center.add(UNNotificationRequest(identifier: "rewe-cart", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)))
    }

    // MARK: Knapp-Warnung

    private static func checkLowStock(products: [Product], forecast: Forecast, settings: AppSettings) {
        for p in products {
            let st = forecast.status(p)
            if st.level == .ok && !st.needsRestock {
                p.lowNotifiedAt = nil
                continue
            }
            guard settings.lowStockEnabled, p.lowNotifiedAt == nil else { continue }
            p.lowNotifiedAt = Date()
            let day = Fmt.weekdayShort(Calendar.current.isoWeekday(st.restockDate))
            let body: String
            if p.source == .sonstiges {
                let days = p.usagePerWeek > 0
                    ? Int((p.currentStock() / p.usagePerWeek * 7).rounded(.down))
                    : nil
                let reach = days.map { "reicht noch ca. \($0) Tage" } ?? "wird knapp"
                body = "\(p.name) \(reach) – bei \(p.whereToBuy) nachkaufen."
            } else if st.level == .leer {
                body = "\(p.name) ist leer – steht auf der \(p.source.listName)."
            } else {
                body = "\(p.name) reicht nicht bis \(day) – steht auf der \(p.source.listName)."
            }
            notifyNow(id: "low-\(p.uuid.uuidString)", title: "\(p.emoji) Wird knapp", body: body, route: "einkauf")
        }
    }

    // MARK: Mindesthaltbarkeit

    private static func scheduleBestBefore(_ products: [Product]) {
        center.removePendingNotificationRequests(withIdentifiers: products.map { "mhd-\($0.uuid.uuidString)" })
        let cal = Calendar.current
        for p in products {
            guard let bb = p.bestBefore, p.currentStock() > 0,
                  let dayBefore = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: bb)),
                  let fireDate = cal.date(bySettingHour: 9, minute: 0, second: 0, of: dayBefore),
                  fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(p.emoji) \(p.name) läuft morgen ab"
            content.body = "Am besten heute oder morgen einplanen."
            content.sound = .default
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            center.add(UNNotificationRequest(identifier: "mhd-\(p.uuid.uuidString)", content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    // MARK: Metzger

    private static func scheduleMetzger(forecast: Forecast, settings: AppSettings) {
        center.removePendingNotificationRequests(withIdentifiers: ["metzger"])
        let list = forecast.shoppingList(for: .metzger)
        guard !list.isEmpty else { return }
        let cal = Calendar.current
        guard let fire = cal.date(bySettingHour: settings.metzgerHour, minute: 0, second: 0, of: forecast.nextMetzger) else { return }
        let content = UNMutableNotificationContent()
        content.title = "🥩 Heute zum Metzger"
        content.body = list.map { "\($0.product.name) (\(Fmt.amount($0.status.orderAmount, $0.product.unit)))" }.joined(separator: ", ")
        content.sound = .default
        content.userInfo = ["route": "einkauf"]
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: "metzger", content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    // MARK: Budget

    private static func checkBudget(purchases: [Purchase], settings: AppSettings) {
        let stats = BudgetStats.make(purchases: purchases, budget: settings.budget, month: Date())
        let key = BudgetStats.monthKey(Date())
        guard settings.budget > 0,
              stats.forecast > settings.budget * settings.budgetWarnPercent / 100,
              settings.lastBudgetWarnKey != key else { return }
        settings.lastBudgetWarnKey = key
        notifyNow(id: "budget-\(key)", title: "💶 Budget wird eng",
                  body: "Prognose für diesen Monat: \(Fmt.euro(stats.forecast)) von \(Fmt.euro(settings.budget)).",
                  route: "ausgaben")
    }

    // MARK: Wunschliste

    private static func scheduleWishes(_ wishes: [WishItem]) {
        center.removePendingNotificationRequests(withIdentifiers: wishes.map { "wish-\($0.uuid.uuidString)" })
        let cal = Calendar.current
        for w in wishes where !w.done {
            guard let due = w.dueDate,
                  let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due),
                  fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "🎁 \(w.name) besorgen"
            content.body = w.storeName.isEmpty ? "Steht heute auf der Wunschliste." : "Bei \(w.storeName) – steht heute auf der Wunschliste."
            content.sound = .default
            content.userInfo = ["route": "einkauf"]
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(identifier: "wish-\(w.uuid.uuidString)", content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    // MARK: Helfer

    static func notifyNow(id: String, title: String, body: String, route: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let route { content.userInfo = ["route": route] }
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }
}
