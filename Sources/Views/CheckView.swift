import SwiftUI
import SwiftData

/// Täglicher Vorrats-Check: fragt nur die Produkte ab, bei denen die Rechnung unsicher ist.
struct CheckView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Product.sortIndex) private var products: [Product]
    @Query private var plan: [PlanEntry]
    @Query private var settingsList: [AppSettings]
    @Query private var logs: [MealLog]

    @State private var queue: [Product] = []
    @State private var index = 0
    @State private var draft: Double = 0
    @State private var answered: [(name: String, text: String, corrected: Bool)] = []
    @State private var started = false

    private var forecast: Forecast {
        Forecast(products: products, plan: plan, settings: settingsList.first ?? AppSettings(), logs: logs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            topBar
            if !queue.isEmpty {
                progress
            }
            if index < queue.count {
                question(queue[index])
            } else if started {
                finished
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.ground)
        .onAppear(perform: start)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
            }
            .foregroundStyle(Theme.ink)
            .accessibilityLabel("Check schließen")
            Spacer()
            if index < queue.count {
                Text("\(index + 1) von \(queue.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Später") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 44)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<queue.count, id: \.self) { i in
                Capsule()
                    .fill(i < index ? Theme.accent : (i == index ? Theme.ink : Color(hex: "DCD9D0")))
                    .frame(height: 5)
            }
        }
    }

    @ViewBuilder
    private func question(_ p: Product) -> some View {
        let st = forecast.status(p)
        VStack(alignment: .leading, spacing: 4) {
            Text("Täglicher Check").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            Text("Was ist noch da?").font(.system(size: 26, weight: .heavy))
        }

        VStack(spacing: 14) {
            ProductImage(photo: p.photo, emoji: p.emoji, tint: p.tint, size: 88)
            VStack(spacing: 4) {
                Text(p.name).font(.system(size: 22, weight: .heavy))
                Text("Laut App sind noch \(Fmt.amount(p.currentStock(), p.unit)) da. Stimmt das?")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 18) {
                stepButton("minus", "Weniger") { draft = max(0, draft - p.unit.step) }
                VStack(spacing: 0) {
                    Text(Fmt.number(draft)).font(.system(size: 40, weight: .heavy))
                    Text(p.unit.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                .frame(minWidth: 80)
                stepButton("plus", "Mehr") { draft += p.unit.step }
            }
            HStack(spacing: 8) {
                Button("Ist leer") { answer(p, value: 0) }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.warnText)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.warnBorder, lineWidth: 2))
                Button("Stimmt") { answer(p, value: draft) }
                    .buttonStyle(PrimaryButtonStyle(color: Theme.ink))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

        if st.needsRestock {
            warning(p, st)
        }

        if !answered.isEmpty {
            checkedList
        }
    }

    private func warning(_ p: Product, _ st: Forecast.Status) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.warnText)
                .frame(width: 36, height: 36)
                .background(Color(hex: "F7DCC6"), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(st.level == .leer ? "Leer" : "Reicht nicht bis zum Einkauf")
                    .font(.system(size: 14, weight: .bold))
                Text("\(st.packages) × \(Fmt.amount(p.packageSize, p.unit)) stehen auf der \(p.source.listName).")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "5E4A3A"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var checkedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schon geprüft").font(.system(size: 15, weight: .bold))
            VStack(spacing: 0) {
                ForEach(Array(answered.enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text(a.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(a.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        Image(systemName: a.corrected ? "pencil" : "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(a.corrected ? Theme.warnText : Theme.accent)
                            .accessibilityLabel(a.corrected ? "korrigiert" : "bestätigt")
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var finished: some View {
        let f = forecast
        let needed = Source.allCases.flatMap { f.shoppingList(for: $0) }
        return VStack(alignment: .leading, spacing: 16) {
            Text("Alles erfasst 👍").font(.system(size: 26, weight: .heavy))
            Text(needed.isEmpty
                 ? "Bis zum nächsten Einkauf reicht alles."
                 : "\(needed.count) Produkte stehen auf euren Listen.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
            if !answered.isEmpty { checkedList }
            Button("Fertig") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func stepButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
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

    private func start() {
        guard !started else { return }
        started = true
        queue = forecast.checkCandidates()
        draft = queue.first?.currentStock() ?? 0
    }

    private func answer(_ p: Product, value: Double) {
        let before = p.currentStock()
        let corrected = abs(value - before) > 0.0001
        let text = corrected ? "\(Fmt.number(value)) statt \(Fmt.amount(before, p.unit))" : Fmt.amount(value, p.unit)
        answered.append((name: p.name, text: text, corrected: corrected))
        if corrected { p.lastCorrectedAt = Date() }
        p.setStock(value)
        p.lastCheckedAt = Date()
        Notifier.evaluate(context)
        index += 1
        if index < queue.count { draft = queue[index].currentStock() }
    }
}
