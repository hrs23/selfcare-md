import Foundation
import Observation
import SelfcareCore

@Observable
final class PackStore {
    private(set) var packs: [Pack] = []
    private(set) var catalog: [String: CatalogEntry] = [:]
    private(set) var catalogOrder: [String] = []
    private var menuCache: [String: [MenuFile]] = [:]
    let settings: Settings

    static let appleName = "Apple Health"

    init(settings: Settings) {
        self.settings = settings
        reload()
    }

    var deviceLanguage: String { BuildInfo.prefersJapanese ? "ja" : "en" }

    func reload() {
        var result: [Pack] = []
        if let base = Bundle.main.resourceURL?.appendingPathComponent("Packs") {
            var languages = ["en", "ja"]
            if BuildInfo.showsDebugTools { languages.append("debug") }
            for lang in languages {
                let dir = base.appendingPathComponent(lang)
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                for name in names {
                    result.append(Pack(id: "bundled:\(lang)/\(name)", name: name, root: dir.appendingPathComponent(name), isBundled: true, language: lang == "debug" ? "en" : lang))
                }
            }
        }
        let importedRoot = AppFiles.importedPacks
        for container in ((try? FileManager.default.contentsOfDirectory(atPath: importedRoot.path)) ?? []).sorted() where !container.hasPrefix(".") {
            let dir = importedRoot.appendingPathComponent(container)
            guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { !$0.hasPrefix(".") }) else { continue }
            result.append(Pack(id: "imported:\(container)", name: name, root: dir.appendingPathComponent(name), isBundled: false, language: nil))
        }
        packs = result
        menuCache = [:]
        buildCatalog()
    }

    var applePack: Pack? {
        packs.first { $0.id == "bundled:\(deviceLanguage)/\(Self.appleName)" }
    }

    private func buildCatalog() {
        catalog = [:]
        catalogOrder = []
        guard let apple = applePack else { return }
        for m in apple.menus(appleHealthTypes: []) {
            guard let type = m.appleHealth else { continue }
            catalog[type] = CatalogEntry(type: type, name: m.name, record: m.record, fields: m.fields)
        }
        let order = Self.specOrder
        catalogOrder = catalog.keys.sorted { a, b in
            (order.firstIndex(of: a) ?? Int.max, catalog[a]!.name) < (order.firstIndex(of: b) ?? Int.max, catalog[b]!.name)
        }
    }

    var appleTypes: Set<String> { Set(catalog.keys) }

    func appleName(_ type: String) -> String {
        catalog[type]?.name ?? type
    }

    func isEnabled(_ pack: Pack) -> Bool {
        if let list = settings.prefs.enabledPacks { return list.contains(pack.id) }
        return pack.isBundled && pack.language == deviceLanguage && !pack.id.hasPrefix("bundled:debug/")
    }

    func setEnabled(_ pack: Pack, _ enabled: Bool) {
        var list = settings.prefs.enabledPacks ?? packs.filter(isEnabled).map(\.id)
        list.removeAll { $0 == pack.id }
        if enabled { list.append(pack.id) }
        settings.prefs.enabledPacks = list
    }

    func menus(_ pack: Pack) -> [MenuFile] {
        if let cached = menuCache[pack.id] { return cached }
        let menus = pack.menus(appleHealthTypes: appleTypes)
        menuCache[pack.id] = menus
        return menus
    }

    func importZip(_ data: Data, name: String) throws {
        try added(PackInstaller.importZip(data, suggestedName: name, into: AppFiles.importedPacks))
    }

    func importFolder(_ url: URL) throws {
        try added(PackInstaller.importFolder(url, into: AppFiles.importedPacks))
    }

    private func added(_ root: URL) throws {
        try validate(root)
        reload()
        if let pack = packs.first(where: { $0.root.standardizedFileURL == root.standardizedFileURL }) { setEnabled(pack, true) }
    }

    private func validate(_ root: URL) throws {
        let pack = Pack(id: "tmp", name: root.lastPathComponent, root: root, isBundled: false, language: nil)
        let names = pack.menuNames()
        if names.isEmpty || names.contains(where: { MenuName.validate($0) != nil }) {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            throw PackError.invalid("The pack has no valid Menus")
        }
    }

    func delete(_ pack: Pack) {
        try? FileManager.default.removeItem(at: pack.root.deletingLastPathComponent())
        settings.prefs.enabledPacks?.removeAll { $0 == pack.id }
        reload()
    }

    static let specOrder: [String] = HealthTypes.workoutTypes.map { "HKWorkoutActivityType" + $0.0 } + HealthTypes.others.map(\.constant)
}
