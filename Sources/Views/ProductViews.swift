import SwiftUI
import SwiftData

// MARK: - Detail: Bestand schnell anpassen

struct ProductDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var product: Product

    @Query private var plan: [PlanEntry]
    @Query private var settingsList: [AppSettings]
    @Query private var logs: [MealLog]
    @Query private var products: [Product]

    @State private var showEdit = false
    @State private var confirmDelete = false

    var body: some View {
        let f = Forecast(products: products, plan: plan, settings: settingsList.first ?? AppSettings(), logs: logs)
        let st = f.status(product)

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        EmojiTile(emoji: product.emoji, tint: product.tint, size: 88)
                        Text(product.name).font(.system(size: 24, weight: .heavy))
                        Text(statusText(st)).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(st.level == .ok ? Theme.muted : Theme.warnText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 14) {
                        HStack(spacing: 18) {
                            roundButton("minus", label: "Weniger") { change(-product.unit.step) }
                            VStack(spacing: 0) {
                                Text(Fmt.number(product.stock)).font(.system(size: 40, weight: .heavy))
                                Text(product.unit.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                            }
                            .frame(minWidth: 90)
                            roundButton("plus", label: "Mehr") { change(product.unit.step) }
                        }
                        HStack(spacing: 8) {
                            Button("Ist leer") { set(0) }
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.warnText)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.warnBorder, lineWidth: 2))
                            Button("Aufgefüllt") { set(product.refillTo) }
                                .buttonStyle(PrimaryButtonStyle(color: Theme.ink))
                        }
                    }
                    .card(20)

                    VStack(spacing: 0) {
                        row("Bezugsquelle", product.source.label)
                        row("Warnen ab", Fmt.amount(product.warnAt, product.unit))
                        row("Auffüllen auf", Fmt.amount(product.refillTo, product.unit))
                        row("Packung", Fmt.amount(product.packageSize, product.unit))
                        if product.price > 0 { row("Preis / Packung", Fmt.euro(product.price)) }
                        row("kcal / 100 g", Fmt.number(product.kcal100, maxFraction: 0))
                        DatePickerRow(date: $product.bestBefore)
                    }
                    .padding(.horizontal, 14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if product.priceHistory.count > 1 {
                        PriceHistoryView(records: product.priceHistory)
                    }

                    Button("Produkt löschen", role: .destructive) { confirmDelete = true }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(minHeight: 44)
                }
                .padding(20)
            }
            .background(Theme.ground)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Bearbeiten") { showEdit = true } }
            }
            .sheet(isPresented: $showEdit) { ProductEditView(product: product) }
            .confirmationDialog("\(product.name) wirklich löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    context.delete(product)
                    try? context.save()
                    dismiss()
                }
            }
        }
    }

    private func statusText(_ st: Forecast.Status) -> String {
        let day = Fmt.weekdayName(Calendar.current.isoWeekday(st.restockDate))
        switch st.level {
        case .leer:
            return "Leer – \(st.packages) × \(Fmt.amount(product.packageSize, product.unit)) auf der \(product.source.listName)"
        case .knapp:
            return "Reicht nicht bis \(day) – \(st.packages) × \(Fmt.amount(product.packageSize, product.unit)) auf der \(product.source.listName)"
        case .ok:
            return "Reicht bis \(day) (dann noch ca. \(Fmt.amount(max(st.projected, 0), product.unit)))"
        }
    }

    private func change(_ delta: Double) { set(max(0, product.stock + delta)) }

    private func set(_ value: Double) {
        product.stock = value
        product.lastCorrectedAt = Date()
        product.lastCheckedAt = Date()
        Notifier.evaluate(context)
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 52, height: 52)
                .background(Theme.ground, in: Circle())
                .overlay(Circle().stroke(Theme.line))
        }
        .foregroundStyle(Theme.ink)
        .accessibilityLabel(label)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold))
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.track).frame(height: 1) }
    }
}

