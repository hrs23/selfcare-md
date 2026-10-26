import SelfcareCore
import SwiftUI

struct CopySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: String
    let onCopy: (DailyDocument) -> Void
    @State private var mode = 0
    @State private var day = Date()

    var recent: [(date: String, doc: DailyDocument)] {
        app.index.dailies(app.vault)
            .filter { $0.date != target && $0.doc.fileProblem == nil && !$0.doc.entries.isEmpty }
            .suffix(21)
            .reversed()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Recent").tag(0)
                    Text("Calendar").tag(1)
                    Text("Template").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                switch mode {
                case 0:
                    List(recent, id: \.date) { item in
                        Button {
                            copy(item.doc)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DayTitle.text(item.date, today: app.today())).foregroundStyle(.primary)
                                Text(item.doc.entries.map(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .tint(.primary)
                    }
                    .themed()
                case 1:
                    let date = DayDate.string(day)
                    let doc = app.loadDaily(date).doc
                    List {
                        DatePicker("", selection: $day, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        if let doc, doc.fileProblem == nil, !doc.entries.isEmpty, date != target {
                            Section {
                                ForEach(doc.entries) { e in Text(e.name) }
                            }
                            Button("Copy") { copy(doc) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .themed()
                default:
                    List {
                        if let t = app.template(), t.fileProblem == nil, !t.entries.isEmpty {
                            Section {
                                ForEach(t.entries) { e in Text(e.name) }
                            }
                            Button("Copy") { copy(t) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .themed()
                }
            }
            .navigationTitle("Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    func copy(_ doc: DailyDocument) {
        onCopy(doc)
        dismiss()
    }
}

struct ReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: DayModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.doc?.entries ?? []) { e in
                    Text(e.name)
                }
                .onMove { from, to in model.move(from: from, to: to) }
            }
            .themed()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct TemplateEditorView: View {
    @Environment(AppModel.self) private var app
    @State private var doc: DailyDocument?
    @State private var adding = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if let problem = doc?.fileProblem {
                FileProblemRow(path: Vault.templatePath, message: problem)
            } else if let doc {
                Section {
                    ForEach(doc.entries) { e in
                        TemplateRow(entry: e)
                    }
                    .onDelete { offsets in
                        mutate { d in
                            for i in offsets.sorted(by: >) { d.deleteEntry(d.entries[i].line) }
                        }
                    }
                    .onMove { from, to in
                        guard let first = from.first else { return }
                        mutate { $0.moveEntry(from: first, to: to) }
                    }
                }
            }
        }
        .themed()
        .environment(\.editMode, $editMode)
        .navigationTitle("Daily template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                    Button {
                        app.show(.markdown(Vault.templatePath))
                    } label: { Label("Edit Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
                } label: { Image(systemName: "ellipsis.circle") }
                if editMode == .active {
                    Button("Done") { editMode = .inactive }
                } else {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .disabled(doc?.fileProblem != nil)
                }
            }
        }
        .sheet(isPresented: $adding) {
            MenuPickerSheet(title: "Add") { menu in
                mutate { $0.addEntry(name: menu.name, record: menu.record) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: app.revision) { _, _ in load() }
    }

    func load() {
        doc = app.template() ?? DailyDocument.newTemplate()
    }

    func mutate(_ change: (inout DailyDocument) -> Void) {
        var d = app.template() ?? DailyDocument.newTemplate()
        guard d.fileProblem == nil else { return }
        change(&d)
        do {
            try app.vault.write(Vault.templatePath, d.text)
            doc = d
            app.vaultChanged()
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

struct TemplateRow: View {
    @Environment(AppModel.self) private var app
    let entry: Entry

    var body: some View {
        let record = app.record(entry.name)
        HStack(spacing: 10) {
            if record == .avoid {
                StatusIcon(state: entry.checkbox ?? true ? .kept : .broken)
            } else if !entry.sets.isEmpty || record == .sets {
                StatusIcon(state: .open)
            } else {
                StatusIcon(state: entry.checkbox == true ? .done : .open)
            }
            VStack(alignment: .leading, spacing: 2) {
                EntryName(entry: entry, imported: false)
                if !entry.valueText.isEmpty {
                    Text(entry.valueText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(entry.sets) { s in
                    Text(s.valueText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}
