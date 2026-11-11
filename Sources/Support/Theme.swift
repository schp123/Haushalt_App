import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

enum Theme {
    static let ground = Color(hex: "F6F4EF")
    static let card = Color.white
    static let ink = Color(hex: "1B1D1A")
    static let inkSoft = Color(hex: "2E302C")
    static let muted = Color(hex: "6B6A64")
    static let mutedOnDark = Color(hex: "D4D2CB")
    static let line = Color(hex: "E3E0D8")
    static let track = Color(hex: "ECEAE4")
    static let accent = Color(hex: "2F7D4F")
    static let warn = Color(hex: "E07A2E")
    static let warnBorder = Color(hex: "E9A06A")
    static let warnText = Color(hex: "B4531A")
    static let warnSoft = Color(hex: "FDF1E7")
    static let amber = Color(hex: "E9A23B")
    static let amberText = Color(hex: "8A5A10")
    static let protein = Color(hex: "2F5FA8")
    static let carbs = Color(hex: "E9A23B")
    static let fat = Color(hex: "8A5BB8")
    static let metzger = Color(hex: "E9A23B")
    static let sonstiges = Color(hex: "8A5BB8")

    static let tints = ["FBF1DC", "E6EEF8", "F3ECE1", "FBE6DF", "EFEEE9", "E3F1E6", "FBE3E3", "EEE8F6", "E8F0DA"]

    /// Stabile Kachelfarbe aus dem Namen (unabhängig vom zufälligen hashValue).
    static func tintHex(for name: String) -> String {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return tints[sum % tints.count]
    }

    static func color(for source: Source) -> Color {
        switch source {
        case .rewe: accent
        case .metzger: metzger
        case .sonstiges: sonstiges
        }
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(_ padding: CGFloat = 16, radius: CGFloat = 22) -> some View {
        modifier(CardStyle(padding: padding, radius: radius))
    }
}

/// Fortschrittsbalken wie im Entwurf.
struct Bar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Emoji auf farbiger Kachel.
struct EmojiTile: View {
    var emoji: String
    var tint: Color
    var size: CGFloat = 40
    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String? = nil
    var trailingColor: Color = Theme.muted
    var body: some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .bold))
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 13, weight: .semibold)).foregroundStyle(trailingColor)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Zahlenfeld, das jede Eingabe sofort übernimmt (auch wenn man direkt auf „Sichern“ tippt).
struct NumberField: View {
    var placeholder: String = "0"
    @Binding var value: Double
    var fractionDigits: Int = 2

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .focused($focused)
            .onAppear { text = Self.format(value, fractionDigits) }
            .onChange(of: text) { _, t in
                if let v = Self.parse(t) {
                    if v != value { value = v }
                } else if t.trimmingCharacters(in: .whitespaces).isEmpty {
                    value = 0
                }
            }
            .onChange(of: value) { _, v in
                if !focused, Self.parse(text) != v { text = Self.format(v, fractionDigits) }
            }
    }

    static func format(_ v: Double, _ digits: Int) -> String {
        v == 0 ? "" : v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never).locale(Fmt.de))
    }

    static func parse(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(",") {
            t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        return Double(t)
    }
}
