import SwiftUI
import SwiftData

struct EinstellungenView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsList: [AppSettings]

    var body: some View {
        NavigationStack {
            Group {
                if let s = settingsList.first {
                    SettingsForm(s: s)
                } else {
                    ProgressView().onAppear { _ = AppSettings.current(context) }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        Notifier.evaluate(context)
                        dismiss()
                    }
                }
            }
        }
    }
}

enum AppInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (Build \(b))"
    }
}

private struct SettingsForm: View {
    @Bindable var s: AppSettings

    var body: some View {
        Form {
            Section {
                weekdayPicker("Bestelltag", $s.orderWeekday)
                weekdayPicker("Liefertag", $s.deliveryWeekday)
                TextField("Lieferfenster", text: $s.deliveryWindow)
                weekdayPicker("Warenkorb füllen am", $s.cartFillWeekday)
                DatePicker("um", selection: time($s.cartFillHour, $s.cartFillMinute), displayedComponents: .hourAndMinute)
            } header: {
                Text("REWE Lieferservice")
            } footer: {
                Text("Zu dieser Zeit legt die Automatik auf deinem Mac die Liste in den REWE-Warenkorb. Den Mac dann bitte eingeschaltet lassen.")
            }

            Section("Metzger") {
                weekdayPicker("Einkaufstag", $s.metzgerWeekday)
                DatePicker("Erinnerung um", selection: time($s.metzgerHour, .constant(0)), displayedComponents: .hourAndMinute)
            }

            Section {
                HStack {
                    Text("Monatsbudget")
                    Spacer()
                    NumberField(placeholder: "800", value: $s.budget)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                    Text("€").foregroundStyle(Theme.muted)
                }
                Stepper("Warnen ab \(Int(s.budgetWarnPercent)) % Prognose", value: $s.budgetWarnPercent, in: 50...120, step: 5)
            } header: {
                Text("Budget")
            } footer: {
                Text("REWE und Metzger zählen gemeinsam.")
            }

            Section("Erinnerungen") {
                Toggle("Täglicher Vorrats-Check", isOn: $s.checkEnabled)
                if s.checkEnabled {
                    DatePicker("Uhrzeit", selection: time($s.checkHour, $s.checkMinute), displayedComponents: .hourAndMinute)
                }
                Toggle("Warnen, wenn etwas knapp wird", isOn: $s.lowStockEnabled)
            }
            .tint(Theme.accent)

            Section("Tagesziele") {
                goal("Kalorien", $s.kcalGoal, "kcal")
                goal("Protein", $s.proteinGoal, "g")
                goal("Kohlenhydrate", $s.carbsGoal, "g")
                goal("Fett", $s.fatGoal, "g")
            }

            Section {
                NavigationLink {
                    SyncSettingsView()
                } label: {
                    LabeledContent("Gemeinsam nutzen", value: SyncEngine.shared.isConfigured ? "verbunden" : "aus")
                }
            } header: {
                Text("Haushalt")
            } footer: {
                Text("Beide iPhones teilen Vorrat, Listen, Wunschliste, Wochenplan und Ausgaben.")
            }

            Section {
                NavigationLink {
                    AssistantSettingsView()
                } label: {
                    LabeledContent("Sprach-Assistent", value: AssistantConfig.load().isConfigured ? "eingerichtet" : "aus")
                }
            } header: {
                Text("Assistent")
            } footer: {
                Text("Steuerung per Sprache über OmniRoute – Bestand, Einkaufsliste, Wunschliste, Mahlzeiten und mehr.")
            }

            Section {
                LabeledContent("Version", value: AppInfo.version)
            }
        }
        .environment(\.locale, Fmt.de)
    }

    private func weekdayPicker(_ title: String, _ value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(1...7, id: \.self) { Text(Fmt.weekdayName($0)).tag($0) }
        }
    }

    private func goal(_ title: String, _ value: Binding<Double>, _ suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            NumberField(placeholder: "0", value: value)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
            Text(suffix).foregroundStyle(Theme.muted).frame(minWidth: 34, alignment: .leading)
        }
    }

    private func time(_ hour: Binding<Int>, _ minute: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: hour.wrappedValue, minute: minute.wrappedValue, second: 0, of: Date()) ?? Date()
        } set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            hour.wrappedValue = c.hour ?? 0
            minute.wrappedValue = c.minute ?? 0
        }
    }
}
