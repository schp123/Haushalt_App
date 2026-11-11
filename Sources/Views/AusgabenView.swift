import SwiftUI
import SwiftData
import Charts

struct AusgabenView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]
    @Query(sort: \MealLog.date, order: .reverse) private var logs: [MealLog]
    @Query private var settingsList: [AppSettings]

    @State private var monthOffset = 0
    @State private var showAdd = false

    private var settings: AppSettings { settingsList.first ?? AppSettings() }
    private var cal: Calendar { .current }
    private var month: Date { cal.date(byAdding: .month, value: monthOffset, to: Date())! }

    var body: some View {
        let stats = BudgetStats.make(purchases: purchases, budget: settings.budget, month: month)
        let monthEnd = cal.date(byAdding: .month, value: 1, to: stats.monthStart)!
        let monthPurchases = purchases.filter { $0.date >= stats.monthStart && $0.date < monthEnd }
        let monthLogs = logs.filter { $0.date >= stats.monthStart && $0.date < monthEnd }
        let mealCost = monthLogs.reduce(0) { $0 + $1.cost }
        let protein = monthLogs.reduce(0) { $0 + $1.protein }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    budgetCard(stats)

                    HStack(spacing: 10) {
                        stat("pro Woche", Fmt.euro(stats.perWeek))
                        stat("pro Mahlzeit", monthLogs.isEmpty ? "–" : Fmt.euro(mealCost / Double(monthLogs.count)))
                        stat("€ / 100 g Protein", protein > 0 ? Fmt.euro(mealCost / protein * 100) : "–")
                    }

                    historyChart

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Einkäufe")
                        if monthPurchases.isEmpty {
                            Text("Noch keine Einkäufe in diesem Monat.")
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                .card(14, radius: 18)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(monthPurchases) { p in
                                    purchaseRow(p)
                                        .contextMenu {
                                            Button("Löschen", role: .destructive) { context.delete(p); Notifier.evaluate(context) }
                                        }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAdd) { PurchaseEditView(source: .metzger) }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lebensmittel-Budget").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                Text("Ausgaben").font(.system(size: 30, weight: .heavy))
            }
            Spacer()
            circleButton("chevron.left", "Vorheriger Monat") { monthOffset -= 1 }
            circleButton("chevron.right", "Nächster Monat") { monthOffset = min(0, monthOffset + 1) }
            circleButton("plus", "Ausgabe eintragen") { showAdd = true }
        }
        .padding(.top, 12)
    }

    private func budgetCard(_ s: BudgetStats) -> some View {
        let rewe = s.bySource[.rewe] ?? 0
        let metzger = s.bySource[.metzger] ?? 0
        let base = max(s.budget, s.spent, 1)
        return VStack(alignment: .leading, spacing: 12) {
            Text(Fmt.monthYear(s.monthStart)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mutedOnDark)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.euro(s.spent)).font(.system(size: 40, weight: .heavy))
                Text("von \(Fmt.euro(s.budget))").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.mutedOnDark)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.accent).frame(width: geo.size.width * rewe / base)
                    Rectangle().fill(Theme.metzger).frame(width: geo.size.width * metzger / base)
                    Spacer(minLength: 0)
                }
                .background(Color(hex: "3A3C37"))
                .clipShape(Capsule())
            }
            .frame(height: 8)
            .accessibilityElement()
            .accessibilityLabel("REWE \(Fmt.euro(rewe)), Metzger \(Fmt.euro(metzger))")

            HStack(spacing: 14) {
                legend(Theme.accent, "REWE \(Fmt.euro(rewe))")
                legend(Theme.metzger, "Metzger \(Fmt.euro(metzger))")
            }
            HStack {
                if s.isCurrentMonth {
                    Text("Prognose Monatsende: \(Fmt.euro(s.forecast))")
                        .foregroundStyle(s.forecast > s.budget ? Color(hex: "F2B48A") : Theme.mutedOnDark)
                }
                Spacer()
                Text(s.remaining >= 0 ? "noch \(Fmt.euro(s.remaining))" : "\(Fmt.euro(-s.remaining)) drüber")
                    .foregroundStyle(Theme.mutedOnDark)
            }
            .font(.system(size: 12, weight: .medium))
            if s.household > 0 {
                Divider().overlay(Color(hex: "3A3C37"))
                HStack {
                    legend(Theme.sonstiges, "Haushalt & Wünsche")
                    Spacer()
                    Text("\(Fmt.euro(s.household)) · extra").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mutedOnDark)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var historyChart: some View {
        let months: [(label: String, total: Double, current: Bool)] = (0..<6).reversed().map { back -> (label: String, total: Double, current: Bool) in
            let m = cal.date(byAdding: .month, value: monthOffset - back, to: Date())!
            let s = BudgetStats.make(purchases: purchases, budget: settings.budget, month: m)
            return (Fmt.monthShort(s.monthStart), s.spent, back == 0)
        }
        let avg = months.filter { !$0.current }.map(\.total).reduce(0, +) / 5
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Letzte 6 Monate").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("Ø \(Fmt.euro(avg))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            Chart {
                ForEach(Array(months.enumerated()), id: \.offset) { _, m in
                    BarMark(x: .value("Monat", m.label), y: .value("Euro", m.total))
                        .foregroundStyle(m.current ? Theme.accent : Color(hex: "DCD9D0"))
                        .cornerRadius(6)
                }
                RuleMark(y: .value("Budget", settings.budget))
                    .foregroundStyle(Theme.warn.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .chartYAxis(.hidden)
            .frame(height: 140)
        }
        .card()
    }

    private func purchaseRow(_ p: Purchase) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.source == .rewe ? "box.truck" : (p.source == .metzger ? "storefront" : "bag"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.color(for: p.source))
                .frame(width: 36, height: 36)
                .background(Theme.color(for: p.source).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Fmt.shortDate(p.date)) · \(p.source.label)").font(.system(size: 14, weight: .bold))
                Text(p.note.isEmpty ? (p.itemCount > 0 ? "\(p.itemCount) Artikel" : "Einkauf") : p.note)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(Fmt.euro(p.total)).font(.system(size: 15, weight: .heavy))
        }
        .frame(minHeight: 56)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: 17, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .card(12, radius: 18)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func circleButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.line))
        }
        .foregroundStyle(Theme.ink)
        .accessibilityLabel(label)
    }
}
