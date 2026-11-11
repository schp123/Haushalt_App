import SwiftUI
import SwiftData

struct EinkaufView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Product.sortIndex) private var products: [Product]
    @Query private var plan: [PlanEntry]
    @Query private var settingsList: [AppSettings]
    @Query(sort: \MealLog.date, order: .reverse) private var logs: [MealLog]

    @Query(sort: \WishItem.createdAt, order: .reverse) private var wishes: [WishItem]

    @State private var excluded: Set<PersistentIdentifier> = []
    @State private var purchaseSource: Source?
    @State private var newWish = false
    @State private var newHousehold = false
    @State private var editWish: WishItem?
    @State private var doneWish: WishItem?
    @State private var showDoneWishes = false

    private var settings: AppSettings { settingsList.first ?? AppSettings() }

    var body: some View {
        let f = Forecast(products: products, plan: plan, settings: settings, logs: logs)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom) {
                        Text("Einkauf").font(.system(size: 30, weight: .heavy))
                        Spacer()
                        Menu {
                            Button { newWish = true } label: { Label("Wunsch (einmalig)", systemImage: "gift") }
                            Button { newHousehold = true } label: { Label("Vorratsprodukt aus anderem Laden", systemImage: "shippingbox") }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .bold))
                                .frame(width: 44, height: 44)
                                .background(Theme.card, in: Circle())
                                .overlay(Circle().stroke(Theme.line))
                                .foregroundStyle(Theme.ink)
                        }
                        .accessibilityLabel("Hinzufügen")
                    }
                    .padding(.top, 12)

                    listSection(.rewe, f.shoppingList(for: .rewe),
                                subtitle: "Bestellen \(Fmt.weekdayName(settings.orderWeekday)) · Lieferung \(Fmt.shortDate(f.nextDelivery)), \(settings.deliveryWindow)",
                                info: "Der Warenkorb wird \(Fmt.weekdayName(settings.cartFillWeekday)) um \(Fmt.time(settings.cartFillHour, settings.cartFillMinute)) automatisch auf rewe.de befüllt – du tippst nur noch auf „Bestellen“.")
                    listSection(.metzger, f.shoppingList(for: .metzger),
                                subtitle: "Einkauf vor Ort · \(Fmt.shortDate(f.nextMetzger))",
                                info: "Du bekommst am Einkaufstag eine Erinnerung mit der Liste.")
                    let other = f.shoppingList(for: .sonstiges)
                    if !other.isEmpty || products.contains(where: { $0.source == .sonstiges }) {
                        listSection(.sonstiges, other, subtitle: "Biomarkt, Amazon & Co. – rechtzeitig vor dem Leerwerden", info: nil)
                    }

                    wishSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $newWish) { WishEditView(item: nil) }
            .sheet(isPresented: $newHousehold) { ProductEditView(product: nil, household: true) }
            .sheet(item: $editWish) { w in WishEditView(item: w) }
            .sheet(item: $doneWish) { w in WishDoneView(item: w) }
            .sheet(item: $purchaseSource) { source in
                PurchaseEditView(source: source,
                                 items: f.shoppingList(for: source).filter { !excluded.contains($0.product.persistentModelID) })
            }
        }
    }

    @ViewBuilder
    private func listSection(_ source: Source, _ list: [(product: Product, status: Forecast.Status)], subtitle: String, info: String?) -> some View {
        let included = list.filter { !excluded.contains($0.product.persistentModelID) }
        let estimate = included.reduce(0.0) { $0 + Double($1.status.packages) * $1.product.price }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.label).font(.system(size: 20, weight: .heavy))
                    Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if estimate > 0 {
                    Text("ca. \(Fmt.euro(estimate))").font(.system(size: 15, weight: .bold))
                }
            }

            if list.isEmpty {
                Text("Nichts nötig – alles reicht bis zum nächsten Einkauf.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .card(14, radius: 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(list, id: \.product.persistentModelID) { item in
                        itemRow(item.product, item.status)
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 8) {
                    ShareLink(item: shareText(source, included)) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Button { purchaseSource = source } label: {
                        Text(source == .rewe ? "Lieferung erhalten" : "Eingekauft")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(source == .rewe ? Theme.accent : Theme.ink,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            if let info {
                Text(info).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var wishSection: some View {
        let open = wishes.filter { !$0.done }.sorted {
            ($0.dueDate ?? .distantFuture, $0.createdAt) < ($1.dueDate ?? .distantFuture, $1.createdAt)
        }
        let done = wishes.filter(\.done)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wunschliste").font(.system(size: 20, weight: .heavy))
                    Text("Einmalige Dinge mit Link, Foto und Erinnerung").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { newWish = true } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Neuer Wunsch")
            }
            if open.isEmpty {
                Text("Nichts auf der Wunschliste.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .card(14, radius: 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(open) { w in
                        WishRow(item: w, onEdit: { editWish = w }, onDone: { doneWish = w })
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            if !done.isEmpty {
                Button(showDoneWishes ? "Erledigte ausblenden" : "\(done.count) erledigt anzeigen") { showDoneWishes.toggle() }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minHeight: 44)
                if showDoneWishes {
                    VStack(spacing: 0) {
                        ForEach(done) { w in
                            WishRow(item: w, onEdit: { editWish = w }, onDone: {
                                w.done = false
                                w.doneAt = nil
                                Notifier.evaluate(context)
                            })
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private func itemRow(_ p: Product, _ st: Forecast.Status) -> some View {
        let isOn = !excluded.contains(p.persistentModelID)
        return Button {
            if isOn { excluded.insert(p.persistentModelID) } else { excluded.remove(p.persistentModelID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Theme.accent : Theme.line)
                ProductImage(photo: p.photo, emoji: p.emoji, tint: p.tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("\(st.packages) × \(Fmt.amount(p.packageSize, p.unit))\(p.source == .sonstiges && !p.storeName.isEmpty ? " · \(p.storeName)" : "")\(p.fallbackName.isEmpty ? "" : " · sonst \(p.fallbackName)")")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if p.price > 0 {
                    Text(Fmt.euro(Double(st.packages) * p.price)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                }
            }
            .frame(minHeight: 56)
            .opacity(isOn ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "auf der Liste" : "ausgelassen")
    }

    private func shareText(_ source: Source, _ list: [(product: Product, status: Forecast.Status)]) -> String {
        let lines = list.map { "• \($0.status.packages) × \($0.product.name) (\(Fmt.amount($0.product.packageSize, $0.product.unit)))" }
        return "\(source.listName):\n" + lines.joined(separator: "\n")
    }
}

// MARK: - Einkauf / Lieferung verbuchen

struct PurchaseEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let source: Source
    /// Produkte, deren Bestand nach dem Einkauf aufgefüllt wird (leer = nur Betrag buchen).
    var items: [(product: Product, status: Forecast.Status)] = []

    @State private var total: Double = 0
    @State private var date = Date()
    @State private var note = ""
    @State private var showScanner = false
    @State private var scanMessage: String?
    @State private var pickedSource: Source = .rewe

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Betrag")
                        Spacer()
                        TextField("0,00", value: $total, format: .number.precision(.fractionLength(2)).locale(Fmt.de))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 22, weight: .bold))
                        Text("€").foregroundStyle(Theme.muted)
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label("Kassenbon scannen", systemImage: "doc.viewfinder")
                    }
                    if let scanMessage { Text(scanMessage).font(.footnote).foregroundStyle(Theme.muted) }
                } footer: {
                    if source == .rewe {
                        Text("Bei REWE-Lieferungen trägt die Warenkorb-Automatik den Rechnungsbetrag später selbst ein.")
                    }
                }

                Section {
                    if items.isEmpty {
                        Picker("Bezugsquelle", selection: $pickedSource) {
                            ForEach(Source.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                        .environment(\.locale, Fmt.de)
                    TextField("Notiz", text: $note)
                }

                if !items.isEmpty {
                    Section("Wird im Vorrat aufgefüllt") {
                        ForEach(items, id: \.product.persistentModelID) { item in
                            HStack {
                                Text("\(item.product.emoji) \(item.product.name)")
                                Spacer()
                                Text("+ \(Fmt.amount(item.status.orderAmount, item.product.unit))").foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .navigationTitle(items.isEmpty ? "Ausgabe eintragen" : "\(source.label) verbuchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Sichern", action: save) }
            }
            .sheet(isPresented: $showScanner) {
                ReceiptScannerView { images in
                    showScanner = false
                    guard !images.isEmpty else { return }
                    Task { @MainActor in
                        if let v = await ReceiptReader.total(from: images) {
                            total = v
                            scanMessage = "Summe vom Bon übernommen – bitte kurz prüfen."
                        } else {
                            scanMessage = "Summe nicht erkannt – bitte von Hand eintragen."
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .onAppear { pickedSource = source }
        }
    }

    private func save() {
        let src = items.isEmpty ? pickedSource : source
        context.insert(Purchase(date: date, source: src, total: total, itemCount: items.count, note: note))
        for item in items {
            item.product.setStock(item.product.currentStock() + item.status.orderAmount)
            item.product.lowNotifiedAt = nil
            item.product.lastCheckedAt = Date()
        }
        Notifier.evaluate(context)
        dismiss()
    }
}
