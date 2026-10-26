import Foundation

public enum YAMLValue: Hashable, Sendable {
    case null
    case scalar(String)
    case list([String])
    case invalid

    public var scalar: String? {
        if case let .scalar(s) = self { return s }
        return nil
    }

    public var list: [String]? {
        if case let .list(l) = self { return l }
        return nil
    }
}

public struct Frontmatter: Sendable, Hashable {
    public enum Entry: Sendable, Hashable {
        case pair(key: String, lines: [String])
        case other(String)
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var keys: [String] {
        entries.compactMap {
            if case let .pair(key, _) = $0 { return key }
            return nil
        }
    }

    public subscript(key: String) -> YAMLValue? {
        for entry in entries {
            if case let .pair(k, lines) = entry, k == key {
                return Self.interpret(lines)
            }
        }
        return nil
    }

    public mutating func set(_ key: String, _ value: YAMLValue?) {
        guard let value, value != .null else {
            entries.removeAll {
                if case let .pair(k, _) = $0 { return k == key }
                return false
            }
            return
        }
        let lines = Self.render(key: key, value: value)
        if let index = entries.firstIndex(where: {
            if case let .pair(k, _) = $0 { return k == key }
            return false
        }) {
            entries[index] = .pair(key: key, lines: lines)
        } else {
            entries.append(.pair(key: key, lines: lines))
        }
    }

    public var text: String {
        entries.flatMap { entry -> [String] in
            switch entry {
            case let .pair(_, lines): lines
            case let .other(line): [line]
            }
        }.joined(separator: "\n")
    }

    public static func parse(_ lines: [String]) -> Frontmatter {
        var entries: [Entry] = []
        for line in lines {
            if let key = keyOf(line) {
                entries.append(.pair(key: key, lines: [line]))
            } else if case let .pair(key, existing)? = entries.last,
                      line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("-") {
                entries[entries.count - 1] = .pair(key: key, lines: existing + [line])
            } else {
                entries.append(.other(line))
            }
        }
        return Frontmatter(entries: entries)
    }

    static func keyOf(_ line: String) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "-", first != "#" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return key
    }

    static func interpret(_ lines: [String]) -> YAMLValue {
        guard let first = lines.first, let colon = first.firstIndex(of: ":") else { return .invalid }
        let inline = stripComment(String(first[first.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if inline.isEmpty {
            if rest.isEmpty { return .null }
            var items: [String] = []
            for line in rest {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") || trimmed == "-" else { return .invalid }
                let item = unquote(stripComment(String(trimmed.dropFirst(1))).trimmingCharacters(in: .whitespaces))
                if item.hasPrefix("[") || item.hasPrefix("{") || keyOf(item) != nil && item.contains(": ") { return .invalid }
                items.append(item)
            }
            return .list(items)
        }
        guard rest.isEmpty else { return .invalid }
        if inline.hasPrefix("[") {
            guard inline.hasSuffix("]") else { return .invalid }
            let inner = inline.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .list([]) }
            if inner.contains("[") || inner.contains("{") { return .invalid }
            return .list(splitFlow(inner).map { unquote($0.trimmingCharacters(in: .whitespaces)) })
        }
        if inline.hasPrefix("{") { return .invalid }
        if inline == "~" || inline == "null" { return .null }
        return .scalar(unquote(inline))
    }

    static func stripComment(_ s: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character = " "
        for (offset, c) in s.enumerated() {
            if c == "'" && !inDouble { inSingle.toggle() }
            if c == "\"" && !inSingle { inDouble.toggle() }
            if c == "#" && !inSingle && !inDouble && previous.isWhitespace {
                return String(s.prefix(offset))
            }
            previous = c
        }
        return s
    }

    static func splitFlow(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for c in s {
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                items.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        items.append(current)
        return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    static func quoteIfNeeded(_ s: String, inFlow: Bool) -> String {
        let specials: Set<Character> = ["[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", ",", "?", ":"]
        var needs = s.isEmpty || s.hasPrefix(" ") || s.hasSuffix(" ")
        if let first = s.first, specials.contains(first) { needs = true }
        if s.hasPrefix("- ") || s == "-" { needs = true }
        if s.contains(": ") || s.contains(" #") { needs = true }
        if inFlow && (s.contains(",") || s.contains("[") || s.contains("]")) { needs = true }
        if ["true", "false", "null", "~", "yes", "no"].contains(s.lowercased()) { needs = true }
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func render(key: String, value: YAMLValue) -> [String] {
        switch value {
        case .null, .invalid:
            return ["\(key):"]
        case let .scalar(s):
            return ["\(key): \(quoteIfNeeded(s, inFlow: false))"]
        case let .list(items):
            return ["\(key): [\(items.map { quoteIfNeeded($0, inFlow: true) }.joined(separator: ", "))]"]
        }
    }
}

public struct MarkdownFile: Sendable, Hashable {
    public var frontmatter: Frontmatter?
    public var frontmatterBroken: Bool
    public var body: String

    public init(frontmatter: Frontmatter?, body: String, frontmatterBroken: Bool = false) {
        self.frontmatter = frontmatter
        self.body = body
        self.frontmatterBroken = frontmatterBroken
    }

    public static func parse(_ text: String) -> MarkdownFile {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return MarkdownFile(frontmatter: nil, body: normalized)
        }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return MarkdownFile(frontmatter: nil, body: normalized, frontmatterBroken: true)
        }
        let fm = Frontmatter.parse(Array(lines[..<end]))
        let body = lines[(end + 1)...].joined(separator: "\n")
        return MarkdownFile(frontmatter: fm, body: body)
    }

    public var text: String {
        guard let frontmatter, !frontmatter.entries.isEmpty else {
            return VaultText.normalized(body)
        }
        return VaultText.normalized("---\n" + frontmatter.text + "\n---\n" + body)
    }
}

public enum VaultText {
    public static func normalized(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        while t.hasSuffix("\n") { t.removeLast() }
        return t + "\n"
    }
}
