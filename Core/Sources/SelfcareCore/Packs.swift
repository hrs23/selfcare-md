import Foundation

public enum PackError: Error, LocalizedError, Equatable {
    case noMenus
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .noMenus: "No menus folder with Menus"
        case let .invalid(m): m
        }
    }
}

public struct Pack: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var root: URL
    public var isBundled: Bool
    public var language: String?

    public init(id: String, name: String, root: URL, isBundled: Bool, language: String?) {
        self.id = id
        self.name = name
        self.root = root
        self.isBundled = isBundled
        self.language = language
    }

    public var readme: String? {
        try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    }

    public func menuNames() -> [String] {
        let dir = root.appendingPathComponent("menus")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(3)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func menuText(_ name: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent("menus/\(name).md"), encoding: .utf8)
    }

    public func menus(appleHealthTypes: Set<String>) -> [MenuFile] {
        menuNames().compactMap { name in
            menuText(name).map { MenuFile(name: name, text: $0, appleHealthTypes: appleHealthTypes) }
        }
    }

    public func files() -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = root.resolvingSymlinksInPath().path
        var result: [String] = []
        for case let u as URL in e {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let p = u.resolvingSymlinksInPath().path
            if p.hasPrefix(base + "/") { result.append(String(p.dropFirst(base.count + 1))) }
        }
        return result
    }
}

public enum ImageResolver {
    public static func resolve(_ reference: String, fromDirectory dir: String, files: [String]) -> String? {
        var ref = reference
        if ref.hasPrefix("<"), ref.hasSuffix(">") { ref = String(ref.dropFirst().dropLast()) }
        ref = ref.removingPercentEncoding ?? ref
        if ref.contains("://") { return nil }
        let fileSet = Set(files)
        var candidates: [String] = []
        if !ref.hasPrefix("/") {
            candidates.append(normalize(dir.isEmpty ? ref : dir + "/" + ref))
        }
        candidates.append(normalize(ref))
        for c in candidates where !c.isEmpty && fileSet.contains(c) { return c }
        let lastComponent = (ref as NSString).lastPathComponent
        if !ref.contains("/") {
            return files.first { ($0 as NSString).lastPathComponent == lastComponent }
        }
        return nil
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if parts.isEmpty { return "" }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}

public enum PackInstaller {
    public static func copy(menus names: [String], from pack: Pack, to vault: Vault, replacing: Bool = false) throws {
        let packFiles = pack.files()
        for name in names {
            guard let text = pack.menuText(name) else { continue }
            let existing = vault.menuFileName(for: name)
            if existing != nil && !replacing { continue }
            let target = Vault.menuPath(existing ?? name)
            try vault.writeRaw(target, VaultText.normalized(text))
            let menu = MenuFile(name: name, text: text, appleHealthTypes: [])
            for ref in menu.imageReferences {
                guard let source = ImageResolver.resolve(ref, fromDirectory: "menus", files: packFiles) else { continue }
                if vault.exists(source) && !replacing { continue }
                let data = try Data(contentsOf: pack.root.appendingPathComponent(source))
                try vault.writeData(source, data)
            }
        }
    }

    public static func importZip(_ data: Data, suggestedName: String, into directory: URL) throws -> URL {
        let entries = try Zip.read(data)
        var files: [(String, Data)] = []
        for e in entries where !e.isDirectory {
            let path = try Zip.safePath(e.path)
            if path.hasPrefix("__MACOSX/") || (path as NSString).lastPathComponent.hasPrefix(".") { continue }
            files.append((path, e.data))
        }
        let (prefix, name) = try packRoot(files.map(\.0), suggestedName: suggestedName)
        let dest = try prepare(directory, name: name)
        do {
            for (path, content) in files where prefix.isEmpty || path.hasPrefix(prefix + "/") {
                let rel = prefix.isEmpty ? path : String(path.dropFirst(prefix.count + 1))
                let target = dest.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
            throw error
        }
        return dest
    }

    public static func importFolder(_ folder: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw PackError.noMenus }
        var files: [String] = []
        for case let u as URL in e {
            let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true { continue }
            let resolved = u.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base + "/") else { throw ZipError.unsafePath(u.lastPathComponent) }
            files.append(String(resolved.dropFirst(base.count + 1)))
        }
        let (prefix, name) = try packRoot(files, suggestedName: folder.lastPathComponent)
        let dest = try prepare(directory, name: name)
        do {
            for path in files where prefix.isEmpty || path.hasPrefix(prefix + "/") {
                let rel = prefix.isEmpty ? path : String(path.dropFirst(prefix.count + 1))
                let target = dest.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: folder.appendingPathComponent(path), to: target)
            }
        } catch {
            try? fm.removeItem(at: dest.deletingLastPathComponent())
            throw error
        }
        return dest
    }

    static func packRoot(_ paths: [String], suggestedName: String) throws -> (prefix: String, name: String) {
        let menuFiles = paths.filter { $0.hasSuffix(".md") }
        if menuFiles.contains(where: { $0.hasPrefix("menus/") && $0.split(separator: "/").count == 2 }) {
            return ("", cleanName(suggestedName))
        }
        let roots = Set(menuFiles.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[1] == "menus" else { return nil }
            return String(parts[0])
        })
        guard roots.count == 1, let root = roots.first else {
            throw PackError.noMenus
        }
        return (root, root)
    }

    static func cleanName(_ name: String) -> String {
        var n = name
        if n.lowercased().hasSuffix(".zip") { n = String(n.dropLast(4)) }
        n = n.replacingOccurrences(of: "/", with: "-")
        return n.isEmpty ? "Pack" : n
    }

    static func prepare(_ directory: URL, name: String) throws -> URL {
        let container = directory.appendingPathComponent(UUID().uuidString)
        let dest = container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    public static func export(name: String, menus: [String], vault: Vault) throws -> Data {
        let packName = cleanName(name)
        var entries: [ZipEntry] = []
        var added = Set<String>()
        let files = vault.list()
        for menu in menus {
            let path = Vault.menuPath(menu)
            let data = try vault.readData(path)
            entries.append(ZipEntry(path: "\(packName)/\(path)", data: data))
            let text = String(decoding: data, as: UTF8.self)
            let file = MenuFile(name: menu, text: text, appleHealthTypes: [])
            for ref in file.imageReferences {
                guard let source = ImageResolver.resolve(ref, fromDirectory: "menus", files: files), !added.contains(source) else { continue }
                added.insert(source)
                entries.append(ZipEntry(path: "\(packName)/\(source)", data: try vault.readData(source)))
            }
        }
        return Zip.write(entries)
    }
}
