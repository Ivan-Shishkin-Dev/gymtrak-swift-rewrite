import SwiftUI

/// The weekly schedule: what each weekday holds. It repeats every week.
struct ScheduleView: View {
    @Environment(Store.self) private var store
    @State private var draft: ProgramWeek?

    var body: some View {
        Form {
            if let draft {
                ForEach(Dow.allCases, id: \.self) { dow in
                    if let i = draft.slots.firstIndex(where: { $0.dow == dow }) {
                        WeekEditorView.slotSection(dow: dow, index: i, draft: $draft, days: store.db.activeDays)
                    }
                }
            }
        }
        .pageBackground()
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if let draft { store.mutate { $0.saveSchedule(draft) } } }
                    .disabled(draft == store.db.scheduleTemplate)
            }
        }
        .onAppear { draft = store.db.scheduleTemplate }
    }
}

enum WeekEditorView {
    @MainActor @ViewBuilder
    static func slotSection(dow: Dow, index i: Int, draft: Binding<ProgramWeek?>, days: [Day]) -> some View {
        let slot = draft.wrappedValue!.slots[i]
        Section(dow.label) {
            Picker("Lift", selection: Binding(get: { slot.liftDayId }, set: { draft.wrappedValue!.slots[i].liftDayId = $0 })) {
                Text("None").tag(Int?.none)
                ForEach(days) { Text($0.name).tag(Int?.some($0.id)) }
            }
            Toggle("Run", isOn: Binding(get: { slot.run != nil }, set: { on in
                draft.wrappedValue!.slots[i].run = on ? makeRun(.easy, minutes: 30, timing: slot.liftDayId == nil ? .standalone : .afterLift) : nil
            }))
            if let run = slot.run {
                Picker("Type", selection: Binding(get: { run.label }, set: { label in
                    let hr = defaultHR(label)
                    draft.wrappedValue!.slots[i].run?.label = label
                    draft.wrappedValue!.slots[i].run?.hrZoneMin = hr.0
                    draft.wrappedValue!.slots[i].run?.hrZoneMax = hr.1
                    draft.wrappedValue!.slots[i].run?.hrHardCap = hr.2
                })) {
                    ForEach(RunLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper(value: Binding(get: { run.durationMin }, set: { draft.wrappedValue!.slots[i].run?.durationMin = $0 }), in: 5...180, step: 5) {
                    LabeledContent("Starting Length", value: "\(run.durationMin) min")
                }
                Toggle("Strides", isOn: Binding(get: { run.strides }, set: { draft.wrappedValue!.slots[i].run?.strides = $0 }))
            }
        }
    }
}
