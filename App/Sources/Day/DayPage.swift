import SelfcareCore
import SwiftUI

enum DayRow: Identifiable {
    case entry(Entry)
    case setsHeader(Entry)
    case set(Entry, SetLine)
    case editor(Entry, SetLine?)
    case heading(Int, String)
    case problem(Int, String, String?)

    var id: String {
        switch self {
        case let .entry(e): "e\(e.line)"
        case let .setsHeader(e): "h\(e.line)"
        case let .set(_, s): "s\(s.line)"
        case let .editor(e, s): "v\(s?.line ?? e.line)"
        case let .heading(l, _): "t\(l)"
        case let .problem(l, _, _): "p\(l)"
        }
    }
}

struct DayPage: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: DayModel
    @State private var memo = ""
    @State private var memoTask: Task<Void, Never>?
    @FocusState private var memoFocused: Bool
    @State private var createName: String?
    @State private var createApple: (type: String, name: String)?
    @State private var reassigning: Entry?

    var body: some View {
        List {
            if app.timer.isRunning {
                Section { TimerBanner() }
            }
            if model.unreadable {
                FileProblemRow(path: model.path, message: "The file is not UTF-8")
            } else if let problem = model.doc?.fileProblem {
                FileProblemRow(path: model.path, message: problem)
            } else {
                let rows = self.rows
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                } else if !app.ai.quickRunning(for: model.path) {
                    Section {
                        Button {
                            app.ai.runQuick(.dayPlan, target: model.path, date: model.date)
                        } label: {
                            Label("Plan with AI", systemImage: "wand.and.sparkles")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                QuickStatusSection(target: model.path)
            }
            if model.doc?.fileProblem == nil && !model.unreadable {
                Section("Memo") {
                    TextField("", text: $memo, axis: .vertical)
                        .lineLimit(3...)
                        .focused($memoFocused)
                        .onChange(of: memo) { _, new in scheduleMemoSave(new) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .themed()
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            await app.refresh(date: model.date)
        }
        .onAppear {
            model.load()
            memo = model.doc?.memo ?? ""
        }
        .onChange(of: app.revision) { _, _ in
            model.reloadIfNeeded()
            if !memoFocused { memo = model.doc?.memo ?? "" }
        }
        .onChange(of: memoFocused) { _, focused in
            if !focused {
                memoTask?.cancel()
                model.saveMemo(memo)
            }
        }
        .overlay { CelebrationView(trigger: model.celebration) }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.completionPulse)
        .confirmationDialog("Create Menu?", isPresented: Binding(get: { createName != nil }, set: { if !$0 { createName = nil } }), titleVisibility: .visible) {
            Button("Create “\(createName ?? "")”") {
                if let name = createName { app.show(.newMenu(name)) }
                createName = nil
            }
        }
        .confirmationDialog("Create Menu?", isPresented: Binding(get: { createApple != nil }, set: { if !$0 { createApple = nil } }), titleVisibility: .visible) {
            Button("Create “\(createApple?.name ?? "")”") {
                if let c = createApple {
                    do { try app.createMenuFromApple(c.type, name: c.name) } catch { app.alert = error.localizedDescription }
                }
                createApple = nil
            }
        }
        .sheet(item: $reassigning) { entry in
            MenuPickerSheet(title: "Change Menu", filter: { menu in
                menu.record == (app.record(entry.name) ?? catalogRecord(entry) ?? .check) && menu.name != entry.name
            }, includePacks: false) { menu in
                model.reassign(entry, to: menu.name)
            }
        }
    }

    private func scheduleMemoSave(_ text: String) {
        guard text != (model.doc?.memo ?? "") else { return }
        memoTask?.cancel()
        memoTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            model.saveMemo(text)
        }
    }

    private func catalogRecord(_ entry: Entry) -> Record? {
        app.packs.catalog.values.first { $0.name == entry.name }?.record
    }

    var rows: [DayRow] {
        guard let doc = model.doc else { return [] }
        var rows: [DayRow] = []
        for item in doc.items {
            switch item {
            case let .heading(line, text):
                rows.append(.heading(line, text))
            case let .raw(line, text):
                rows.append(.problem(line, text, "Unreadable line"))
            case let .entry(e):
                if let p = e.problem {
                    rows.append(.problem(e.line, e.raw, p))
                    for s in e.sets { rows.append(.problem(s.line, s.raw, nil)) }
                    continue
                }
                let record = app.record(e.name) ?? (app.menu(e.name) == nil ? catalogRecord(e) : nil)
                let setsShape = !e.sets.isEmpty || (e.checkbox == nil && record == .sets)
                if setsShape {
                    rows.append(.setsHeader(e))
                    for s in e.sets {
                        if let problem = s.problem {
                            rows.append(.problem(s.line, s.raw, problem))
                        } else {
                            rows.append(.set(e, s))
                            if model.editing == s.line { rows.append(.editor(e, s)) }
                        }
                    }
                } else {
                    rows.append(.entry(e))
                    if model.editing == e.line { rows.append(.editor(e, nil)) }
                }
            }
        }
        return rows
    }

    @ViewBuilder
    func rowView(_ row: DayRow) -> some View {
        switch row {
        case let .heading(_, text):
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        case let .problem(_, text, message):
            Button {
                app.show(.markdown(model.path))
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text.trimmingCharacters(in: .whitespaces)).font(.callout.monospaced()).foregroundStyle(.primary)
                        if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            .tint(.primary)
        case let .entry(e):
            EntryRow(model: model, entry: e, onMissing: { createName = e.name }, onCreateApple: { createApple = $0 }, onReassign: { reassigning = e })
        case let .setsHeader(e):
            SetsHeaderRow(model: model, entry: e, onMissing: { createName = e.name }, onCreateApple: { createApple = $0 }, onReassign: { reassigning = e })
        case let .set(e, s):
            SetRow(model: model, entry: e, item: s)
        case let .editor(e, s):
            ValueEditor(value: (s?.value ?? e.value) ?? Value(), menuFields: app.menu(e.name)?.fields ?? [], units: app.units, onChange: { v in
                model.setValue(line: s?.line ?? e.line, isSet: s != nil, value: v)
            }, onDelete: s.map { set in { model.deleteSet(set) } })
        }
    }
}

struct FileProblemRow: View {
    @Environment(AppModel.self) private var app
    let path: String
    let message: String

    var body: some View {
        Section {
            Button {
                app.show(.markdown(path))
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("Edit Markdown")
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct QuickStatusSection: View {
    @Environment(AppModel.self) private var app
    let target: String

    var body: some View {
        if let quick = app.ai.quick, quick.target == target {
            Section {
                if quick.running {
                    HStack {
                        ProgressView()
                        Text(quick.kind.label).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { app.ai.stopQuick() }
                    }
                } else if let error = quick.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        Spacer()
                        Button { app.ai.dismissQuick() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                } else if quick.canUndo {
                    HStack {
                        Label(quick.kind.label, systemImage: "sparkles").foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { app.ai.undoQuick() }.buttonStyle(.borderless)
                        Button { app.ai.dismissQuick() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct CelebrationView: View {
    let trigger: Int
    @State private var visible = false
    @State private var scale: CGFloat = 0.3
    @State private var ring: CGFloat = 0.3

    var body: some View {
        ZStack {
            if visible {
                Circle()
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 6)
                    .frame(width: 160, height: 160)
                    .scaleEffect(ring)
                    .opacity(2 - ring)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(scale)
                    .shadow(color: .accentColor.opacity(0.4), radius: 20)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            let heavy = UIImpactFeedbackGenerator(style: .heavy)
            heavy.impactOccurred(intensity: 1)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            visible = true
            scale = 0.3
            ring = 0.3
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1 }
            withAnimation(.easeOut(duration: 0.9)) { ring = 2 }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeIn(duration: 0.3)) { visible = false }
            }
        }
    }
}
