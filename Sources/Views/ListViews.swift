import SwiftUI
import SwiftData

/// Freie Einkaufsliste im Tab „Einkauf“ – per Hand oder per Sprache befüllt.
struct ShoppingListSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ListItem.createdAt) private var items: [ListItem]

    @State private var text = ""
    @State private var source: Source = .rewe
    @State private var store = ""
    @FocusState private var focused: Bool

    var body: some View {
        let open = items.filter { !$0.done }
        let done = items.filter(\.done)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Einkaufsliste").font(.system(size: 20, weight: .heavy))
                    Text("Alles, was zusätzlich mit soll").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if !done.isEmpty {
                    Button("Erledigte entfernen") {
                        for i in done { context.delete(i) }
                        Notifier.evaluate(context)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minHeight: 44)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("z. B. 2 Zitronen", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .frame(minHeight: 48)
                    Menu {
                        ForEach(Source.allCases) { s in
                            Button(s.label) { source = s }
                        }
                    } label: {
                        Text(source == .sonstiges && !store.isEmpty ? store : source.label)
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(Theme.color(for: source).opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Laden wählen")
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Hinzufügen")
                }
                if source == .sonstiges {
                    TextField("Laden (Biomarkt, dm …)", text: $store)
                        .font(.system(size: 14))
                        .frame(minHeight: 40)
                }

                ForEach(open + done) { item in
                    Divider()
                    row(item)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func row(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            Button {
                item.done.toggle()
                Notifier.evaluate(context)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.done ? Theme.accent : Theme.line)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Wieder offen" : "Abhaken")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.quantity.isEmpty ? item.name : "\(item.quantity) \(item.name)")
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.muted : Theme.ink)
                Text(item.whereToBuy).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .frame(minHeight: 50)
        .contextMenu {
            Button("Löschen", role: .destructive) {
                context.delete(item)
                Notifier.evaluate(context)
            }
        }
    }

    private func add() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let parts = ListItem.split(t)
        context.insert(ListItem(name: parts.name, quantity: parts.quantity, source: source,
                                storeName: source == .sonstiges ? store : ""))
        text = ""
        focused = true
        Notifier.evaluate(context)
    }
}
