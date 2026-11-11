import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Bild an Gemini schicken und Gericht schätzen lassen

struct MealEstimate {
    struct Item: Identifiable {
        let id = UUID()
        var product: Product
        var amount: Double
        var use = true
    }
    var name = ""
    var kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0
    var note = ""
    var items: [Item] = []
}

@MainActor
enum MealVision {
    static func analyze(_ image: UIImage, hint: String, context ctx: ModelContext) async throws -> MealEstimate {
        guard let jpeg = ImageTools.jpeg(image, maxSide: 1024) else { throw AssistantError.badResponse("Bild konnte nicht gelesen werden") }
        let products = ((try? ctx.fetch(FetchDescriptor<Product>())) ?? []).filter { !$0.isDeleted && $0.isFood }
        let list = products.map {
            "\($0.uuid.uuidString.lowercased().prefix(8)) | \($0.name) | Einheit \($0.unit.rawValue)\($0.unit.isMass ? "" : " (\(Fmt.number($0.gramsPerUnit)) g pro Einheit)")"
        }.joined(separator: "\n")

        let prompt = """
        Schätze das Gericht auf dem Foto für ein Ernährungstagebuch (eine Portion, so wie abgebildet).
        \(hint.isEmpty ? "" : "Hinweis vom Nutzer: \(hint)\n")
        Antworte NUR mit JSON ohne Markdown:
        {"name":"kurzer deutscher Name","kcal":0,"protein":0,"carbs":0,"fat":0,"note":"1 Satz, worauf die Schätzung beruht","ingredients":[{"product":"ID","amount":0}]}
        Makros in Gramm. "ingredients" nur für Zutaten, die eindeutig zu einem Produkt aus dieser Vorratsliste passen,
        Menge in der Einheit des Produkts (gramm/milliliter in g bzw. ml, sonst Stück/Becher/Packung als Anteil, z. B. 0.5):
        \(list.isEmpty ? "(keine Produkte)" : list)
        """
        let message: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
            ]
        ]
        let raw = try await AssistantClient.complete(raw: [message], config: AssistantConfig.load(), timeout: 30)
        guard let json = Assistant.extractJSON(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw AssistantError.badResponse(raw)
        }
        func num(_ v: Any?) -> Double {
            if let d = v as? Double, d.isFinite { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return NumberField.parse(s) ?? 0 }
            return 0
        }
        var est = MealEstimate(name: obj["name"] as? String ?? "Mahlzeit", kcal: num(obj["kcal"]), protein: num(obj["protein"]),
                               carbs: num(obj["carbs"]), fat: num(obj["fat"]), note: obj["note"] as? String ?? "")
        for i in obj["ingredients"] as? [[String: Any]] ?? [] {
            guard let ref = (i["product"] as? String)?.lowercased(), !ref.isEmpty,
                  let p = products.first(where: { $0.uuid.uuidString.lowercased().hasPrefix(ref) || $0.name.lowercased() == ref }) else { continue }
            let amount = num(i["amount"])
            if amount > 0 { est.items.append(.init(product: p, amount: amount)) }
        }
        return est
    }
}

// MARK: - Ablauf: Foto → Schätzung prüfen → speichern

struct MealPhotoView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var hint = ""
    @State private var analyzing = false
    @State private var error: String?
    @State private var estimate: MealEstimate?
    @State private var slot = MealSlot.forNow()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .listRowInsets(EdgeInsets())
                    }
                    Button {
                        showCamera = true
                    } label: {
                        Label("Foto aufnehmen", systemImage: "camera")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Aus Fotos wählen", systemImage: "photo")
                    }
                    TextField("Hinweis (optional), z. B. „große Portion, mit Olivenöl“", text: $hint)
                } footer: {
                    Text("Gemini schätzt Gericht, Kalorien und Makros und erkennt Zutaten aus eurem Vorrat. Du kannst alles vor dem Speichern anpassen.")
                }

                if analyzing {
                    Section { HStack { ProgressView(); Text("Schätze …").foregroundStyle(Theme.muted) } }
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.warnText) }
                }

                if estimate != nil {
                    estimateSections
                }
            }
            .navigationTitle("Mahlzeit per Foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).disabled(estimate == nil)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    showCamera = false
                    if let img { use(img) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { use(img) }
                }
            }
        }
    }

    @ViewBuilder
    private var estimateSections: some View {
        if let binding = Binding($estimate) {
            Section {
                TextField("Gericht", text: binding.name)
                Picker("Mahlzeit", selection: $slot) {
                    ForEach(MealSlot.allCases) { Text($0.label).tag($0) }
                }
                row("Kalorien", binding.kcal, "kcal")
                row("Protein", binding.protein, "g")
                row("Kohlenhydrate", binding.carbs, "g")
                row("Fett", binding.fat, "g")
            } header: {
                Text("Schätzung")
            } footer: {
                if !binding.wrappedValue.note.isEmpty { Text(binding.wrappedValue.note) }
            }

            if !binding.wrappedValue.items.isEmpty {
                Section {
                    ForEach(binding.items) { $item in
                        Toggle(isOn: $item.use) {
                            HStack {
                                Text("\(item.product.emoji) \(item.product.name)")
                                Spacer()
                                Text(Fmt.amount(item.amount, item.product.unit)).foregroundStyle(Theme.muted)
                            }
                        }
                        .tint(Theme.accent)
                    }
                } header: {
                    Text("Vom Vorrat abbuchen")
                } footer: {
                    Text("Ausgewählte Zutaten werden vom Bestand abgezogen und ihre Kosten der Mahlzeit zugerechnet.")
                }
            }
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            NumberField(placeholder: "0", value: value, fractionDigits: 0)
                .multilineTextAlignment(.trailing).frame(maxWidth: 90)
            Text(unit).foregroundStyle(Theme.muted).frame(minWidth: 34, alignment: .leading)
        }
    }

    private func use(_ img: UIImage) {
        image = img
        estimate = nil
        error = nil
        analyzing = true
        Task { @MainActor in
            defer { analyzing = false }
            do {
                estimate = try await MealVision.analyze(img, hint: hint, context: context)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let est = estimate else { return }
        var cost = 0.0
        for item in est.items where item.use {
            cost += item.product.cost(for: item.amount)
            item.product.setStock(item.product.currentStock() - item.amount)
        }
        let log = MealLog(date: Date(), slot: slot, name: est.name.isEmpty ? "Mahlzeit" : est.name, emoji: "📸",
                          nutrition: Nutrition(kcal: est.kcal, protein: est.protein, carbs: est.carbs, fat: est.fat),
                          cost: cost, fromPlan: false)
        log.uuid = UUID()
        context.insert(log)
        Notifier.evaluate(context)
        dismiss()
    }
}

/// Kamera (UIKit) für das Mahlzeiten-Foto.
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
    }
}
