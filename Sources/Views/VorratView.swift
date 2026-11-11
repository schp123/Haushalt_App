import SwiftUI
import SwiftData

struct VorratView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Product.sortIndex) private var products: [Product]
    @Query private var plan: [PlanEntry]
    @Query private var settingsList: [AppSettings]
    @Query(sort: \MealLog.date, order: .reverse) private var logs: [MealLog]

    @State private var showAdd = false
    @State private var showSettings = false
    @State private var selected: Product?

    private var settings: AppSettings { settingsList.first ?? AppSettings() }
    private var forecast: Forecast { Forecast(products: products, plan: plan, settings: settings, logs: logs) }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        let f = forecast
        let statuses = Dictionary(uniqueKeysWithValues: products.map { ($0.persistentModelID, f.status($0)) })
        let empty = statuses.values.filter { $0.level == .leer }.count
        let low = statuses.values.filter { $0.level == .knapp }.count
        let reweCount = f.shoppingList(for: .rewe).count

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if reweCount > 0 {
                        cartCard(count: reweCount)
                    }

                    MacroCard(totals: f.todayTotals().nutrition, settings: settings)

                    SectionTitle(title: "Deine Basics",
                                 trailing: summary(empty: empty, low: low),
                                 trailingColor: (empty + low) > 0 ? Theme.warnText : Theme.muted)

                    if products.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(products) { p in
                                if let st = statuses[p.persistentModelID] {
                                    Button { selected = p } label: { ProductTile(product: p, status: st) }
                                        .buttonStyle(.plain)
                                }
                            }
                            Button { showAdd = true } label: { addTile }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAdd) { ProductEditView(product: nil) }
            .sheet(isPresented: $showSettings) { EinstellungenView() }
            .sheet(item: $selected) { p in ProductDetailView(product: p) }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.longDate(Date()))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                Text("Vorrat").font(.system(size: 30, weight: .heavy))
            }
            Spacer()
            Button { Router.shared.showCheck = true } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
            }
            .accessibilityLabel("Vorrats-Check starten")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
            }
            .accessibilityLabel("Einstellungen")
        }
        .foregroundStyle(Theme.ink)
        .padding(.top, 12)
    }

    private func cartCard(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cart")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) Artikel auf der REWE-Liste").font(.system(size: 15, weight: .bold))
                    Text("Bestellung \(Fmt.weekdayName(settings.orderWeekday)), Lieferung \(Fmt.weekdayShort(settings.deliveryWeekday)) \(settings.deliveryWindow).")
                        .font(.system(size: 13)).foregroundStyle(Theme.mutedOnDark)
                }
            }
            Button { Router.shared.tab = .einkauf } label: {
                Text("Liste ansehen")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Noch keine Produkte").font(.system(size: 17, weight: .bold))
            Text("Trag eure Basics ein – per Name, REWE-Artikelnummer, Link oder Barcode.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Erstes Produkt hinzufügen") { showAdd = true }
                .buttonStyle(PrimaryButtonStyle())
            Button("Beispiel-Basics laden") { SampleData.load(into: context) }
                .font(.system(size: 14, weight: .semibold))
                .frame(minHeight: 44)
        }
        .card(20)
    }

    private var addTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
            Text("Produkt").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, minHeight: 124)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 2, dash: [6])))
        .accessibilityLabel("Produkt hinzufügen")
    }

    private func summary(empty: Int, low: Int) -> String? {
        var parts: [String] = []
        if empty > 0 { parts.append("\(empty) leer") }
        if low > 0 { parts.append("\(low) knapp") }
        return parts.isEmpty ? (products.isEmpty ? nil : "alles da") : parts.joined(separator: " · ")
    }
}

// MARK: - Kachel

struct ProductTile: View {
    let product: Product
    let status: Forecast.Status

    var body: some View {
        let fraction = product.stock / max(product.refillTo, product.stock, 1)
        VStack(alignment: .leading, spacing: 8) {
            EmojiTile(emoji: product.emoji, tint: product.tint)
            Text(product.name)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Bar(fraction: fraction, color: barColor, height: 5)
            Text(label)
                .font(.system(size: 11, weight: status.level == .ok ? .medium : .bold))
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(status.level == .leer ? 10 : 12)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if status.level == .leer {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.warnBorder, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var barColor: Color {
        switch status.level {
        case .ok: Theme.accent
        case .knapp: Theme.amber
        case .leer: Theme.warn
        }
    }
    private var labelColor: Color {
        switch status.level {
        case .ok: Theme.muted
        case .knapp: Theme.amberText
        case .leer: Theme.warnText
        }
    }
    private var label: String {
        switch status.level {
        case .leer: "leer · \(product.source.label)"
        case .knapp: "\(Fmt.amount(product.stock, product.unit)) · knapp"
        case .ok: "\(Fmt.number(product.stock)) / \(Fmt.amount(product.refillTo, product.unit))"
        }
    }
}

// MARK: - Tageswerte

struct MacroCard: View {
    let totals: Nutrition
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: min(totals.kcal / max(settings.kcalGoal, 1), 1))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(Fmt.kcal(totals.kcal)).font(.system(size: 18, weight: .heavy))
                    Text("/ \(Fmt.kcal(settings.kcalGoal)) kcal").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityElement(children: .combine)

            VStack(spacing: 9) {
                macro("Protein", totals.protein, settings.proteinGoal, Theme.protein)
                macro("Kohlenhydrate", totals.carbs, settings.carbsGoal, Theme.carbs)
                macro("Fett", totals.fat, settings.fatGoal, Theme.fat)
            }
        }
        .card()
    }

    private func macro(_ name: String, _ v: Double, _ goal: Double, _ color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Fmt.number(v, maxFraction: 0)) / \(Fmt.number(goal, maxFraction: 0)) g").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12, weight: .semibold))
            Bar(fraction: v / max(goal, 1), color: color)
        }
    }
}
