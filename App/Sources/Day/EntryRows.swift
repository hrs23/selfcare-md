import SelfcareCore
import SwiftUI

extension AppModel {
    func healthType(for entry: Entry) -> String? {
        if let m = menu(entry.name), let type = m.appleHealth { return type }
        return packs.catalog.values.first { $0.name == entry.name }?.type
    }
}

struct StatusIcon: View {
    enum State { case open, done, kept, broken, partial }
    let state: State

    var body: some View {
        Group {
            switch state {
            case .open: Image(systemName: "circle").foregroundStyle(Color(.tertiaryLabel))
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            case .kept: Image(systemName: "checkmark.shield.fill").foregroundStyle(Color.accentColor)
            case .broken: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .partial: Image(systemName: "circle.lefthalf.filled").foregroundStyle(Color.accentColor)
            }
        }
        .font(.title2)
        .frame(width: 30)
        .contentTransition(.symbolEffect(.replace))
    }
}

struct EntryName: View {
    @Environment(AppModel.self) private var app
    let entry: Entry
    let imported: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.name).foregroundStyle(.primary)
            if app.menu(entry.name) == nil && !imported {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).font(.caption)
            } else if let m = app.menu(entry.name), m.hasProblem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
            if imported {
                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink.opacity(0.8))
            }
        }
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var app
    let model: DayModel
    let entry: Entry
    let onMissing: () -> Void
    let onCreateApple: ((type: String, name: String)) -> Void
    let onReassign: () -> Void

    var menu: MenuFile? { app.menu(entry.name) }
    var record: Record? { app.record(entry.name) }
    var imported: Bool { entry.marker != nil }
    var isAvoid: Bool { record == .avoid }
    var missing: Bool { menu == nil }

    var state: StatusIcon.State {
        if isAvoid { return entry.checkbox ?? true ? .kept : .broken }
        return entry.checkbox == true ? .done : .open
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: tap) {
                StatusIcon(state: state)
            }
            .buttonStyle(.borderless)
            .disabled(imported || (missing && !imported) || menu?.hasProblem == true)
            VStack(alignment: .leading, spacing: 2) {
                EntryName(entry: entry, imported: imported)
                if !entry.valueText.isEmpty {
                    Text(entry.valueText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if entry.checkbox != true, !isAvoid, let prev = model.previous[entry.line], entry.valueText.isEmpty {
                    Text(prev.text).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if imported, let type = app.healthType(for: entry), type.hasPrefix("HKWorkoutActivityType"), let uuid = entry.marker?.uuid {
                    WorkoutExtra(uuid: uuid)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: rowTap)
        .contextMenu { menuItems }
    }

    func tap() {
        if isAvoid {
            model.toggleAvoid(entry)
        } else if entry.checkbox != true {
            model.complete(entry)
        }
    }

    func rowTap() {
        if imported {
            if let type = app.healthType(for: entry), type.hasPrefix("HKWorkoutActivityType"), let uuid = entry.marker?.uuid {
                app.show(.workout(uuid))
            } else if missing, let type = app.healthType(for: entry) {
                onCreateApple((type, entry.name))
            }
            return
        }
        if missing {
            onMissing()
            return
        }
        if menu?.hasProblem == true {
            app.show(.menu(entry.name))
            return
        }
        if isAvoid || entry.checkbox != true {
            tap()
        } else if !(menu?.fields.isEmpty ?? true) || !entry.valueText.isEmpty {
            model.beginEditing(entry.line)
        }
    }

    @ViewBuilder
    var menuItems: some View {
        if !imported && !isAvoid && entry.checkbox == true {
            Button { model.uncomplete(entry) } label: { Label("Mark as not done", systemImage: "circle") }
        }
        if !imported && !isAvoid && (!(menu?.fields.isEmpty ?? true) || !entry.valueText.isEmpty) {
            Button { model.beginEditing(entry.line) } label: { Label("Edit value", systemImage: "slider.horizontal.3") }
        }
        if imported {
            if let type = app.healthType(for: entry), type.hasPrefix("HKWorkoutActivityType"), let uuid = entry.marker?.uuid {
                Button { app.show(.workout(uuid)) } label: { Label("Workout details", systemImage: "figure.run") }
            }
            Button(action: onReassign) { Label("Change Menu", systemImage: "arrow.triangle.swap") }
        }
        if missing {
            if imported, let type = app.healthType(for: entry) {
                Button { onCreateApple((type, entry.name)) } label: { Label("Create Menu", systemImage: "plus") }
            } else {
                Button(action: onMissing) { Label("Create Menu", systemImage: "plus") }
            }
        } else {
            Button { app.show(.menu(entry.name)) } label: { Label("Open Menu", systemImage: "doc.text") }
        }
        if !imported {
            Button(role: .destructive) { model.deleteEntry(entry) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct SetsHeaderRow: View {
    @Environment(AppModel.self) private var app
    let model: DayModel
    let entry: Entry
    let onMissing: () -> Void
    let onCreateApple: ((type: String, name: String)) -> Void
    let onReassign: () -> Void

    var menu: MenuFile? { app.menu(entry.name) }
    var imported: Bool { entry.isImported }
    var missing: Bool { menu == nil }

    var state: StatusIcon.State {
        if entry.sets.isEmpty { return .open }
        let done = entry.sets.filter(\.checked).count
        if done == entry.sets.count { return .done }
        return done == 0 ? .open : .partial
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(state: state)
            VStack(alignment: .leading, spacing: 2) {
                EntryName(entry: entry, imported: imported)
                if let prev = model.previous[entry.line] {
                    Text(prev.text).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if !entry.sets.isEmpty {
                Text("\(entry.sets.filter(\.checked).count)/\(entry.sets.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !missing && menu?.hasProblem != true {
                Button {
                    model.addSet(entry)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if missing {
                if imported, let type = app.healthType(for: entry) { onCreateApple((type, entry.name)) } else { onMissing() }
            } else {
                app.show(.menu(entry.name))
            }
        }
        .contextMenu {
            if !missing && menu?.hasProblem != true {
                Button { model.addSet(entry) } label: { Label("Add set", systemImage: "plus") }
                Button { app.show(.menu(entry.name)) } label: { Label("Open Menu", systemImage: "doc.text") }
            } else if missing {
                if imported, let type = app.healthType(for: entry) {
                    Button { onCreateApple((type, entry.name)) } label: { Label("Create Menu", systemImage: "plus") }
                } else {
                    Button(action: onMissing) { Label("Create Menu", systemImage: "plus") }
                }
            }
            if imported {
                Button(action: onReassign) { Label("Change Menu", systemImage: "arrow.triangle.swap") }
            } else {
                Button(role: .destructive) { model.deleteEntry(entry) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

struct SetRow: View {
    @Environment(AppModel.self) private var app
    let model: DayModel
    let entry: Entry
    let item: SetLine

    var imported: Bool { item.marker != nil }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleSet(item)
            } label: {
                StatusIcon(state: item.checked ? .done : .open)
            }
            .buttonStyle(.borderless)
            .disabled(imported || app.record(entry.name) == nil)
            Text(item.valueText.isEmpty ? "—" : item.valueText)
                .font(.body.monospacedDigit())
                .foregroundStyle(item.checked ? .primary : .secondary)
            if imported {
                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 24)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !imported, app.record(entry.name) != nil else {
                if imported, let uuid = item.marker?.uuid, app.healthType(for: entry)?.hasPrefix("HKWorkoutActivityType") == true {
                    app.show(.workout(uuid))
                }
                return
            }
            model.beginEditing(item.line)
        }
        .contextMenu {
            if !imported {
                Button { model.toggleSet(item) } label: { Label(item.checked ? "Mark as not done" : "Mark as done", systemImage: "checkmark") }
                Button { model.beginEditing(item.line) } label: { Label("Edit value", systemImage: "slider.horizontal.3") }
                Button(role: .destructive) { model.deleteSet(item) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

struct WorkoutExtra: View {
    @Environment(AppModel.self) private var app
    let uuid: String
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .task(id: uuid) {
            text = await app.health.summaryExtra(uuid: uuid)
        }
    }
}