struct DatePickerRow: View {
    @Binding var date: Date?
    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { date != nil }, set: { date = $0 ? Calendar.current.date(byAdding: .day, value: 5, to: Date()) : nil })) {
                Text("Mindesthaltbarkeit").font(.system(size: 14, weight: .semibold))
            }
            .tint(Theme.accent)
        }
        .frame(minHeight: 48)
        if let d = date {
            DatePicker("Haltbar bis", selection: Binding(get: { d }, set: { date = $0 }), displayedComponents: .date)
                .font(.system(size: 14, weight: .semibold))
                .environment(\.locale, Fmt.de)
                .frame(minHeight: 48)
        }
    }
}

struct PriceHistoryView: View {
    let records: [PriceRecord]
    var body: some View {
        let sorted = records.sorted { $0.date < $1.date }
        VStack(alignment: .leading, spacing: 8) {
            Text("Preisverlauf").font(.system(size: 15, weight: .bold))
            ForEach(sorted.suffix(6), id: \.persistentModelID) { r in
                HStack {
                    Text(Fmt.shortDate(r.date)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Fmt.euro(r.price)).fontWeight(.bold)
                }
                .font(.system(size: 13))
            }
            if let first = sorted.first, let last = sorted.last, first.price > 0 {
                let change = (last.price - first.price) / first.price * 100
                Text(change >= 0 ? "+\(Fmt.number(change)) % seit \(Fmt.shortDate(first.date))" : "\(Fmt.number(change)) % seit \(Fmt.shortDate(first.date))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(change > 10 ? Theme.warnText : Theme.muted)
            }
        }
        .card()
    }
}

// MARK: - Anlegen / Bearbeiten

struct ProductEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Product.sortIndex) private var allProducts: [Product]

    let product: Product?

    @State private var query = ""
    @State private var lookupMessage: String?
    @State private var isLooking = false
    @State private var showScanner = false

    @State private var name = ""
    @State private var emoji = "🛒"
    @State private var emojiTouched = false
    @State private var source: Source = .rewe
    @State private var unit: StockUnit = .stueck
    @State private var stock: Double = 0
    @State private var warnAt: Double = 1
    @State private var refillTo: Double = 3
    @State private var packageSize: Double = 1
    @State private var gramsPerUnit: Double = 100
    @State private var price: Double = 0
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var reweNumber = ""
    @State private var reweURL = ""
    @State private var barcode = ""
    @State private var fallbackName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Name, Artikelnummer oder REWE-Link", text: $query)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.search)
                            .onSubmit { Task { await resolve(query) } }
                        if isLooking { ProgressView() }
                        Button { showScanner = true } label: {
                            Image(systemName: "barcode.viewfinder").font(.system(size: 20, weight: .semibold))
                        }
                        .accessibilityLabel("Barcode scannen")
                        .disabled(!BarcodeScannerView.isAvailable)
                    }
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        Task { @MainActor in
                            query = s
                            await resolve(s)
                        }
                    }
                    if let lookupMessage {
                        Text(lookupMessage).font(.footnote).foregroundStyle(Theme.muted)
                    }
                } footer: {
                    Text("Link bekommst du in der REWE-App über „Teilen“ → „Link kopieren“. Barcode füllt die Nährwerte automatisch.")
                }

                Section("Produkt") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, new in if !emojiTouched { emoji = EmojiGuess.emoji(for: new) } }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(EmojiGuess.picker, id: \.self) { e in
                                Button { emoji = e; emojiTouched = true } label: {
                                    Text(e).font(.system(size: 24))
                                        .frame(width: 44, height: 44)
                                        .background(e == emoji ? Theme.track : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Picker("Bezugsquelle", selection: $source) {
                        ForEach(Source.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Einheit", selection: $unit) {
                        ForEach(StockUnit.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    numberRow("Aktueller Bestand", $stock, unit.short)
                    numberRow("Warnen ab", $warnAt, unit.short)
                    numberRow("Auffüllen auf", $refillTo, unit.short)
                    numberRow("Menge pro Packung", $packageSize, unit.short)
                    if !unit.isMass { numberRow("Gramm pro \(unit.label)", $gramsPerUnit, "g") }
                    numberRow("Preis pro Packung", $price, "€")
                } header: {
                    Text("Bestand")
                } footer: {
                    Text("Gewarnt wird, sobald der Bestand – jetzt oder laut Wochenplan zum nächsten Einkauf – auf „Warnen ab“ fällt.")
                }

                Section("Nährwerte pro 100 g") {
                    numberRow("Kalorien", $kcal, "kcal")
                    numberRow("Protein", $protein, "g")
                    numberRow("Kohlenhydrate", $carbs, "g")
                    numberRow("Fett", $fat, "g")
                }

                Section {
                    TextField("REWE-Artikelnummer", text: $reweNumber).keyboardType(.numberPad)
                    TextField("Ausweichartikel, falls ausverkauft", text: $fallbackName)
                    if !barcode.isEmpty { LabeledContent("Barcode", value: barcode) }
                } header: {
                    Text("Bestellung")
                } footer: {
                    Text("Ohne Artikelnummer sucht Claude beim ersten Warenkorb-Lauf auf rewe.de nach dem Namen und speichert die Nummer.")
                }
            }
            .navigationTitle(product == nil ? "Produkt hinzufügen" : "Bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showScanner) {
                BarcodeScannerView { code in
                    showScanner = false
                    Task { @MainActor in await resolve(code) }
                }
                .ignoresSafeArea()
            }
            .onAppear(perform: loadFromProduct)
        }
    }

    private func numberRow(_ title: String, _ value: Binding<Double>, _ suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number.locale(Fmt.de))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(suffix).foregroundStyle(Theme.muted).frame(minWidth: 34, alignment: .leading)
        }
    }

    @MainActor
    private func resolve(_ text: String) async {
        guard let input = ProductInput.parse(text) else { return }
        switch input {
        case .name(let n):
            name = n
            lookupMessage = nil
        case .rewe(let number, let hint, let url):
            reweNumber = number
            reweURL = url ?? ""
            source = .rewe
            if let hint, name.isEmpty { name = hint }
            lookupMessage = "REWE-Artikel \(number) verknüpft."
        case .barcode(let code):
            barcode = code
            isLooking = true
            defer { isLooking = false }
            if let off = await OpenFoodFacts.lookup(barcode: code) {
                if !off.name.isEmpty { name = off.name }
                kcal = off.kcal ?? kcal
                protein = off.protein ?? protein
                carbs = off.carbs ?? carbs
                fat = off.fat ?? fat
                let extra = [off.brand, off.quantity].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                lookupMessage = "Gefunden\(extra.isEmpty ? "" : ": \(extra)"). Nährwerte übernommen."
            } else {
                lookupMessage = "Barcode \(code) nicht in der Datenbank – bitte Namen und Nährwerte eintragen."
            }
        }
    }

    private func loadFromProduct() {
        guard let p = product else { return }
        name = p.name; emoji = p.emoji; emojiTouched = true
        source = p.source; unit = p.unit
        stock = p.stock; warnAt = p.warnAt; refillTo = p.refillTo
        packageSize = p.packageSize; gramsPerUnit = p.gramsPerUnit; price = p.price
        kcal = p.kcal100; protein = p.protein100; carbs = p.carbs100; fat = p.fat100
        reweNumber = p.reweArticleNumber; reweURL = p.reweURL; barcode = p.barcode; fallbackName = p.fallbackName
    }

    private func save() {
        let p: Product
        if let existing = product {
            p = existing
        } else {
            p = Product(name: name, emoji: emoji, source: source, unit: unit)
            p.sortIndex = (allProducts.map(\.sortIndex).max() ?? -1) + 1
            context.insert(p)
        }
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.emoji = emoji
        p.source = source
        p.unit = unit
        if p.stock != stock { p.lastCorrectedAt = Date() }
        p.stock = max(0, stock)
        p.warnAt = max(0, warnAt)
        p.refillTo = max(refillTo, warnAt)
        p.packageSize = max(packageSize, 0.01)
        p.gramsPerUnit = unit.isMass ? 1 : max(gramsPerUnit, 0)
        p.kcal100 = kcal; p.protein100 = protein; p.carbs100 = carbs; p.fat100 = fat
        p.reweArticleNumber = reweNumber
        p.reweURL = reweURL
        p.barcode = barcode
        p.fallbackName = fallbackName
        p.updatePrice(price, context: context)
        p.lowNotifiedAt = nil
        Notifier.evaluate(context)
        dismiss()
    }
}
