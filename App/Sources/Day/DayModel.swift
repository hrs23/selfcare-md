import Foundation
import Observation
import SelfcareCore

@Observable
final class DayModel {
    let date: String
    unowned let app: AppModel
    private(set) var doc: DailyDocument?
    private(set) var unreadable = false
    private(set) var previous: [Int: Value] = [:]
    private(set) var history = TextHistory()
    private(set) var celebration = 0
    private(set) var completionPulse = 0
    var editing: Int?
    private var editingSnapshotTaken = false
    private var loadedRevision = -1

    init(date: String, app: AppModel) {
        self.date = date
        self.app = app
    }

    var path: String { Vault.dailyPath(date) }
    var isToday: Bool { date == app.today() }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func reloadIfNeeded() {
        if loadedRevision != app.revision { load() }
    }

    func load() {
        if isToday { app.ensureTodayCopied() }
        let result = app.loadDaily(date)
        doc = result.doc
        unreadable = result.unreadable
        loadedRevision = app.revision
        computePrevious()
    }

    private func computePrevious() {
        var map: [Int: Value] = [:]
        guard let doc else {
            previous = [:]
            return
        }
        let all = app.index.dailies(app.vault)
        for e in doc.entries {
            if let v = VaultIndex.previousValue(in: all, menu: e.name, date: date, current: doc, beforeLine: e.line) {
                map[e.line] = v
            }
        }
        previous = map
    }

    func clearHistory() {
        history.clear()
        editing = nil
    }

    func isComplete(_ d: DailyDocument) -> Bool {
        d.isAllComplete { self.app.record($0.name) }
    }

    private func diskText() -> String?? {
        do {
            return .some(try app.vault.readIfExists(path))
        } catch {
            app.alert = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func mutate(completing: Bool = false, snapshot: Bool = true, _ change: (inout DailyDocument) -> Void) -> Bool {
        guard let before = diskText() else { return false }
        if before.map({ DailyDocument(text: $0).text }) != doc?.text {
            load()
            return false
        }
        var working = doc ?? app.newDaily(date)
        guard working.fileProblem == nil else { return false }
        let wasComplete = isComplete(working)
        change(&working)
        guard working.text != (before ?? "") else { return false }
        let after = VaultText.normalized(working.text)
        do {
            try app.vault.writeRaw(path, after)
        } catch {
            app.alert = error.localizedDescription
            return false
        }
        history.record(before: before, after: after, merging: !snapshot)
        doc = working
        app.vaultChanged()
        loadedRevision = app.revision
        computePrevious()
        if completing {
            completionPulse += 1
            if !wasComplete && isComplete(working) {
                celebration += 1
            }
        }
        return true
    }

    func undo() {
        guard let disk = diskText() else { return }
        restore(history.undo(disk: disk))
    }

    func redo() {
        guard let disk = diskText() else { return }
        restore(history.redo(disk: disk))
    }

    private func restore(_ target: TextHistory.Target?) {
        editing = nil
        do {
            switch target {
            case let .text(text): try app.vault.writeRaw(path, text)
            case .missing: try app.vault.delete(path)
            case nil: break
            }
        } catch {
            history.clear()
            app.alert = error.localizedDescription
        }
        app.vaultChanged()
        load()
    }

    func initialValue(for entry: Entry, menu: MenuFile?) -> Value {
        let fields = menu?.fields ?? []
        guard !fields.isEmpty else { return Value() }
        if let prev = VaultIndex.previousValue(in: app.index.dailies(app.vault), menu: entry.name, date: date, current: doc, beforeLine: entry.endLine + 1), !prev.isEmpty {
            let restricted = prev.restricted(to: fields)
            if !restricted.isEmpty { return restricted }
        }
        return menu?.initial ?? Value()
    }

    func complete(_ entry: Entry) {
        guard entry.checkbox != true else { return }
        var value: Value?
        if entry.value?.isEmpty ?? true {
            let v = initialValue(for: entry, menu: app.menu(entry.name))
            if !v.isEmpty { value = v }
        }
        mutate(completing: true) { $0.setEntryCheck(entry.line, true, value: value) }
    }

    func uncomplete(_ entry: Entry) {
        mutate { $0.setEntryCheck(entry.line, false) }
    }

    func toggleAvoid(_ entry: Entry) {
        let kept = entry.checkbox ?? true
        mutate(completing: !kept) { $0.setEntryCheck(entry.line, !kept) }
    }

    func toggleSet(_ set: SetLine) {
        mutate(completing: !set.checked) { $0.setSetCheck(set.line, !set.checked) }
    }

    func addSet(_ entry: Entry) {
        let value = entry.sets.last(where: { $0.value != nil })?.value ?? initialValue(for: entry, menu: app.menu(entry.name))
        var newLine: Int?
        mutate(completing: true) { newLine = $0.addSet(to: entry.line, value: value, checked: true) }
        if value.isEmpty, let newLine {
            editing = newLine
            editingSnapshotTaken = true
        }
    }

    func deleteSet(_ set: SetLine) {
        if editing == set.line { editing = nil }
        mutate { $0.deleteSet(set.line) }
    }

    func deleteEntry(_ entry: Entry) {
        editing = nil
        mutate { $0.deleteEntry(entry.line) }
    }

    func add(menu: MenuFile) {
        mutate { $0.addEntry(name: menu.name, record: menu.record) }
    }

    func move(from: IndexSet, to: Int) {
        guard let first = from.first else { return }
        editing = nil
        mutate { $0.moveEntry(from: first, to: to) }
    }

    func beginEditing(_ line: Int) {
        editing = editing == line ? nil : line
        editingSnapshotTaken = false
    }

    func setValue(line: Int, isSet: Bool, value: Value) {
        let snapshot = !editingSnapshotTaken
        let changed = mutate(snapshot: snapshot) { d in
            if isSet { d.setSetValue(line, value) } else { d.setEntryValue(line, value) }
        }
        if changed { editingSnapshotTaken = true }
    }

    func reassign(_ entry: Entry, to name: String) {
        mutate { $0.setEntryLink(entry.line, name: name) }
    }

    func copy(from source: DailyDocument) {
        let blocks = DailyCopy.blocks(from: source) { self.app.record($0) }
        guard !blocks.isEmpty else { return }
        mutate { DailyCopy.append(blocks, to: &$0) }
    }

    func saveMemo(_ memo: String) {
        guard let before = diskText() else { return }
        var working: DailyDocument
        if let before {
            working = DailyDocument(text: before)
        } else {
            guard !memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            working = app.newDaily(date)
        }
        guard working.fileProblem == nil, working.memo != memo.trimmingCharacters(in: .newlines) else { return }
        working.setMemo(memo)
        do {
            try app.vault.write(path, working.text)
            doc = working
            app.vaultChanged()
            loadedRevision = app.revision
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

@Observable
final class DayStore {
    var date: String {
        didSet {
            if oldValue != date {
                for (key, model) in models where key != date { model.clearHistory() }
                models = models.filter { abs(daysBetween($0.key, date)) <= 1 }
            }
        }
    }
    private var models: [String: DayModel] = [:]
    unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        self.date = app.today()
    }

    func model(_ date: String) -> DayModel {
        if let m = models[date] { return m }
        let m = DayModel(date: date, app: app)
        models[date] = m
        return m
    }

    var current: DayModel { model(date) }

    func clearAllHistory() {
        for m in models.values { m.clearHistory() }
    }

    private func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = DayDate.date(a), let db = DayDate.date(b) else { return 99 }
        return Calendar.current.dateComponents([.day], from: da, to: db).day ?? 99
    }
}
