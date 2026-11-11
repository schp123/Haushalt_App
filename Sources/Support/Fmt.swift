import Foundation

enum Fmt {
    static let de = Locale(identifier: "de_DE")

    static func euro(_ v: Double) -> String {
        v.formatted(.currency(code: "EUR").locale(de))
    }

    static func number(_ v: Double, maxFraction: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(0...maxFraction)).locale(de))
    }

    static func amount(_ v: Double, _ unit: StockUnit) -> String {
        "\(number(v)) \(unit.short)"
    }

    static func kcal(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)).grouping(.automatic).locale(de))
    }

    static let weekdayNames = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    static let weekdayShorts = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// iso: 1 = Montag … 7 = Sonntag
    static func weekdayName(_ iso: Int) -> String { weekdayNames[max(1, min(7, iso)) - 1] }
    static func weekdayShort(_ iso: Int) -> String { weekdayShorts[max(1, min(7, iso)) - 1] }

    static func time(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func longDate(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(de))
    }

    static func shortDate(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(de))
    }

    static func monthYear(_ d: Date) -> String {
        d.formatted(.dateTime.month(.wide).year().locale(de))
    }

    static func monthShort(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).locale(de))
    }
}

extension Calendar {
    /// 1 = Montag … 7 = Sonntag
    func isoWeekday(_ d: Date) -> Int {
        let w = component(.weekday, from: d)
        return w == 1 ? 7 : w - 1
    }
}
