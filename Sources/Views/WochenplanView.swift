import SwiftUI
import SwiftData

struct WochenplanView: View {
    @Environment(\.modelContext) private var context
    @Query private var plan: [PlanEntry]
    @Query(sort: \MealTemplate.name) private var templates: [MealTemplate]
    @State private var newTemplate = false

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    Section {
                        Text("Leg zuerst Vorlagen für eure Gerichte an – dann verteilst du sie hier auf die Woche.")
                            .foregroundStyle(Theme.muted)
                        Button("Neue Vorlage") { newTemplate = true }
                    }
                }
                ForEach(1...7, id: \.self) { day in
                    Section {
                        ForEach(MealSlot.allCases) { slot in
                            slotRow(day: day, slot: slot)
                        }
                    } header: {
                        HStack {
                            Text(Fmt.weekdayName(day))
                            Spacer()
                            Text("\(Fmt.kcal(dayKcal(day))) kcal")
                        }
                    }
                }
                Section {
                    Button("Montag auf alle Tage übertragen") { copyMonday() }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Wochenplan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newTemplate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Neue Vorlage")
                }
            }
            .sheet(isPresented: $newTemplate) { TemplateEditView(template: nil) }
        }
    }

    private func entry(_ day: Int, _ slot: MealSlot) -> PlanEntry? {
        plan.first { $0.weekday == day && $0.slotRaw == slot.rawValue }
    }

    private func dayKcal(_ day: Int) -> Double {
        plan.filter { $0.weekday == day }.reduce(0) { $0 + ($1.template?.nutrition.kcal ?? 0) }
    }

    private func slotRow(day: Int, slot: MealSlot) -> some View {
        let current = entry(day, slot)?.template
        return Menu {
            Button("Nichts geplant") { assign(nil, day: day, slot: slot) }
            ForEach(templates) { t in
                Button("\(t.emoji) \(t.name)") { assign(t, day: day, slot: slot) }
            }
        } label: {
            HStack {
                Text(slot.label).foregroundStyle(Theme.ink)
                Spacer()
                Text(current.map { "\($0.emoji) \($0.name)" } ?? "–")
                    .foregroundStyle(current == nil ? Theme.muted : Theme.ink)
                    .lineLimit(1)
            }
            .frame(minHeight: 36)
        }
    }

    private func assign(_ t: MealTemplate?, day: Int, slot: MealSlot) {
        if let e = entry(day, slot) {
            if let t { e.template = t } else { context.delete(e) }
        } else if let t {
            let e = PlanEntry(weekday: day, slot: slot)
            context.insert(e)
            e.template = t
        }
        Notifier.evaluate(context)
    }

    private func copyMonday() {
        for day in 2...7 {
            for slot in MealSlot.allCases {
                assign(entry(1, slot)?.template, day: day, slot: slot)
            }
        }
    }
}
