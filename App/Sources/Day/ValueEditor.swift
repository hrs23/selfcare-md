import SelfcareCore
import SwiftUI

extension Field {
    var label: String {
        switch self {
        case .weight: "Weight"
        case .reps: "Reps"
        case .distance: "Distance"
        case .duration: "Duration"
        case .heartRate: "Heart rate"
        case .percent: "Percent"
        case .bloodPressure: "Blood pressure"
        case .volume: "Volume"
        case .energy: "Energy"
        case .temperature: "Temperature"
        }
    }
}

struct ValueEditor: View {
    let value: Value
    let menuFields: [Field]
    let units: UnitPreferences
    let onChange: (Value) -> Void
    var onDelete: (() -> Void)?
    @State private var extra: [Field] = []

    var fields: [Field] {
        let base = value.isEmpty ? menuFields : value.fields
        return Field.sorted(base + extra)
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(fields) { field in
                FieldStepper(field: field, quantity: value[field], units: units) { q in
                    var v = value
                    v[field] = q
                    onChange(v)
                }
            }
            HStack {
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash").font(.callout)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Menu {
                    ForEach(Field.allCases) { field in
                        Button {
                            toggle(field)
                        } label: {
                            if fields.contains(field) {
                                Label(field.label, systemImage: "checkmark")
                            } else {
                                Text(field.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func toggle(_ field: Field) {
        if fields.contains(field) {
            extra.removeAll { $0 == field }
            var v = value
            v[field] = nil
            if v != value { onChange(v) }
        } else {
            extra.append(field)
        }
    }
}

struct FieldStepper: View {
    let field: Field
    let quantity: Quantity?
    let units: UnitPreferences
    let onChange: (Quantity) -> Void

    var current: Quantity { quantity ?? .zero(field, units: units) }

    var body: some View {
        if field == .bloodPressure {
            VStack(spacing: 6) {
                row(label: "Systolic", part: 0)
                row(label: "Diastolic", part: 1)
            }
        } else {
            row(label: field.label, part: 0)
        }
    }

    func row(label: String, part: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button {
                onChange(current.stepped(-1, part: part))
            } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            DirectInput(field: field, quantity: quantity, part: part, units: units, onChange: onChange)
                .frame(width: 128)
            Button {
                onChange(current.stepped(1, part: part))
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct DirectInput: View {
    let field: Field
    let quantity: Quantity?
    let part: Int
    let units: UnitPreferences
    let onChange: (Quantity) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var display: String {
        guard let q = quantity else { return "" }
        switch q {
        case let .bloodPressure(a, b): return String(part == 0 ? a : b)
        case let .duration(s): return DurationText.format(s)
        default:
            let unit = q.unitText
            let t = q.text
            return unit.isEmpty ? t : String(t.dropLast(unit.count))
        }
    }

    var unit: String {
        switch field {
        case .reps, .duration: ""
        case .bloodPressure: "mmHg"
        default: (quantity ?? .zero(field, units: units)).unitText
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField("0", text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(field == .duration ? .numbersAndPunctuation : (field == .weight ? .numbersAndPunctuation : .decimalPad))
                .font(.body.monospacedDigit())
                .focused($focused)
                .onSubmit(commit)
            if !unit.isEmpty {
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { text = display }
        .onChange(of: quantity) { _, _ in if !focused { text = display } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    func commit() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != display else { return }
        let q: Quantity?
        switch field {
        case .duration:
            if raw.contains(":") {
                q = ValueParser.value(raw)?[.duration]
            } else if let minutes = Double(raw) {
                q = .duration(Int((minutes * 60).rounded()))
            } else {
                q = ValueParser.value(raw)?[.duration]
            }
        case .bloodPressure:
            guard let n = Int(raw), case let .bloodPressure(a, b) = quantity ?? .zero(.bloodPressure, units: units) else { q = nil; break }
            q = part == 0 ? .bloodPressure(n, b) : .bloodPressure(a, n)
        case .reps:
            q = Int(raw).map { .reps(max(0, $0)) }
        default:
            q = ValueParser.value(raw + unit)?[field]
        }
        if let q {
            onChange(q)
        } else {
            text = display
        }
    }
}
