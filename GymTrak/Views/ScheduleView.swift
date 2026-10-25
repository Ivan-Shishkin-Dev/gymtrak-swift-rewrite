import SwiftUI

/// Every program week; tap one to change what each day holds.
struct ScheduleView: View {
    @Environment(Store.self) private var store

    var body: some View {
        let weeks = store.db.weeks
        let thisMonday = DateKey.mondayKey(Date())
        List {
            ForEach(weeks) { w in
                NavigationLink { WeekEditorView(weekId: w.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Week \(w.id)").font(.system(size: 16, weight: .semibold))
                                if w.startDate == thisMonday { Text("NOW").eyebrow(Theme.volt) }
                                if w.isDeload { Text("DELOAD").eyebrow(Theme.amber) }
                            }
                            Text("\(DateKey.label(w.startDate, "MMM d")) – \(DateKey.label(DateKey.addDays(w.startDate, 6), "MMM d")) · \(w.runMinutes) min running")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.sub)
                        }
                        Spacer()
                    }
                }
            }
            if store.canEdit, let last = weeks.last {
                Button { store.mutate { $0.duplicateProgramWeek(last.id) } } label: {
                    Label("Add a week (copy of week \(last.id))", systemImage: "plus")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Schedule")
    }
}

/// Edit one week: the lift day and run for each weekday. Past weeks are read-only.
struct WeekEditorView: View {
    let weekId: Int
    @Environment(Store.self) private var store
    @State private var draft: ProgramWeek?

    var body: some View {
        let editable = store.canEdit && (draft?.startDate ?? "") >= DateKey.mondayKey(Date())
        Form {
            if let draft {
                Section {
                    Toggle("Deload week", isOn: binding(\.isDeload))
                } footer: {
                    Text(editable ? "Deload drops the last set of any exercise with 3 or more." : "Past weeks can't be edited.")
                }
                ForEach(Dow.allCases, id: \.self) { dow in
                    if let i = draft.slots.firstIndex(where: { $0.dow == dow }) {
                        slotSection(dow: dow, index: i)
                    }
                }
            }
        }
        .disabled(!editable)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Week \(weekId)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if let draft { store.mutate { $0.updateProgramWeek(draft) } } }
                        .disabled(draft == store.db.weeks.first { $0.id == weekId })
                }
            }
        }
        .onAppear { draft = store.db.weeks.first { $0.id == weekId } }
    }

    private func binding<T>(_ kp: WritableKeyPath<ProgramWeek, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: kp] }, set: { draft![keyPath: kp] = $0 })
    }

    private func slotSection(dow: Dow, index i: Int) -> some View {
        let slot = draft!.slots[i]
        return Section("\(dow.label) · \(DateKey.label(draft!.date(of: dow), "MMM d"))") {
            Picker("Lift", selection: Binding(get: { slot.liftDayId }, set: { draft!.slots[i].liftDayId = $0 })) {
                Text("None").tag(Int?.none)
                ForEach(store.db.activeDays) { Text($0.name).tag(Int?.some($0.id)) }
            }
            Toggle("Run", isOn: Binding(get: { slot.run != nil }, set: { on in
                draft!.slots[i].run = on ? makeRun(.easy, minutes: 30, timing: slot.liftDayId == nil ? .standalone : .afterLift) : nil
            }))
            if let run = slot.run {
                Picker("Type", selection: Binding(get: { run.label }, set: { label in
                    let hr = defaultHR(label)
                    draft!.slots[i].run?.label = label
                    draft!.slots[i].run?.hrZoneMin = hr.0
                    draft!.slots[i].run?.hrZoneMax = hr.1
                    draft!.slots[i].run?.hrHardCap = hr.2
                })) {
                    ForEach(RunLabel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper(value: Binding(get: { run.durationMin }, set: { draft!.slots[i].run?.durationMin = $0 }), in: 5...180, step: 5) {
                    LabeledContent("Duration", value: "\(run.durationMin) min")
                }
                Toggle("Strides", isOn: Binding(get: { run.strides }, set: { draft!.slots[i].run?.strides = $0 }))
                TextField("Notes", text: Binding(get: { run.notes ?? "" }, set: { draft!.slots[i].run?.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
        }
    }
}
