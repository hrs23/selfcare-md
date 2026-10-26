import SelfcareCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack(path: $app.settingsPath) {
            List {
                Section {
                    NavigationLink(value: Route.template) { Label("Daily template", systemImage: "doc.text") }
                    NavigationLink(value: Route.sync) {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sync")
                                    if app.sync.failing {
                                        if let last = app.sync.state.lastSuccess {
                                            Text(last.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(app.sync.state.lastError ?? "").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            } icon: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Spacer()
                            Text(syncSummary).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink(value: Route.aiSettings) {
                        HStack {
                            Label("AI", systemImage: "sparkles")
                            Spacer()
                            Text(app.ai.configured ? app.ai.settings.preset.label : "Not set").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink(value: Route.health) { Label("Apple Health", systemImage: "heart") }
                    NavigationLink(value: Route.units) { Label("Units", systemImage: "ruler") }
                }
                Section {
                    NavigationLink(value: Route.files("")) { Label("Files", systemImage: "folder") }
                    NavigationLink(value: Route.information) { Label("Information", systemImage: "info.circle") }
                }
            }
            .themed()
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }

    var syncSummary: String {
        guard let config = app.sync.config else { return "Off" }
        let conflicts = app.sync.conflicts.count
        return conflicts > 0 ? "\(config.kindLabel) · \(conflicts)" : config.kindLabel
    }
}

struct HealthSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var end = Date()

    var health: HealthService { app.health }

    var body: some View {
        Form {
            if !health.available {
                Section { Label("Apple Health is not available", systemImage: "heart.slash").foregroundStyle(.secondary) }
            } else {
                Section {
                    Toggle("Import automatically", isOn: Binding(get: { health.settings.autoImport }, set: { on in
                        Task { await health.setAutoImport(on) }
                    }))
                    Button("Check access") {
                        Task {
                            do { try await health.requestAuthorization() } catch { app.alert = error.localizedDescription }
                        }
                    }
                    Link("Open Health", destination: URL(string: "x-apple-health://")!)
                    if let error = health.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                }
                Section("Types") {
                    NavigationLink {
                        HealthTypesView()
                    } label: {
                        LabeledContent("Types", value: "\(health.enabledTypes.count)")
                    }
                }
                Section("Import a period") {
                    DatePicker("From", selection: $start, displayedComponents: .date)
                    DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                    if let progress = health.rangeProgress {
                        ProgressView(value: progress)
                        Button("Stop", role: .destructive) { health.cancelRangeImport() }
                    } else {
                        Button("Import") { health.startRangeImport(from: start, to: end) }
                    }
                }
            }
        }
        .themed()
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HealthTypesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            row(HealthTypes.workoutKey, "Workouts")
            ForEach(HealthTypes.others, id: \.constant) { def in
                row(def.constant, app.packs.appleName(def.constant))
            }
        }
        .themed()
        .tint(.primary)
        .navigationTitle("Types")
        .navigationBarTitleDisplayMode(.inline)
    }

    func row(_ key: String, _ name: String) -> some View {
        let on = app.health.enabledTypes.contains(key)
        return Button {
            app.health.setEnabled(key, !on)
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }
}

struct UnitsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Picker("Weight", selection: $settings.prefs.units.weight) {
                ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Distance", selection: $settings.prefs.units.distance) {
                ForEach([DistanceUnit.km, .mi], id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Volume", selection: $settings.prefs.units.volume) {
                ForEach(VolumeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Temperature", selection: $settings.prefs.units.temperature) {
                ForEach(TemperatureUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        .themed()
        .navigationTitle("Units")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FilesView: View {
    @Environment(AppModel.self) private var app
    let path: String

    var body: some View {
        let items = app.vault.list(path, recursive: false, includeDirectories: true)
        List(items, id: \.self) { item in
            let isDir = app.vault.isDirectory(item)
            NavigationLink(value: isDir ? Route.files(item) : (item.hasSuffix(".md") ? Route.markdown(item) : Route.fileView(item))) {
                Label((item as NSString).lastPathComponent, systemImage: isDir ? "folder" : icon(item))
            }
        }
        .themed()
        .navigationTitle(path.isEmpty ? "Files" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .id(app.revision)
    }

    func icon(_ item: String) -> String {
        if item.hasSuffix(".md") { return "doc.text" }
        if VaultTools.isImage(item) { return "photo" }
        return "doc"
    }
}

struct FileViewer: View {
    @Environment(AppModel.self) private var app
    let path: String

    var body: some View {
        Group {
            if VaultTools.isImage(path), let url = try? app.vault.url(path) {
                ScrollView {
                    VaultImage(url: url).padding()
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(app.vault.readIfExists(path) ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding()
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct InformationView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let problems = app.problems()
        List {
            Section {
                LabeledContent("Version", value: BuildInfo.version)
                LabeledContent("Vault", value: "On My iPhone › selfcare.md › selfcare")
            }
            Section {
                LabeledContent("Menus", value: "\(app.menus.count)")
                LabeledContent("Daily pages", value: "\(app.vault.dailyDates().count)")
                LabeledContent("Workouts", value: "\(app.vault.list(Vault.workouts).count)")
                LabeledContent("Images", value: "\(app.vault.list(Vault.media).count)")
            }
            if !problems.isEmpty {
                Section("Problems") {
                    ForEach(problems) { p in
                        NavigationLink(value: Route.markdown(p.path)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.path)
                                Text(p.message).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .themed()
        .navigationTitle("Information")
        .navigationBarTitleDisplayMode(.inline)
    }
}
