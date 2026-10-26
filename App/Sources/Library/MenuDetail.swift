import Charts
import SelfcareCore
import SwiftUI

struct MenuDetailView: View {
    @Environment(AppModel.self) private var app
    let name: String
    @State private var history: [HistoryItem] = []
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var pickingDay = false
    @State private var day = Date()

    var menu: MenuFile? { app.menu(name) }

    var body: some View {
        Group {
            if let menu {
                if menu.hasProblem {
                    List {
                        FileProblemRow(path: Vault.menuPath(menu.name), message: menu.problems.joined(separator: "\n"))
                    }
                    .themed()
                } else {
                    content(menu)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let menu, !menu.hasProblem {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu { secondary(menu) } label: { Image(systemName: "ellipsis.circle") }
                    Button {
                        add(menu, to: app.today())
                    } label: {
                        Label("Add to Today", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear(perform: loadHistory)
        .onChange(of: app.revision) { _, _ in loadHistory() }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try app.deleteMenu(name)
                    pop()
                } catch {
                    app.alert = error.localizedDescription
                }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                do {
                    try app.renameMenu(name, to: newName)
                    replaceRoute(with: newName)
                } catch {
                    app.alert = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $pickingDay) {
            NavigationStack {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pickingDay = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                if let menu { add(menu, to: DayDate.string(day)) }
                                pickingDay = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    func loadHistory() {
        history = app.index.history(app.vault, menu: name)
    }

    func content(_ menu: MenuFile) -> some View {
        List {
            QuickStatusSection(target: Vault.menuPath(menu.name))
            Section {
                if let url = app.thumbnailURL(menu), menu.thumbnail != nil {
                    VaultImage(url: url)
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.canvas)
                }
                MenuSummary(menu: menu)
                if !menu.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownView(text: menu.body, imageResolver: { app.resolveImage($0, from: "menus") })
                        .padding(.vertical, 4)
                }
            }
            if !history.isEmpty {
                Section("Weekly") {
                    WeeklyChart(history: history, today: app.today())
                        .frame(height: 120)
                }
                ForEach(menu.fields) { field in
                    let points = MenuStats.points(history: history, field: field, units: app.units)
                    if points.count >= 1 {
                        Section(field.label) {
                            TrendChart(points: points, field: field, units: app.units)
                                .frame(height: 160)
                        }
                    }
                }
                Section("History") {
                    ForEach(history.prefix(200)) { item in
                        Button {
                            app.tab = .day
                            NotificationCenter.default.post(name: .openDay, object: item.date)
                        } label: {
                            HistoryRow(item: item)
                        }
                    }
                }
            }
        }
        .themed()
    }

    @ViewBuilder
    func secondary(_ menu: MenuFile) -> some View {
        Button { add(menu, to: nil) } label: { Label("Add to template", systemImage: "doc.badge.plus") }
        Button { day = Date(); pickingDay = true } label: { Label("Add to a day…", systemImage: "calendar.badge.plus") }
        Divider()
        Button { app.show(.editMenu(menu.name)) } label: { Label("Edit", systemImage: "pencil") }
        Button { newName = menu.name; renaming = true } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
        Button { app.show(.markdown(Vault.menuPath(menu.name))) } label: { Label("Edit Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
        Divider()
        Button { app.ai.runQuick(.menuTidy, target: Vault.menuPath(menu.name), date: app.today()) } label: { Label("Tidy up with AI", systemImage: "wand.and.sparkles") }
            .disabled(app.ai.quickRunning)
        if app.ai.imageGenerationAvailable && menu.thumbnailReference == nil {
            Button { app.ai.runQuick(.menuImage, target: Vault.menuPath(menu.name), date: app.today()) } label: { Label("Create image", systemImage: "photo") }
                .disabled(app.ai.quickRunning)
        }
        Button { app.openChat(attachments: [Vault.menuPath(menu.name)], text: "Help me with the form, the weight and alternatives for this Menu.") } label: { Label("Chat about this Menu", systemImage: "bubble.left.and.text.bubble.right") }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
    }

    func add(_ menu: MenuFile, to date: String?) {
        if let date {
            let model = DayModel(date: date, app: app)
            model.load()
            model.add(menu: menu)
        } else {
            var t = app.template() ?? DailyDocument.newTemplate()
            guard t.fileProblem == nil else {
                app.alert = "The template has a problem"
                return
            }
            t.addEntry(name: menu.name, record: menu.record)
            do {
                try app.vault.write(Vault.templatePath, t.text)
                app.vaultChanged()
            } catch {
                app.alert = error.localizedDescription
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func pop() {
        switch app.tab {
        case .day: _ = app.dayPath.popLast()
        case .library: _ = app.libraryPath.popLast()
        case .ai: _ = app.aiPath.popLast()
        case .settings: _ = app.settingsPath.popLast()
        }
    }

    func replaceRoute(with newName: String) {
        func fix(_ path: inout [Route]) {
            if let i = path.lastIndex(of: .menu(name)) { path[i] = .menu(newName) }
        }
        fix(&app.dayPath)
        fix(&app.libraryPath)
        fix(&app.aiPath)
        fix(&app.settingsPath)
    }
}

extension Notification.Name {
    static let openDay = Notification.Name("selfcare.openDay")
}

struct MenuSummary: View {
    @Environment(AppModel.self) private var app
    let menu: MenuFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(menu.record.rawValue)
                if !menu.fields.isEmpty {
                    Text("·")
                    Text(menu.fields.map(\.label).joined(separator: ", "))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let type = menu.appleHealth {
                Label(app.packs.appleName(type), systemImage: "heart.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !menu.tags.isEmpty {
                Text(menu.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(item.date).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.entry.sets.isEmpty {
                    Text(summary(item.entry)).foregroundStyle(.primary)
                } else {
                    ForEach(item.entry.sets) { s in
                        HStack(spacing: 4) {
                            Text(s.valueText.isEmpty ? "✓" : s.valueText)
                            if !s.checked { Image(systemName: "circle").font(.caption2) }
                        }
                        .foregroundStyle(s.checked ? .primary : .tertiary)
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
    }

    func summary(_ e: Entry) -> String {
        let mark = e.checkbox == true ? "✓" : (e.checkbox == false ? "✗" : "–")
        return e.valueText.isEmpty ? mark : e.valueText
    }
}

struct WeeklyChart: View {
    let history: [HistoryItem]
    let today: String

    var body: some View {
        let weeks = MenuStats.weeklyCounts(history: history, weeks: 12, today: today)
        Chart(weeks, id: \.weekStart) { w in
            BarMark(x: .value("Week", w.weekStart, unit: .weekOfYear), y: .value("Days", w.count))
                .foregroundStyle(Color.accentColor)
        }
        .chartYScale(domain: 0...7)
        .chartYAxis { AxisMarks(values: [0, 7]) }
    }
}

struct TrendChart: View {
    let points: [MenuStats.Point]
    let field: Field
    let units: UnitPreferences

    var unitLabel: String {
        switch field {
        case .weight: units.weight.rawValue
        case .distance: units.distance.rawValue
        case .duration: "min"
        case .heartRate: "bpm"
        case .percent: "%"
        case .bloodPressure: "mmHg"
        case .volume: units.volume.rawValue
        case .energy: "kcal"
        case .temperature: units.temperature.rawValue
        case .reps: ""
        }
    }

    var domain: ClosedRange<Date> {
        let cal = Calendar.current
        let dates = points.compactMap { DayDate.date($0.date) }
        let last = cal.date(byAdding: .day, value: 1, to: dates.max() ?? Date())!
        let first = min(dates.min() ?? Date(), cal.date(byAdding: .day, value: -13, to: last)!)
        return first...last
    }

    var body: some View {
        Chart(points) { p in
            let y = field == .duration ? p.value / 60 : p.value
            if let date = DayDate.date(p.date) {
                LineMark(x: .value("Day", date, unit: .day), y: .value(unitLabel, y))
                    .foregroundStyle(by: .value("Series", p.series))
                PointMark(x: .value("Day", date, unit: .day), y: .value(unitLabel, y))
                    .foregroundStyle(by: .value("Series", p.series))
            }
        }
        .chartLegend(field == .bloodPressure ? .visible : .hidden)
        .chartYAxisLabel(unitLabel)
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }
}
