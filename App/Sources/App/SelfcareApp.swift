import SelfcareCore
import SwiftUI

@main
struct SelfcareApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.foreground() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Day", systemImage: "checklist", value: AppTab.day) {
                DayScreen()
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryScreen()
            }
            Tab("AI", systemImage: "sparkles", value: AppTab.ai) {
                AIScreen()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsScreen()
            }
            .badge(app.sync.failing ? Text("!") : nil)
        }
        .onAppear { KeyboardDismisser.shared.install() }
        .onChange(of: app.tab) { _, _ in KeyboardDismisser.dismiss() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { KeyboardDismisser.dismiss() }
            }
        }
        .alert("Error", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(app.alert ?? "")
        }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case let .menu(name): MenuDetailView(name: name)
        case let .newMenu(name): MenuEditorView(mode: .create(name))
        case let .editMenu(name): MenuEditorView(mode: .edit(name))
        case let .markdown(path): MarkdownEditorView(path: path)
        case .template: TemplateEditorView()
        case let .workout(uuid): WorkoutDetailView(uuid: uuid)
        case .packs: PacksView()
        case let .pack(id): PackDetailView(id: id)
        case .sync: SyncSettingsView()
        case .conflicts: ConflictsView()
        case let .conflict(path): ConflictResolveView(path: path)
        case .aiSettings: AISettingsView()
        case .health: HealthSettingsView()
        case .units: UnitsView()
        case let .files(path): FilesView(path: path)
        case let .fileView(path): FileViewer(path: path)
        case .information: InformationView()
        }
    }
}

extension AppModel {
    func refresh(date: String) async {
        await health.importDay(date)
        await sync.run(trigger: .pull)
        vaultChanged()
    }
}
