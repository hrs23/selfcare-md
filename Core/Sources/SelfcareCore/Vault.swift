import Foundation

public enum VaultError: Error, LocalizedError, Equatable {
    case outsideVault(String)
    case notUTF8(String)
    case notFound(String)
    case invalidName(String)
    case duplicate(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .outsideVault(p): "Path is outside the vault: \(p)"
        case let .notUTF8(p): "Not UTF-8: \(p)"
        case let .notFound(p): "Not found: \(p)"
        case let .invalidName(m): m
        case let .duplicate(n): "A Menu named \(n) already exists"
        case let .failed(m): m
        }
    }
}

public struct VaultFileInfo: Sendable, Hashable {
    public var path: String
    public var created: Date?
    public var modified: Date?
    public var size: Int
    public var isDirectory: Bool
}

public final class Vault: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public static let menus = "menus"
    public static let daily = "daily"
    public static let templates = "templates"
    public static let workouts = "workouts"
    public static let media = "media"
    public static let templatePath = "templates/Daily.md"

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func ensureStructure() {
        for dir in [Self.menus, Self.daily, Self.templates, Self.workouts, Self.media] {
            try? fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    public static func dailyPath(_ date: String) -> String { "daily/\(date).md" }
    public static func menuPath(_ name: String) -> String { "menus/\(name).md" }

    public func url(_ relative: String) throws -> URL {
        let clean = try Self.clean(relative)
        let url = clean.isEmpty ? root : root.appendingPathComponent(clean)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var probe = url
        while !fm.fileExists(atPath: probe.path), probe.path.count > root.path.count {
            probe = probe.deletingLastPathComponent()
        }
        let resolved = probe.resolvingSymlinksInPath().path
        guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            throw VaultError.outsideVault(relative)
        }
        return url
    }

    public static func clean(_ relative: String) throws -> String {
        var path = relative.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("./") { path.removeFirst(2) }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw VaultError.outsideVault(relative) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        for part in parts where part == ".." || part == "." {
            throw VaultError.outsideVault(relative)
        }
        return parts.joined(separator: "/")
    }

    public func exists(_ relative: String) -> Bool {
        guard let u = try? url(relative) else { return false }
        return fm.fileExists(atPath: u.path)
    }

    public func isDirectory(_ relative: String) -> Bool {
        guard let u = try? url(relative) else { return false }
        var dir: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    public func readData(_ relative: String) throws -> Data {
        let u = try url(relative)
        guard fm.fileExists(atPath: u.path) else { throw VaultError.notFound(relative) }
        return try Data(contentsOf: u)
    }

    public func read(_ relative: String) throws -> String {
        let data = try readData(relative)
        guard let s = String(data: data, encoding: .utf8) else { throw VaultError.notUTF8(relative) }
        return s
    }

    public func readIfExists(_ relative: String) -> String? {
        try? read(relative)
    }

    public func write(_ relative: String, _ text: String) throws {
        try writeData(relative, Data(VaultText.normalized(text).utf8))
    }

    public func writeRaw(_ relative: String, _ text: String) throws {
        try writeData(relative, Data(text.utf8))
    }

    public func writeData(_ relative: String, _ data: Data) throws {
        let u = try url(relative)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    public func delete(_ relative: String) throws {
        let u = try url(relative)
        guard fm.fileExists(atPath: u.path) else { throw VaultError.notFound(relative) }
        try fm.removeItem(at: u)
    }

    public func move(_ from: String, _ to: String) throws {
        let a = try url(from)
        let b = try url(to)
        guard fm.fileExists(atPath: a.path) else { throw VaultError.notFound(from) }
        try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        if a.path.lowercased() == b.path.lowercased() && a.path != b.path {
            let tmp = a.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: a, to: tmp)
            try fm.moveItem(at: tmp, to: b)
        } else {
            guard !fm.fileExists(atPath: b.path) else { throw VaultError.failed("\(to) already exists") }
            try fm.moveItem(at: a, to: b)
        }
    }

    public func info(_ relative: String) -> VaultFileInfo? {
        guard let u = try? url(relative), let attrs = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        return VaultFileInfo(
            path: relative,
            created: attrs[.creationDate] as? Date,
            modified: attrs[.modificationDate] as? Date,
            size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
            isDirectory: (attrs[.type] as? FileAttributeType) == .typeDirectory
        )
    }

    public func modified(_ relative: String) -> Date? {
        info(relative)?.modified
    }

    public func list(_ relative: String = "", recursive: Bool = true, includeDirectories: Bool = false) -> [String] {
        guard let base = try? url(relative) else { return [] }
        var result: [String] = []
        let prefix = root.resolvingSymlinksInPath().path
        func rel(_ u: URL) -> String {
            let p = u.resolvingSymlinksInPath().path
            return p.hasPrefix(prefix + "/") ? String(p.dropFirst(prefix.count + 1)) : u.lastPathComponent
        }
        if recursive {
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
            for case let u as URL in e {
                let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if includeDirectories { result.append(rel(u)) }
                    continue
                }
                result.append(rel(u))
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir && !includeDirectories { continue }
                result.append(relative.isEmpty ? u.lastPathComponent : relative + "/" + u.lastPathComponent)
            }
        }
        return result.sorted()
    }

    public func menuNames() -> [String] {
        list(Self.menus, recursive: false)
            .filter { $0.hasSuffix(".md") }
            .map { String(($0 as NSString).lastPathComponent.dropLast(3)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func dailyDates() -> [String] {
        list(Self.daily, recursive: false)
            .map { ($0 as NSString).lastPathComponent }
            .filter { $0.hasSuffix(".md") && DayDate.isValid(String($0.dropLast(3))) }
            .map { String($0.dropLast(3)) }
            .sorted()
    }

    public func menuFileName(for name: String) -> String? {
        let names = menuNames()
        if names.contains(name) { return name }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func validateNewName(_ name: String, excluding: String? = nil) throws {
        if let m = MenuName.validate(name) { throw VaultError.invalidName(m) }
        for existing in menuNames() where existing.caseInsensitiveCompare(name) == .orderedSame {
            if let excluding, existing.caseInsensitiveCompare(excluding) == .orderedSame { continue }
            throw VaultError.duplicate(existing)
        }
    }

    public func renameMenu(from old: String, to new: String) throws {
        try validateNewName(new, excluding: old)
        if old == new { return }
        let from = Self.menuPath(old)
        let to = Self.menuPath(new)
        var originals: [String: String] = [:]
        for path in list().filter({ $0.hasSuffix(".md") }) {
            guard let text = try? read(path) else { continue }
            if WikiLinks.rename(in: text, from: old, to: new) != text {
                originals[path] = text
            }
        }
        var moved = false
        var written: [String: String] = [:]
        do {
            try move(from, to)
            moved = true
            for (path, text) in originals {
                let target = path == from ? to : path
                try writeRaw(target, WikiLinks.rename(in: text, from: old, to: new))
                written[target] = text
            }
        } catch {
            for (target, text) in written {
                try? writeRaw(target, text)
            }
            if moved {
                try? move(to, from)
            }
            throw error
        }
    }
}

public enum WikiLinks {
    static let regex = try! NSRegularExpression(pattern: #"\[\[([^\]\|#\^]+)((?:[#|^][^\]]*)?)\]\]"#)

    public static func rename(in text: String, from old: String, to new: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            guard name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(old) == .orderedSame else { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range(at: 1).location - last))
            result += new
            last = m.range(at: 1).location + m.range(at: 1).length
        }
        result += ns.substring(from: last)
        return result
    }

    public static func names(in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }
}

public enum DayDate {
    public static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func isValid(_ string: String) -> Bool {
        guard string.count == 10, let d = date(string) else { return false }
        return self.string(d) == string
    }

    public static func adding(_ days: Int, to string: String, calendar: Calendar = .current) -> String {
        guard let d = date(string, calendar: calendar), let n = calendar.date(byAdding: .day, value: days, to: d) else { return string }
        return self.string(n, calendar: calendar)
    }
}
