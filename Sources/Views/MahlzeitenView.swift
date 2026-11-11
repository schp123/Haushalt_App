import SwiftUI
import SwiftData

struct MahlzeitenView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MealLog.date, order: .reverse) private var logs: [MealLog]
    @Query(sort: \MealTemplate.name) private var templates: [MealTemplate]
    @Query private var plan: [PlanEntry]
    @Query private var settingsList: [AppSettings]

    @State private var showManual = false
    @State private var editTemplate: MealTemplate?
    @State private var showNewTemplate = false

    private var settings: AppSettings { settingsList.first ?? AppSettings() }
    private var cal: Calendar { .current }
    private var todayLogs: [MealLog] {
        logs.filter { cal.isDateInToday($0.date) }.sorted { $0.date < $1.date }
    }
    private var openPlanned: [PlanEntry] {
        let today = cal.isoWeekday(Date())
        let done = Set(todayLogs.filter(\.fromPlan).map(\.slotRaw))
        return plan
            .filter { $0.weekday == today && $0.template != nil && !done.contains($0.slotRaw) }
            .sorted { $0.slot.order < $1.slot.order }
    }

    var body: some View {
        let totals = todayLogs.reduce(Nutrition()) { $0 + Nutrition(kcal: $1.kcal, protein: $1.protein, carbs: $1.carbs, fat: $1.fat) }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.longDate(Date())).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                            Text("Mahlzeiten").font(.system(size: 30, weight: .heavy))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Fmt.kcal(totals.kcal)) kcal").font(.system(size: 18, weight: .heavy))
                            Text("noch \(Fmt.kcal(max(settings.kcalGoal - totals.kcal, 0))) übrig")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.top, 12)

                    MacroCard(totals: totals, settings: settings)

                    HStack(spacing: 8) {
                        actionButton("Neue Vorlage", "square.grid.2x2", dark: true) { showNewTemplate = true }
                        actionButton("Frei eintragen", "square.and.pencil", dark: false) { showManual = true }
                    }

                    if !templates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(title: "Schnell eintragen")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(templates) { t in
                                        Button { MealLogger.log(template: t, slot: .forNow(), fromPlan: false, context: context) } label: {
                                            Text("\(t.emoji) \(t.name)")
                                                .font(.system(size: 13, weight: .semibold))
                                                .padding(.horizontal, 14)
                                                .frame(minHeight: 40)
                                                .background(Theme.card, in: Capsule())
                                                .overlay(Capsule().stroke(Theme.line))
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Vorlage bearbeiten") { editTemplate = t }
                                            Button("Löschen", role: .destructive) { context.delete(t); Notifier.evaluate(context) }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(spacing: 10) {
                        ForEach(todayLogs) { log in
                            MealCard(log: log)
                                .contextMenu {
                                    Button("Löschen", role: .destructive) { context.delete(log); Notifier.evaluate(context) }
                                }
                        }
                        ForEach(openPlanned) { entry in
                            plannedCard(entry)
                        }
                        if todayLogs.isEmpty && openPlanned.isEmpty {
                            Text("Heute noch nichts eingetragen. Leg im Wochenplan fest, was es gibt – dann reicht ein Tipp auf „Gegessen“.")
                                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                                .card()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showManual) { ManualMealView() }
            .sheet(isPresented: $showNewTemplate) { TemplateEditView(template: nil) }
            .sheet(item: $editTemplate) { t in TemplateEditView(template: t) }
        }
    }

    private func actionButton(_ title: String, _ icon: String, dark: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(dark ? .white : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(dark ? Theme.ink : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func plannedCard(_ entry: PlanEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.slot.label) · laut Plan").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Text("\(entry.template?.emoji ?? "") \(entry.template?.name ?? "")").font(.system(size: 15, weight: .bold))
            }
            Spacer()
            Button("Gegessen") {
                if let t = entry.template { MealLogger.log(template: t, slot: entry.slot, fromPlan: true, context: context) }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: "CFCBC0"), style: StrokeStyle(lineWidth: 2, dash: [6])))
    }
}

struct MealCard: View {
    let log: MealLog
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(log.slot.label) · \(log.date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text("\(log.emoji) \(log.name)").font(.system(size: 15, weight: .bold))
                }
                Spacer()
                Text(Fmt.kcal(log.kcal)).font(.system(size: 15, weight: .heavy))
            }
            HStack(spacing: 6) {
                chip("P \(Fmt.number(log.protein, maxFraction: 0)) g", bg: "E6EEF8", fg: "234A85")
                chip("K \(Fmt.number(log.carbs, maxFraction: 0)) g", bg: "FBF1DC", fg: "7A5410")
                chip("F \(Fmt.number(log.fat, maxFraction: 0)) g", bg: "EEE8F6", fg: "5A3D80")
                if log.cost > 0 { chip(Fmt.euro(log.cost), bg: "EFEEE9", fg: "4E4C46") }
            }
        }
        .card(14, radius: 20)
    }

    private func chip(_ text: String, bg: String, fg: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(hex: fg))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(hex: bg), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Frei eintragen

