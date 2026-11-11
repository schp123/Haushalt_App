import SwiftUI
import SwiftData
import PhotosUI

/// Eintrag der Wunschliste in der Einkaufsliste.
struct WishRow: View {
    @Environment(\.modelContext) private var context
    let item: WishItem
    var onEdit: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDone) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.done ? Theme.accent : Theme.line)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Erledigt" : "Als gekauft markieren")

            Button(action: onEdit) {
                HStack(spacing: 12) {
                    ProductImage(photo: item.photo, emoji: "🎁", tint: Color(hex: "EEE8F6"), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .strikethrough(item.done)
                            .lineLimit(2)
                        Text(subtitle).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isOverdue ? Theme.warnText : Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if item.price > 0 {
                        Text(Fmt.euro(item.price)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    }
                }
            }
            .buttonStyle(.plain)

            if let url = URL(string: item.linkURL), !item.linkURL.isEmpty {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Link öffnen")
            }
        }
        .frame(minHeight: 60)
        .opacity(item.done ? 0.55 : 1)
    }

    private var isOverdue: Bool {
        guard let d = item.dueDate, !item.done else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    private var subtitle: String {
        var parts: [String] = []
        if !item.storeName.isEmpty { parts.append(item.storeName) }
        if let d = item.dueDate {
            parts.append(isOverdue ? "überfällig seit \(Fmt.shortDate(d))" : "bis \(Fmt.shortDate(d))")
        }
        if !item.note.isEmpty { parts.append(item.note) }
        return parts.isEmpty ? "Wunschliste" : parts.joined(separator: " · ")
    }
}

/// Wunsch anlegen oder bearbeiten – mit Link, Foto und Erinnerungsdatum.
struct WishEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let item: WishItem?

    @State private var name = ""
    @State private var note = ""
    @State private var storeName = ""
    @State private var linkURL = ""
    @State private var photo: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var price: Double = 0
    @State private var hasDue = true
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var loading = false
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Link (Amazon, Biomarkt …)", text: $linkURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { Task { await loadLink() } }
                        if loading { ProgressView() }
                    }
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        Task { @MainActor in
                            linkURL = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            await loadLink()
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.muted) }
                } footer: {
                    Text("Aus einem Link übernimmt die App Name, Laden und Bild.")
                }

                Section("Was?") {
                    TextField("Name, z. B. Rosmarinöl", text: $name)
                    TextField("Laden", text: $storeName)
                    TextField("Notiz", text: $note)
                    PhotoRow(photo: $photo, item: $photoItem)
                    HStack {
                        Text("Preis")
                        Spacer()
                        NumberField(placeholder: "0", value: $price)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                        Text("€").foregroundStyle(Theme.muted)
                    }
                }

                Section {
                    Toggle("Erinnern", isOn: $hasDue).tint(Theme.accent)
                    if hasDue {
                        DatePicker("Kaufen bis", selection: $dueDate, displayedComponents: .date)
                            .environment(\.locale, Fmt.de)
                    }
                } footer: {
                    Text("Am Morgen des Datums kommt eine Erinnerung.")
                }

                if item != nil {
                    Section {
                        Button("Wunsch löschen", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(item == nil ? "Neuer Wunsch" : "Wunsch bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Wunsch löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    if let item { context.delete(item) }
                    Notifier.evaluate(context)
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let w = item else { return }
        name = w.name; note = w.note; storeName = w.storeName; linkURL = w.linkURL
        photo = w.photo; price = w.price
        hasDue = w.dueDate != nil
        if let d = w.dueDate { dueDate = d }
    }

    @MainActor
    private func loadLink() async {
        guard let url = URL(string: linkURL), url.scheme?.hasPrefix("http") == true else { return }
        loading = true
        defer { loading = false }
        let preview = await LinkPreview.load(url)
        if storeName.isEmpty, let s = preview.store { storeName = s }
        if name.isEmpty, let t = preview.title { name = String(t.prefix(60)) }
        if photo == nil, let img = preview.image { photo = ImageTools.jpeg(img) }
        message = preview.title == nil ? "Link gespeichert." : "Vom Link übernommen."
    }

    private func save() {
        let w = item ?? {
            let new = WishItem(name: name)
            context.insert(new)
            return new
        }()
        w.name = name.trimmingCharacters(in: .whitespaces)
        w.note = note
        w.storeName = storeName
        w.linkURL = linkURL.trimmingCharacters(in: .whitespaces)
        w.photo = photo
        w.price = max(0, price)
        w.dueDate = hasDue ? Calendar.current.startOfDay(for: dueDate) : nil
        Notifier.evaluate(context)
        dismiss()
    }
}

/// Beim Abhaken: Preis bestätigen und als Ausgabe buchen.
struct WishDoneView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let item: WishItem
    @State private var price: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Bezahlt")
                        Spacer()
                        NumberField(placeholder: "0", value: $price)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
                            .font(.system(size: 20, weight: .bold))
                        Text("€").foregroundStyle(Theme.muted)
                    }
                } footer: {
                    Text("Wird unter „Haushalt & Wünsche“ in den Ausgaben verbucht – nicht im Lebensmittel-Budget.")
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gekauft") {
                        item.done = true
                        item.doneAt = Date()
                        if price > 0 {
                            context.insert(Purchase(date: Date(), source: .sonstiges, total: price, itemCount: 1,
                                                    note: item.storeName.isEmpty ? item.name : "\(item.name) · \(item.storeName)"))
                        }
                        Notifier.evaluate(context)
                        dismiss()
                    }
                }
            }
            .onAppear { price = item.price }
        }
        .presentationDetents([.medium])
    }
}
