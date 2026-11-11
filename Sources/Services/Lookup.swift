import Foundation
import SwiftData
import UIKit
import Vision

// MARK: - Mahlzeit eintragen (bucht Zutaten vom Vorrat ab)

@MainActor
enum MealLogger {
    static func log(template: MealTemplate, slot: MealSlot, fromPlan: Bool, context: ModelContext, date: Date = Date()) {
        var n = Nutrition()
        var cost = 0.0
        for ing in template.ingredients {
            guard let p = ing.product else { continue }
            n = n + p.nutrition(for: ing.amount)
            cost += p.cost(for: ing.amount)
            p.stock = max(0, p.stock - ing.amount)
        }
        context.insert(MealLog(date: date, slot: slot, name: template.name, emoji: template.emoji,
                               nutrition: n, cost: cost, fromPlan: fromPlan))
        Notifier.evaluate(context)
    }
}

// MARK: - Open Food Facts (freie Produktdatenbank, Nährwerte per Barcode)

struct OFFProduct {
    var name: String
    var brand: String?
    var quantity: String?
    var kcal: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
}

enum OpenFoodFacts {
    static func lookup(barcode: String) async -> OFFProduct? {
        let fields = "product_name,product_name_de,brands,quantity,nutriments"
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Wocheneinkauf-iOS/0.1 (private Nutzung)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["status"] as? Int) == 1,
              let p = obj["product"] as? [String: Any] else { return nil }

        let n = p["nutriments"] as? [String: Any] ?? [:]
        func num(_ key: String) -> Double? {
            if let d = n[key] as? Double { return d }
            if let s = n[key] as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }
        let nameDE = (p["product_name_de"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = nameDE ?? (p["product_name"] as? String) ?? ""
        return OFFProduct(name: name, brand: p["brands"] as? String, quantity: p["quantity"] as? String,
                          kcal: num("energy-kcal_100g"), protein: num("proteins_100g"),
                          carbs: num("carbohydrates_100g"), fat: num("fat_100g"))
    }
}

// MARK: - Eingabe deuten: Name, REWE-Artikelnummer, REWE-Link oder Barcode

enum ProductInput {
    case barcode(String)
    case rewe(number: String, nameHint: String?, url: String?)
    case name(String)

    static func parse(_ raw: String) -> ProductInput? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Link (z. B. aus der REWE-App über „Teilen“ kopiert)
        if let r = t.range(of: "https?://\\S+", options: .regularExpression),
           let url = URL(string: String(t[r])), url.host?.contains("rewe") == true {
            let comps = url.pathComponents.filter { $0 != "/" }
            if let num = comps.last(where: { $0.count >= 5 && $0.allSatisfy(\.isNumber) }) {
                var hint: String? = nil
                if let i = comps.firstIndex(of: num), i > 0, comps[i - 1] != "p" {
                    hint = comps[i - 1].replacingOccurrences(of: "-", with: " ").capitalized(with: Fmt.de)
                }
                return .rewe(number: num, nameHint: hint, url: url.absoluteString)
            }
        }

        // Nur Ziffern: 12–14 Stellen = Barcode (EAN), sonst REWE-Artikelnummer
        if t.allSatisfy(\.isNumber) {
            return (12...14).contains(t.count) ? .barcode(t) : .rewe(number: t, nameHint: nil, url: nil)
        }
        return .name(t)
    }
}

// MARK: - Passendes Emoji zum Namen

enum EmojiGuess {
    private static let table: [(String, String)] = [
        ("eier", "🥚"), ("milch", "🥛"), ("hafer", "🌾"), ("müsli", "🥣"), ("hähnchen", "🍗"), ("huhn", "🍗"),
        ("pute", "🍗"), ("reis", "🍚"), ("brokkoli", "🥦"), ("apfel", "🍎"), ("äpfel", "🍎"), ("skyr", "🥣"),
        ("joghurt", "🥣"), ("quark", "🥣"), ("avocado", "🥑"), ("banane", "🍌"), ("brot", "🍞"), ("käse", "🧀"),
        ("lachs", "🐟"), ("fisch", "🐟"), ("thunfisch", "🐟"), ("rind", "🥩"), ("steak", "🥩"), ("hack", "🥩"),
        ("schwein", "🥩"), ("kartoffel", "🥔"), ("süßkartoffel", "🍠"), ("tomate", "🍅"), ("gurke", "🥒"),
        ("paprika", "🫑"), ("karotte", "🥕"), ("möhre", "🥕"), ("zwiebel", "🧅"), ("knoblauch", "🧄"),
        ("nudel", "🍝"), ("pasta", "🍝"), ("butter", "🧈"), ("öl", "🫒"), ("nuss", "🥜"), ("nüsse", "🥜"),
        ("mandel", "🥜"), ("erdnuss", "🥜"), ("beere", "🫐"), ("spinat", "🥬"), ("salat", "🥬"), ("kaffee", "☕️"),
        ("wasser", "💧"), ("honig", "🍯"), ("zitrone", "🍋"), ("pilz", "🍄"), ("champignon", "🍄"), ("mais", "🌽"),
        ("bohne", "🫘"), ("linse", "🫘"), ("kichererbse", "🫘"), ("wurst", "🌭"), ("speck", "🥓"), ("schinken", "🥓"),
        ("tofu", "🧊"), ("whey", "💪"), ("protein", "💪"), ("orange", "🍊"), ("traube", "🍇"), ("erdbeer", "🍓"),
        ("wrap", "🌯"), ("tortilla", "🌯"), ("ei", "🥚")
    ]

    static func emoji(for name: String) -> String {
        let n = name.lowercased(with: Fmt.de)
        if n == "ei" { return "🥚" }
        for (key, e) in table where key != "ei" && n.contains(key) { return e }
        return "🛒"
    }

    static let picker = ["🥚", "🥛", "🌾", "🥣", "🍗", "🥩", "🐟", "🍚", "🍝", "🍞", "🥔", "🥦", "🥬", "🥕", "🍅",
                         "🥒", "🫑", "🧅", "🧄", "🍄", "🌽", "🫘", "🍎", "🍌", "🫐", "🍓", "🍊", "🍋", "🥑", "🧀",
                         "🧈", "🫒", "🥜", "🍯", "☕️", "💧", "💪", "🌯", "🥓", "🛒"]
}

// MARK: - Kassenbon lesen (auf dem Gerät, ohne Internet)

enum ReceiptReader {
    static func total(from images: [UIImage]) async -> Double? {
        var lines: [String] = []
        for img in images {
            guard let cg = img.cgImage else { continue }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["de-DE"]
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            lines += (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        return parseTotal(lines)
    }

    static func parseTotal(_ lines: [String]) -> Double? {
        let keys = ["zu zahlen", "summe", "gesamt", "total", "betrag", "ec-karte", "kartenzahlung"]
        for (i, line) in lines.enumerated() where keys.contains(where: { line.lowercased().contains($0) }) {
            let window = [line] + lines[(i + 1)..<min(i + 3, lines.count)]
            if let v = window.compactMap(firstAmount).first { return v }
        }
        return lines.compactMap(firstAmount).max()
    }

    static func firstAmount(_ s: String) -> Double? {
        guard let r = s.range(of: "\\d{1,4}[.,]\\d{2}", options: .regularExpression) else { return nil }
        return Double(s[r].replacingOccurrences(of: ",", with: "."))
    }
}
