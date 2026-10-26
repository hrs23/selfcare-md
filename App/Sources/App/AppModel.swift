import Foundation
import Observation
import SelfcareCore
import SwiftUI

enum AppTab: Hashable {
    case day, library, ai, settings
}

enum Route: Hashable {
    case menu(String)
    case newMenu(String)
    case editMenu(String)
    case markdown(String)
    case template
    case workout(String)
    case packs
    case pack(String)
    case sync
    case conflicts
    case conflict(String)
    case aiSettings
    case health
    case units
    case files(String)
    case fileView(String)
    case information
}

struct PendingChat: Equatable {
    var attachments: [String]
    var text: String
}

@Observable
final class AppModel {
    let settings: Settings
    let vault: Vault
    let index = VaultIndex()
    let packs: PackStore
    private(set) var menus: [MenuFile] = []
    private(set) var revision = 0
    var tab: AppTab = .day
    var dayPath: [Route] = []
    var libraryPath: [Route] = []
    var aiPath: [Route] = []
    var settingsPath: [Route] = []
    var pendingChat: PendingChat?
    var alert: String?
    var health: HealthService!
    var sync: SyncService!
    var timer: WorkoutTimer!
    var ai: AIService!

    init() {
        settings = Settings()
        vault = Vault(root: AppFiles.vaultRoot)
        vault.ensureStructure()
        packs = PackStore(settings: settings)
        reloadMenus()
        health = HealthService(model: self)
        sync = SyncService(model: self)
        timer = WorkoutTimer(model: self)
        ai = AIService(model: self)
    }

    var units: UnitPreferences { settings.prefs.units }

    func today() -> String { DayDate.string(Date()) }

    func reloadMenus() {
        let types = packs.appleTypes
        menus = vault.menuNames().compactMap { name in
            guard let text = try? vault.read(Vault.menuPath(name)) else {
                return MenuFile(name: name, text: "---\nrecord: [unreadable]\n---\n", appleHealthTypes: types)
            }
            return MenuFile(name: name, text: text, appleHealthTypes: types)
        }
    }

    func vaultChanged() {
        reloadMenus()
        revision += 1
    }

    func menu(_ name: String) -> MenuFile? {
        menus.first { $0.name == name } ?? menus.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func record(_ name: String) -> Record? {
        guard let m = menu(name), !m.hasProblem else { return nil }
        return m.record
    }

    func show(_ route: Route, in tab: AppTab? = nil) {
        let target = tab ?? self.tab
        switch target {
        case .day: dayPath.append(route)
        case .library: libraryPath.append(route)
        case .ai: aiPath.append(route)
        case .settings: settingsPath.append(route)
        }
        if tab != nil { self.tab = target }
    }

    func openChat(attachments: [String], text: String) {
        pendingChat = PendingChat(attachments: attachments, text: text)
        tab = .ai
    }

    func template() -> DailyDocument? {
        guard let text = vault.readIfExists(Vault.templatePath) else { return nil }
        return DailyDocument(text: text, kind: .template)
    }

    func loadDaily(_ date: String) -> (doc: DailyDocument?, unreadable: Bool) {
        let path = Vault.dailyPath(date)
        guard vault.exists(path) else { return (nil, false) }
        guard let text = try? vault.read(path) else { return (nil, true) }
        return (DailyDocument(text: text), false)
    }

    func newDaily(_ date: String) -> DailyDocument {
        if date == today() {
            return DailyCopy.newDaily(date: date, template: template(), record: record)
        }
        return DailyDocument.new(date: date)
    }

    func ensureTodayCopied() {
        let date = today()
        guard !vault.exists(Vault.dailyPath(date)), let template = template(), template.fileProblem == nil else { return }
        let blocks = DailyCopy.blocks(from: template, record: record)
        guard !blocks.isEmpty else { return }
        var doc = DailyDocument.new(date: date)
        DailyCopy.append(blocks, to: &doc)
        try? vault.write(Vault.dailyPath(date), doc.text)
        revision += 1
    }

    func writeDaily(_ date: String, _ doc: DailyDocument) throws {
        try vault.write(Vault.dailyPath(date), doc.text)
        revision += 1
    }

    func menuNamesInVault() -> Set<String> {
        Set(menus.map { $0.name.lowercased() })
    }

    func createMenu(_ draft: MenuDraft, initial: Value? = nil) throws {
        try vault.validateNewName(draft.name)
        var text = draft.text(updating: nil)
        if let initial, !initial.isEmpty {
            var file = MarkdownFile.parse(text)
            file.frontmatter?.set("initial", .scalar(initial.text))
            text = file.text
        }
        try vault.write(Vault.menuPath(draft.name), text)
        vaultChanged()
    }

    func updateMenu(_ original: MenuFile, _ draft: MenuDraft) throws {
        if draft.name != original.name {
            try vault.renameMenu(from: original.name, to: draft.name)
        }
        let path = Vault.menuPath(draft.name)
        let current = (try? vault.read(path)).map { MarkdownFile.parse($0) } ?? original.file
        try vault.write(path, draft.text(updating: current))
        vaultChanged()
    }

    func renameMenu(_ from: String, to: String) throws {
        try vault.renameMenu(from: from, to: to)
        vaultChanged()
    }

    func deleteMenu(_ name: String) throws {
        try vault.delete(Vault.menuPath(name))
        vaultChanged()
    }

    func copyFromPack(_ pack: Pack, names: [String], replacing: Bool = false) throws {
        try PackInstaller.copy(menus: names, from: pack, to: vault, replacing: replacing)
        vaultChanged()
    }

    func createMenuFromApple(_ type: String, name: String) throws {
        if let apple = packs.packs.first(where: { $0.id == "bundled:\(packs.deviceLanguage)/\(PackStore.appleName)" }),
           apple.menuNames().contains(name) {
            try copyFromPack(apple, names: [name])
            return
        }
        let entry = packs.catalog[type]
        try createMenu(MenuDraft(name: name, record: entry?.record ?? .check, fields: entry?.fields ?? [], appleHealth: entry == nil ? nil : type))
    }

    func placement() -> HealthPlacement {
        let catalog = packs.catalog
        let vault = self.vault
        let index = self.index
        return HealthPlacement(menus: menus, catalog: { catalog[$0] }, recentMenu: { index.recentMenu(vault, candidates: $0) })
    }

    func problems() -> [VaultProblem] {
        index.problems(vault, menus: menus)
    }

    func thumbnailURL(_ menu: MenuFile) -> URL? {
        guard let ref = menu.thumbnailReference else { return nil }
        return resolveImage(ref, from: "menus")
    }

    func resolveImage(_ ref: String, from dir: String) -> URL? {
        let files = vault.list(Vault.media) + vault.list(dir, recursive: false)
        let direct = ImageResolver.resolve(ref, fromDirectory: dir, files: files)
        let path = direct ?? ImageResolver.resolve(ref, fromDirectory: dir, files: vault.list())
        guard let path else { return nil }
        return try? vault.url(path)
    }

    func foreground() {
        let today = today()
        let changedDay = settings.prefs.lastActiveDay != nil && settings.prefs.lastActiveDay != today
        settings.prefs.lastActiveDay = today
        vaultChanged()
        if changedDay {
            NotificationCenter.default.post(name: .dayChanged, object: nil)
        }
        ensureTodayCopied()
        Task {
            await health.importAutomatically()
            await sync.run(trigger: .foreground)
        }
    }
}

extension Notification.Name {
    static let dayChanged = Notification.Name("selfcare.dayChanged")
}
