import SwiftUI

/// Type a new load. The field starts empty with the current value as a hint, so you
/// just type; leaving it empty keeps what was there.
struct LoadEditorSheet: View {
    let title: String
    let loadType: LoadType
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    enum MachineMode: String, CaseIterable { case level = "Level", pounds = "lb", max = "Max" }
    enum BodyMode: String, CaseIterable { case plain = "Bodyweight", added = "Added", assisted = "Assisted" }

    @State private var parsed = StructuredLoad(type: .weight)
    @State private var n = ""
    @State private var add = ""
    @State private var text = ""
    @State private var machine = MachineMode.level
    @State private var bodyMode = BodyMode.plain
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch loadType {
                case .weight:
                    field("Weight", $n, hint: parsed.n, unit: "lb")
                case .machine:
                    Picker("Type", selection: $machine) {
                        ForEach(MachineMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if machine == .max {
                        field("Extra", $add, hint: parsed.add, unit: "lb")
                    } else {
                        field(machine == .pounds ? "Weight" : "Level", $n, hint: parsed.n, unit: machine == .pounds ? "lb" : nil)
                    }
                case .plates:
                    field("Plates", $n, hint: parsed.n, unit: nil)
                    field("Extra", $add, hint: parsed.add, unit: "lb", focus: false)
                case .bodyweight:
                    Picker("Type", selection: $bodyMode) {
                        ForEach(BodyMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if bodyMode != .plain {
                        field(bodyMode == .added ? "Added" : "Assisted", $add, hint: parsed.add.map(abs), unit: "lb")
                    }
                case .free:
                    TextField(initial.isEmpty ? "Load" : initial, text: $text).focused($focused)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(result); dismiss() }.bold()
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.height(260)])
    }

    private func field(_ label: String, _ value: Binding<String>, hint: Double?, unit: String?, focus: Bool = true) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(hint.map(fmtNum) ?? "0", text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.title3.weight(.semibold))
                .focused($focused, enabled: focus)
                .frame(maxWidth: 140)
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        parsed = parseLoad(initial, type: loadType)
        machine = parsed.max ? .max : (parsed.lb || (parsed.n ?? 0) > 20) ? .pounds : .level
        bodyMode = (parsed.add ?? 0) > 0 ? .added : (parsed.add ?? 0) < 0 ? .assisted : .plain
        focused = true
    }

    /// Empty fields fall back to the old value.
    private var result: String {
        let num = Double(n.replacingOccurrences(of: ",", with: ".")) ?? (machine == .max ? nil : parsed.n)
        let extra = Double(add.replacingOccurrences(of: ",", with: "."))
        switch loadType {
        case .weight:
            return formatLoad(StructuredLoad(type: .weight, n: num))
        case .machine:
            if machine == .max { return formatLoad(StructuredLoad(type: .machine, max: true, add: extra ?? (parsed.max ? parsed.add : nil))) }
            return formatLoad(StructuredLoad(type: .machine, n: num, lb: machine == .pounds))
        case .plates:
            return formatLoad(StructuredLoad(type: .plates, n: num, add: add.isEmpty ? parsed.add : (extra == 0 ? nil : extra)))
        case .bodyweight:
            let amount = extra ?? parsed.add.map(abs)
            switch bodyMode {
            case .plain: return "BW"
            case .added: return formatLoad(StructuredLoad(type: .bodyweight, add: amount))
            case .assisted: return formatLoad(StructuredLoad(type: .bodyweight, add: amount.map { -$0 }))
            }
        case .free:
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? initial : t
        }
    }
}

/// Reps: type a number. Empty keeps the old value.
struct RepsEditorSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Text("Reps")
                    Spacer()
                    TextField(bareReps(initial).isEmpty ? "0" : bareReps(initial), text: $value)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.title3.weight(.semibold))
                        .focused($focused)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(value.isEmpty ? initial : repsToken(value)); dismiss() }.bold()
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(200)])
    }
}

extension LoadType {
    /// What the big number in a workout means for this load type.
    func valueLabel(for raw: String) -> String {
        switch self {
        case .weight: return "lb"
        case .machine:
            let p = parseLoad(raw, type: .machine)
            return p.max ? "Max" : p.lb ? "lb" : "Level"
        case .plates: return "Plates"
        case .bodyweight: return "Bodyweight"
        case .free: return "Load"
        }
    }
}

private extension View {
    /// Attach focus only to the field that should get the keyboard first.
    @ViewBuilder func focused(_ binding: FocusState<Bool>.Binding, enabled: Bool) -> some View {
        if enabled { focused(binding) } else { self }
    }
}