struct ManualMealView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var slot = MealSlot.forNow()
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var cost: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was gab es?", text: $name)
                    Picker("Mahlzeit", selection: $slot) {
                        ForEach(MealSlot.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Nährwerte") {
                    field("Kalorien", $kcal, "kcal")
                    field("Protein", $protein, "g")
                    field("Kohlenhydrate", $carbs, "g")
                    field("Fett", $fat, "g")
                    field("Kosten (z. B. auswärts)", $cost, "€")
                }
            }
            .navigationTitle("Frei eintragen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        context.insert(MealLog(date: Date(), slot: slot, name: name, emoji: "🍽️",
                                               nutrition: Nutrition(kcal: kcal, protein: protein, carbs: carbs, fat: fat),
                                               cost: cost, fromPlan: false))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private func field(_ title: String, _ v: Binding<Double>, _ suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: v, format: .number.locale(Fmt.de))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
            Text(suffix).foregroundStyle(Theme.muted).frame(minWidth: 34, alignment: .leading)
        }
    }
}

// MARK: - Vorlage (Gericht aus euren Produkten)

struct TemplateEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Product.sortIndex) private var products: [Product]

    let template: MealTemplate?

    struct Row: Identifiable {
        let id = UUID()
        var product: Product?
        var amount: Double
    }

    @State private var name = ""
    @State private var emoji = "🍽️"
    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        let total = rows.reduce(Nutrition()) { acc, r in r.product.map { acc + $0.nutrition(for: r.amount) } ?? acc }
        let cost = rows.reduce(0.0) { $0 + ($1.product?.cost(for: $1.amount) ?? 0) }

        NavigationStack {
            Form {
                Section {
                    TextField("Name, z. B. Hähnchen-Reis-Bowl", text: $name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(["🍽️", "🥣", "🍗", "🥗", "🍝", "🍚", "🥚", "🐟", "🥩", "🌯", "🥪", "🍎"], id: \.self) { e in
                                Button { emoji = e } label: {
                                    Text(e).font(.system(size: 24)).frame(width: 44, height: 44)
                                        .background(e == emoji ? Theme.track : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Zutaten") {
                    ForEach($rows) { $row in
                        HStack {
                            Picker("Produkt", selection: $row.product) {
                                Text("Wählen").tag(Product?.none)
                                ForEach(products) { p in Text("\(p.emoji) \(p.name)").tag(Optional(p)) }
                            }
                            .labelsHidden()
                            Spacer()
                            TextField("0", value: $row.amount, format: .number.locale(Fmt.de))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 70)
                            Text(row.product?.unit.short ?? "").foregroundStyle(Theme.muted).frame(minWidth: 44, alignment: .leading)
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    Button("Zutat hinzufügen") { rows.append(Row(product: nil, amount: 1)) }
                }

                Section("Pro Portion") {
                    LabeledContent("Kalorien", value: "\(Fmt.kcal(total.kcal)) kcal")
                    LabeledContent("Protein / Kohlenhydrate / Fett",
                                   value: "\(Fmt.number(total.protein, maxFraction: 0)) / \(Fmt.number(total.carbs, maxFraction: 0)) / \(Fmt.number(total.fat, maxFraction: 0)) g")
                    if cost > 0 { LabeledContent("Kosten", value: Fmt.euro(cost)) }
                }
            }
            .navigationTitle(template == nil ? "Neue Vorlage" : "Vorlage bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern", action: save).disabled(name.isEmpty) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let t = template else {
            rows = [Row(product: nil, amount: 1)]
            return
        }
        name = t.name
        emoji = t.emoji
        rows = t.ingredients.map { Row(product: $0.product, amount: $0.amount) }
    }

    private func save() {
        let t: MealTemplate
        if let existing = template {
            t = existing
            for ing in t.ingredients { context.delete(ing) }
        } else {
            t = MealTemplate(name: name, emoji: emoji)
            context.insert(t)
        }
        t.name = name
        t.emoji = emoji
        for r in rows {
            guard let p = r.product, r.amount > 0 else { continue }
            let ing = Ingredient(amount: r.amount)
            context.insert(ing)
            ing.product = p
            ing.template = t
        }
        Notifier.evaluate(context)
        dismiss()
    }
}
