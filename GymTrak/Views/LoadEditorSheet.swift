import SwiftUI

/// Structured editor for one load string, shaped by the exercise's load type, so
/// the stored notation can't drift ("225 lb", "Max + 10", "5 pl + 25", "+70").
struct LoadEditorSheet: View {
    let title: String
    let loadType: LoadType
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var n = ""
    @State private var add = ""
    @State private var max = false
    @State private var lb = false
    @State private var assisted = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch loadType {
                case .weight:
                    numberRow("Weight", $n, unit: "lb")
                case .machine:
                    Toggle("Max (top of stack)", isOn: $max)
                    if max {
                        numberRow("Extra", $add, unit: "lb")
                    } else {
                        numberRow(lb ? "Weight" : "Level", $n, unit: lb ? "lb" : nil)
                        Toggle("Reading is in pounds", isOn: $lb)
                    }
                case .plates:
                    numberRow("Plates", $n, unit: "pl")
                    numberRow("Extra", $add, unit: "lb")
                case .bodyweight:
                    Picker("Mode", selection: $assisted) {
                        Text("Added").tag(false)
                        Text("Assisted").tag(true)
                    }
                    .pickerStyle(.segmented)
                    numberRow(assisted ? "Assistance" : "Added", $add, unit: "lb")
                    Text("Leave empty for plain bodyweight.").font(.footnote).foregroundStyle(.secondary)
                case .free:
                    TextField("Load", text: $text).focused($focused)
                }
                Section {
                    LabeledContent("Saves as", value: preview.isEmpty ? "—" : preview)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(preview); dismiss() }.bold()
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium])
    }

    private func numberRow(_ label: String, _ value: Binding<String>, unit: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(maxWidth: 120)
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
    }

    private func load() {
        let p = parseLoad(initial, type: loadType)
        n = p.n.map(fmtNum) ?? ""
        max = p.max
        lb = p.lb || (loadType == .machine && (p.n ?? 0) > 20)
        if loadType == .bodyweight {
            assisted = (p.add ?? 0) < 0
            add = p.add.map { fmtNum(abs($0)) } ?? ""
        } else {
            add = p.add.map(fmtNum) ?? ""
        }
        text = p.text ?? initial
        focused = true
    }

    private var preview: String {
        let num = Double(n.replacingOccurrences(of: ",", with: "."))
        let extra = Double(add.replacingOccurrences(of: ",", with: "."))
        switch loadType {
        case .weight: return formatLoad(StructuredLoad(type: .weight, n: num))
        case .machine: return formatLoad(StructuredLoad(type: .machine, n: max ? nil : num, max: max, add: max ? extra : nil, lb: lb))
        case .plates: return formatLoad(StructuredLoad(type: .plates, n: num, add: extra))
        case .bodyweight: return formatLoad(StructuredLoad(type: .bodyweight, add: extra.map { assisted ? -$0 : $0 }))
        case .free: return text.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Reps editor: a number, stored as "× N".
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
                    TextField("0", text: $value).keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($focused)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(repsToken(value)); dismiss() }.bold()
                }
            }
            .onAppear { value = bareReps(initial); focused = true }
        }
        .presentationDetents([.height(220)])
    }
}
