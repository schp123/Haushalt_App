import SwiftUI
import SwiftData
import PhotosUI

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
                        ProductImage(photo: product.photo, emoji: product.emoji, tint: product.tint, size: 88)
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
                                Text(Fmt.number(product.currentStock())).font(.system(size: 40, weight: .heavy))
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
                        row("Bezugsquelle", product.whereToBuy)
                        if product.usagePerWeek > 0 { row("Verbrauch / Woche", Fmt.amount(product.usagePerWeek, product.unit)) }
                        row("Warnen ab", Fmt.amount(product.warnAt, product.unit))
                        row("Auffüllen auf", Fmt.amount(product.refillTo, product.unit))
                        row("Packung", Fmt.amount(product.packageSize, product.unit))
                        if product.price > 0 { row("Preis / Packung", Fmt.euro(product.price)) }
                        if product.isFood { row("kcal / 100 g", Fmt.number(product.kcal100, maxFraction: 0)) }
                        DatePickerRow(date: $product.bestBefore)
                    }
                    .padding(.horizontal, 14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                    if let url = URL(string: product.linkURL), !product.linkURL.isEmpty {
                        Link(destination: url) {
                            Label("Bei \(product.whereToBuy) öffnen", systemImage: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }

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

    private func change(_ delta: Double) { set(max(0, product.currentStock() + delta)) }

    private func set(_ value: Double) {
        product.setStock(value)
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
    /// Neues Produkt aus einem anderen Laden (Waschmittel, Rosmarinöl …) vorbelegen.
    var household: Bool = false

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
    @State private var isFood = true
    @State private var storeName = ""
    @State private var linkURL = ""
    @State private var photo: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var usagePerWeek: Double = 0
    @State private var leadDays = 7

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Name, Artikelnummer oder Link", text: $query)
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
                    Text("REWE-Link: in der REWE-App „Teilen“ → „Link kopieren“. Links von Amazon, Biomarkt & Co. übernehmen Name und Bild. Barcode füllt die Nährwerte.")
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
                    PhotoRow(photo: $photo, item: $photoItem)
                    Picker("Bezugsquelle", selection: $source) {
                        ForEach(Source.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if source == .sonstiges {
                        TextField("Laden, z. B. Biomarkt, Amazon, dm", text: $storeName)
                        TextField("Link zum Produkt", text: $linkURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("Lebensmittel", isOn: $isFood).tint(Theme.accent)
                    Picker("Einheit", selection: $unit) {
                        ForEach(StockUnit.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    numberRow("Aktueller Bestand", $stock, unit.short)
                    numberRow("Warnen ab", $warnAt, unit.short)
                    numberRow("Auffüllen auf", $refillTo, unit.short)
                    numberRow("Menge pro Packung", $packageSize, unit.short)
                    if isFood && !unit.isMass { numberRow("Gramm pro \(unit.label)", $gramsPerUnit, "g") }
                    numberRow("Verbrauch pro Woche", $usagePerWeek, unit.short)
                    if source == .sonstiges {
                        Stepper("\(leadDays) Tage vorher warnen", value: $leadDays, in: 1...60)
                    }
                    numberRow("Preis pro Packung", $price, "€")
                } header: {
                    Text("Bestand")
                } footer: {
                    Text(source == .sonstiges
                         ? "Beispiel Waschmittel: Packung = 60 Anwendungen, Verbrauch 6 pro Woche. Die App zieht den Verbrauch automatisch ab und warnt rechtzeitig vor „Warnen ab“."
                         : "Gewarnt wird, sobald der Bestand – jetzt oder laut Wochenplan zum nächsten Einkauf – auf „Warnen ab“ fällt.")
                }

                if isFood {
                    Section("Nährwerte pro 100 g") {
                        numberRow("Kalorien", $kcal, "kcal")
                        numberRow("Protein", $protein, "g")
                        numberRow("Kohlenhydrate", $carbs, "g")
                        numberRow("Fett", $fat, "g")
                    }
                }

                if source == .rewe {
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
        case .link(let url):
            linkURL = url.absoluteString
            source = .sonstiges
            isLooking = true
            defer { isLooking = false }
            let preview = await LinkPreview.load(url)
            if let store = preview.store, storeName.isEmpty { storeName = store }
            if let title = preview.title, !title.isEmpty { name = String(title.prefix(60)) }
            if let img = preview.image { photo = ImageTools.jpeg(img) }
            lookupMessage = preview.title == nil ? "Link gespeichert – Name bitte selbst eintragen." : "Name\(preview.image == nil ? "" : " und Bild") vom Link übernommen."
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
        guard let p = product else {
            if household {
                source = .sonstiges
                isFood = false
                unit = .anwendung
                emoji = "🧴"
                emojiTouched = true
            }
            return
        }
        name = p.name; emoji = p.emoji; emojiTouched = true
        source = p.source; unit = p.unit
        stock = p.currentStock(); warnAt = p.warnAt; refillTo = p.refillTo
        packageSize = p.packageSize; gramsPerUnit = p.gramsPerUnit; price = p.price
        kcal = p.kcal100; protein = p.protein100; carbs = p.carbs100; fat = p.fat100
        reweNumber = p.reweArticleNumber; reweURL = p.reweURL; barcode = p.barcode; fallbackName = p.fallbackName
        isFood = p.isFood; storeName = p.storeName; linkURL = p.linkURL; photo = p.photo
        usagePerWeek = p.usagePerWeek; leadDays = p.leadDays
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
        if abs(p.currentStock() - stock) > 0.0001 || product == nil {
            if product != nil { p.lastCorrectedAt = Date() }
            p.setStock(stock)
        }
        p.warnAt = max(0, warnAt)
        p.refillTo = max(refillTo, warnAt)
        p.packageSize = max(packageSize, 0.01)
        p.gramsPerUnit = unit.isMass ? 1 : max(gramsPerUnit, 0)
        p.kcal100 = kcal; p.protein100 = protein; p.carbs100 = carbs; p.fat100 = fat
        if !isFood { p.kcal100 = 0; p.protein100 = 0; p.carbs100 = 0; p.fat100 = 0 }
        p.reweArticleNumber = reweNumber
        p.reweURL = reweURL
        p.barcode = barcode
        p.fallbackName = fallbackName
        p.isFood = isFood
        p.storeName = storeName.trimmingCharacters(in: .whitespaces)
        p.linkURL = linkURL.trimmingCharacters(in: .whitespaces)
        p.photo = photo
        p.usagePerWeek = max(0, usagePerWeek)
        p.leadDays = leadDays
        p.updatePrice(price, context: context)
        p.lowNotifiedAt = nil
        Notifier.evaluate(context)
        dismiss()
    }
}


// MARK: - Foto wählen (für Produkte und Wunschliste)

struct PhotoRow: View {
    @Binding var photo: Data?
    @Binding var item: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 12) {
            if let data = photo, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            PhotosPicker(selection: $item, matching: .images) {
                Label(photo == nil ? "Foto hinzufügen" : "Foto ändern", systemImage: "photo")
            }
            if photo != nil {
                Spacer()
                Button("Entfernen", role: .destructive) { photo = nil }
                    .buttonStyle(.borderless)
            }
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task { @MainActor in
                if let data = try? await new.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    photo = ImageTools.jpeg(img)
                }
            }
        }
    }
}

/// Foto oder Emoji – für Kacheln und Listen.
struct ProductImage: View {
    var photo: Data?
    var emoji: String
    var tint: Color
    var size: CGFloat = 40

    var body: some View {
        if let data = photo, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                .accessibilityHidden(true)
        } else {
            EmojiTile(emoji: emoji, tint: tint, size: size)
        }
    }
}
