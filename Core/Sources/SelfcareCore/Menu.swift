import Foundation

public enum Record: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case check, avoid, sets
    public var id: String { rawValue }
}

public struct MenuFile: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var file: MarkdownFile
    public var record: Record
    public var fields: [Field]
    public var tags: [String]
    public var appleHealth: String?
    public var thumbnail: String?
    public var initial: Value?
    public var problems: [String]

    public var hasProblem: Bool { !problems.isEmpty }
    public var body: String { file.body }
    public var usesFields: Bool { record != .avoid }

    public init(name: String, text: String, appleHealthTypes: Set<String>) {
        self.name = name
        let file = MarkdownFile.parse(text)
        self.file = file
        var problems: [String] = []
        var record = Record.check
        var fields: [Field] = []
        var tags: [String] = []
        var appleHealth: String?
        var thumbnail: String?
        var initial: Value?

        if file.frontmatterBroken {
            problems.append("Frontmatter is not closed")
        }
        if let fm = file.frontmatter {
            switch fm["record"] {
            case nil, .null?:
                break
            case let .scalar(s)?:
                if let r = Record(rawValue: s) {
                    record = r
                } else {
                    problems.append("Unknown record: \(s)")
                }
            default:
                problems.append("record must be check, avoid or sets")
            }
            switch fm["fields"] {
            case nil, .null?:
                break
            case let .list(items)?:
                var parsed: [Field] = []
                for item in items {
                    if let f = Field(rawValue: item) {
                        parsed.append(f)
                    } else {
                        problems.append("Unknown field: \(item)")
                    }
                }
                fields = Field.sorted(parsed)
            case let .scalar(s)?:
                if let f = Field(rawValue: s) {
                    fields = [f]
                } else {
                    problems.append("Unknown field: \(s)")
                }
            default:
                problems.append("fields must be a list")
            }
            switch fm["tags"] {
            case let .list(items)?: tags = items.filter { !$0.isEmpty }
            case let .scalar(s)?: tags = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
            switch fm["apple-health"] {
            case nil, .null?:
                break
            case let .scalar(s)?:
                appleHealth = s
            default:
                appleHealth = ""
            }
            thumbnail = fm["thumbnail"]?.scalar.flatMap { $0.isEmpty ? nil : $0 }
            if let s = fm["initial"]?.scalar {
                initial = ValueParser.value(s)
            } else if let l = fm["initial"]?.list, l.count == 1 {
                initial = ValueParser.value(l[0])
            }
        }
        if record == .avoid {
            fields = []
            appleHealth = nil
        } else if let ah = appleHealth, !appleHealthTypes.contains(ah) {
            problems.append("Unknown apple-health: \(ah)")
        }
        if record == .sets && fields.isEmpty && !problems.contains(where: { $0.hasPrefix("Unknown field") }) {
            problems.append("sets needs fields")
        }
        if fields.isEmpty || initial?.isEmpty == true {
            initial = nil
        }
        self.record = record
        self.fields = fields
        self.tags = tags
        self.appleHealth = appleHealth
        self.thumbnail = thumbnail
        self.initial = initial
        self.problems = problems
    }

    public var text: String { file.text }

    public var imageReferences: [String] {
        var refs: [String] = []
        if let thumbnail { refs.append(thumbnail) }
        refs.append(contentsOf: MarkdownImages.references(in: file.body))
        return refs
    }

    public var thumbnailReference: String? {
        thumbnail ?? MarkdownImages.references(in: file.body).first
    }
}

public struct MenuDraft: Sendable, Hashable {
    public var name: String
    public var record: Record
    public var fields: [Field]
    public var tags: [String]
    public var appleHealth: String?
    public var thumbnail: String?
    public var body: String

    public init(name: String = "", record: Record = .check, fields: [Field] = [], tags: [String] = [], appleHealth: String? = nil, thumbnail: String? = nil, body: String = "") {
        self.name = name
        self.record = record
        self.fields = fields
        self.tags = tags
        self.appleHealth = appleHealth
        self.thumbnail = thumbnail
        self.body = body
    }

    public init(menu: MenuFile) {
        self.init(name: menu.name, record: menu.record, fields: menu.fields, tags: menu.tags, appleHealth: menu.appleHealth, thumbnail: menu.thumbnail, body: menu.body)
    }

    public var isValid: Bool {
        MenuName.validate(name) == nil && !(record == .sets && fields.isEmpty)
    }

    public func text(updating original: MarkdownFile?) -> String {
        var file = original ?? MarkdownFile(frontmatter: Frontmatter(), body: "")
        var fm = file.frontmatter ?? Frontmatter()
        fm.set("record", .scalar(record.rawValue))
        if record == .avoid {
            fm.set("fields", nil)
            fm.set("apple-health", nil)
        } else {
            fm.set("fields", fields.isEmpty ? nil : .list(Field.sorted(fields).map(\.rawValue)))
            fm.set("apple-health", appleHealth.map { .scalar($0) })
        }
        fm.set("tags", tags.isEmpty ? nil : .list(tags))
        fm.set("thumbnail", thumbnail.map { .scalar($0) })
        file.frontmatter = fm
        file.frontmatterBroken = false
        if original == nil {
            file.body = body.isEmpty ? "" : "\n" + body
        } else {
            file.body = body
        }
        return file.text
    }
}

public enum MenuName {
    public static let forbidden = ["/", "\\", "[[", "]]", "|", "#", "^"]

    public static func validate(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name is empty" }
        if trimmed != name { return "Name has leading or trailing spaces" }
        for f in forbidden where name.contains(f) {
            return "Name cannot contain \(f)"
        }
        if name.hasPrefix(".") { return "Name cannot start with ." }
        if name.contains("\n") { return "Name cannot contain line breaks" }
        return nil
    }
}

public enum MarkdownImages {
    public static func references(in body: String) -> [String] {
        var refs: [String] = []
        let ns = body as NSString
        let patterns = [#"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#, #"!\[\[([^\]|#]+)(?:\|[^\]]*)?\]\]"#]
        var found: [(Int, String)] = []
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                var path = ns.substring(with: m.range(at: 1))
                if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
                path = path.removingPercentEncoding ?? path
                found.append((m.range.location, path))
            }
        }
        for (_, path) in found.sorted(by: { $0.0 < $1.0 }) where !path.contains("://") {
            refs.append(path)
        }
        return refs
    }
}
