import Foundation

public enum HealthMarker: Hashable, Sendable {
    case record(String)
    case aggregate(String)

    public init?(comment: String) {
        let inner = comment.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("apple-health:") else { return nil }
        let id = inner.dropFirst("apple-health:".count).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        if UUID(uuidString: id) != nil {
            self = .record(id.uppercased())
        } else {
            self = .aggregate(id)
        }
    }

    public var comment: String {
        switch self {
        case let .record(id): "<!-- apple-health:\(id) -->"
        case let .aggregate(c): "<!-- apple-health:\(c) -->"
        }
    }

    public var uuid: String? {
        if case let .record(id) = self { return id }
        return nil
    }
}

public struct LineParts: Hashable, Sendable {
    public var valueText: String
    public var comment: String?
    public var marker: HealthMarker?

    static func split(_ rest: String) -> LineParts {
        var text = rest
        var comment: String?
        var marker: HealthMarker?
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("-->"), let open = trimmed.range(of: "<!--", options: .backwards) {
            let c = String(trimmed[open.lowerBound...])
            comment = c
            let inner = String(c.dropFirst(4).dropLast(3))
            marker = HealthMarker(comment: inner)
            text = String(trimmed[..<open.lowerBound])
        }
        return LineParts(valueText: text.trimmingCharacters(in: .whitespaces), comment: comment, marker: marker)
    }
}

public struct SetLine: Hashable, Sendable, Identifiable {
    public var id: Int { line }
    public var line: Int
    public var raw: String
    public var checked: Bool
    public var valueText: String
    public var value: Value?
    public var comment: String?
    public var marker: HealthMarker?
    public var problem: String?

    public var isImported: Bool { marker != nil }
}

public struct Entry: Hashable, Sendable, Identifiable {
    public var id: Int { line }
    public var line: Int
    public var endLine: Int
    public var raw: String
    public var name: String
    public var link: String
    public var checkbox: Bool?
    public var valueText: String
    public var value: Value?
    public var comment: String?
    public var marker: HealthMarker?
    public var sets: [SetLine]
    public var problem: String?

    public var isImported: Bool { marker != nil || sets.contains { $0.marker != nil } }
    public var isPlan: Bool { checkbox == nil && sets.isEmpty }
    public var hasLineProblem: Bool { problem != nil || sets.contains { $0.problem != nil } }
}

public enum SelfcareItem: Hashable, Sendable, Identifiable {
    case entry(Entry)
    case heading(line: Int, text: String)
    case raw(line: Int, text: String)

    public var id: Int {
        switch self {
        case let .entry(e): e.line
        case let .heading(line, _): line
        case let .raw(line, _): line
        }
    }
}

public enum DocumentKind: Sendable {
    case daily
    case template
}

public struct DailyDocument: Sendable, Hashable {
    public var lines: [String]
    public var kind: DocumentKind
    public private(set) var items: [SelfcareItem] = []
    public private(set) var selfcareHeading: Int?
    public private(set) var selfcareEnd: Int = 0
    public private(set) var memoHeading: Int?
    public private(set) var memoEnd: Int = 0
    public private(set) var fileProblem: String?

    public init(text: String, kind: DocumentKind = .daily) {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") { normalized.removeLast() }
        lines = normalized.isEmpty ? [] : normalized.components(separatedBy: "\n")
        self.kind = kind
        analyze()
    }

    public static func new(date: String) -> DailyDocument {
        DailyDocument(text: "# \(date)\n\n## Selfcare\n\n## Memo\n")
    }

    public static func newTemplate() -> DailyDocument {
        DailyDocument(text: "## Selfcare\n", kind: .template)
    }

    public var text: String {
        VaultText.normalized(lines.joined(separator: "\n"))
    }

    public var entries: [Entry] {
        items.compactMap {
            if case let .entry(e) = $0 { return e }
            return nil
        }
    }

    public func entry(at line: Int) -> Entry? {
        entries.first { $0.line == line }
    }

    public var memo: String {
        guard let memoHeading else { return "" }
        let body = lines[(memoHeading + 1)..<memoEnd]
        return Array(body).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for c in line {
            if c == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return level
    }

    static func headingTitle(_ line: String) -> String {
        line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    mutating func analyze() {
        items = []
        selfcareHeading = nil
        memoHeading = nil
        fileProblem = nil
        var selfcareHeadings: [Int] = []
        var inCode = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("```") { inCode.toggle() }
            if inCode { continue }
            if let level = Self.headingLevel(line), level == 2 {
                let title = Self.headingTitle(line)
                if title == "Selfcare" { selfcareHeadings.append(i) }
                if title == "Memo" && memoHeading == nil { memoHeading = i }
            }
        }
        if selfcareHeadings.count > 1 {
            fileProblem = "More than one ## Selfcare"
            return
        }
        guard let start = selfcareHeadings.first else {
            fileProblem = "No ## Selfcare"
            return
        }
        selfcareHeading = start
        selfcareEnd = sectionEnd(after: start)
        if let memoHeading {
            memoEnd = sectionEnd(after: memoHeading)
        }
        parseSelfcare()
    }

    func sectionEnd(after heading: Int) -> Int {
        var i = heading + 1
        while i < lines.count {
            if let level = Self.headingLevel(lines[i]), level <= 2 { return i }
            i += 1
        }
        return lines.count
    }

    static let topItem = try! NSRegularExpression(pattern: #"^[-*+] (?:\[([ xX])\] )?(.*)$"#)
    static let subItem = try! NSRegularExpression(pattern: #"^(\s+)[-*+] (?:\[([ xX])\] ?)?(.*)$"#)
    static let wikilink = try! NSRegularExpression(pattern: #"^\[\[([^\]\|#\^]+)((?:[#|^][^\]]*)?)\]\]"#)

    static func groups(_ regex: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    mutating func parseSelfcare() {
        guard let start = selfcareHeading else { return }
        var current: Entry?
        var result: [SelfcareItem] = []
        func flush() {
            if var e = current {
                finalize(&e)
                result.append(.entry(e))
            }
            current = nil
        }
        var i = start + 1
        while i < selfcareEnd {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            if let first = line.first, first == " " || first == "\t", current != nil {
                if let g = Self.groups(Self.subItem, line) {
                    let parts = LineParts.split(g[2] ?? "")
                    var set = SetLine(line: i, raw: line, checked: g[1].map { $0 != " " } ?? false, valueText: parts.valueText, value: nil, comment: parts.comment, marker: parts.marker, problem: nil)
                    if g[1] == nil {
                        set.problem = "Value line needs a checkbox"
                    } else {
                        switch ValueParser.parse(parts.valueText) {
                        case let .success(v): set.value = v
                        case .failure: set.problem = "Unreadable value"
                        }
                    }
                    current!.sets.append(set)
                } else {
                    current!.sets.append(SetLine(line: i, raw: line, checked: false, valueText: trimmed, value: nil, comment: nil, marker: nil, problem: "Unreadable line"))
                }
                current!.endLine = i
                i += 1
                continue
            }
            flush()
            if let level = Self.headingLevel(line), level >= 3 {
                result.append(.heading(line: i, text: Self.headingTitle(line)))
            } else if let g = Self.groups(Self.topItem, line), let content = g[1], let link = Self.groups(Self.wikilink, content), let name = link[0] {
                let linkText = "[[\(name)\(link[1] ?? "")]]"
                let rest = String(content.dropFirst(linkText.count))
                let parts = LineParts.split(rest)
                var entry = Entry(line: i, endLine: i, raw: line, name: name.trimmingCharacters(in: .whitespaces), link: linkText, checkbox: g[0].map { $0 != " " }, valueText: parts.valueText, value: nil, comment: parts.comment, marker: parts.marker, sets: [], problem: nil)
                switch ValueParser.parse(parts.valueText) {
                case let .success(v): entry.value = v
                case .failure: entry.problem = "Unreadable value"
                }
                current = entry
            } else {
                result.append(.raw(line: i, text: line))
            }
            i += 1
        }
        flush()
        items = result
    }

    func finalize(_ e: inout Entry) {
        if !e.sets.isEmpty {
            if e.checkbox != nil {
                e.problem = "Menu line has both a checkbox and value lines"
            } else if !e.valueText.isEmpty {
                e.problem = "Menu line has both a value and value lines"
            }
        }
    }

    public var hasLineProblems: Bool {
        items.contains {
            switch $0 {
            case let .entry(e): e.hasLineProblem
            case .raw: true
            case .heading: false
            }
        }
    }

    public var problemLines: Set<Int> {
        var set = Set<Int>()
        for item in items {
            switch item {
            case let .entry(e):
                if e.problem != nil { set.insert(e.line) }
                for s in e.sets where s.problem != nil { set.insert(s.line) }
            case let .raw(line, _):
                set.insert(line)
            case .heading:
                break
            }
        }
        return set
    }
}

public extension DailyDocument {
    static func menuLine(checkbox: Bool?, link: String, value: String, comment: String?) -> String {
        var s = "- "
        if let checkbox { s += checkbox ? "[x] " : "[ ] " }
        s += link
        if !value.isEmpty { s += " " + value }
        if let comment { s += " " + comment }
        return s
    }

    static func setLine(indent: String, checked: Bool, value: String, comment: String?) -> String {
        var s = indent + "- " + (checked ? "[x]" : "[ ]")
        if !value.isEmpty { s += " " + value }
        if let comment { s += " " + comment }
        return s
    }

    static func indent(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private mutating func replace(_ index: Int, _ line: String) {
        lines[index] = line
        analyze()
    }

    mutating func ensureSelfcare() {
        if selfcareHeading != nil || fileProblem == "More than one ## Selfcare" { return }
        if let memoHeading {
            lines.insert(contentsOf: ["## Selfcare", ""], at: memoHeading)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("## Selfcare")
        }
        analyze()
    }

    mutating func setEntryCheck(_ line: Int, _ checked: Bool, value: Value? = nil) {
        guard let e = entry(at: line) else { return }
        let text = value.map(\.text) ?? e.valueText
        replace(line, Self.menuLine(checkbox: checked, link: e.link, value: text, comment: e.comment))
    }

    mutating func setEntryValue(_ line: Int, _ value: Value) {
        guard let e = entry(at: line) else { return }
        replace(line, Self.menuLine(checkbox: e.checkbox, link: e.link, value: value.text, comment: e.comment))
    }

    mutating func setEntryLink(_ line: Int, name: String) {
        guard let e = entry(at: line) else { return }
        replace(line, Self.menuLine(checkbox: e.checkbox, link: "[[\(name)]]", value: e.valueText, comment: e.comment))
    }

    mutating func setSetCheck(_ line: Int, _ checked: Bool) {
        guard let (_, s) = findSet(line) else { return }
        replace(line, Self.setLine(indent: Self.indent(of: s.raw), checked: checked, value: s.valueText, comment: s.comment))
    }

    mutating func setSetValue(_ line: Int, _ value: Value) {
        guard let (_, s) = findSet(line) else { return }
        replace(line, Self.setLine(indent: Self.indent(of: s.raw), checked: s.checked, value: value.text, comment: s.comment))
    }

    func findSet(_ line: Int) -> (Entry, SetLine)? {
        for e in entries {
            if let s = e.sets.first(where: { $0.line == line }) { return (e, s) }
        }
        return nil
    }

    @discardableResult
    mutating func addSet(to entryLine: Int, value: Value, checked: Bool, comment: String? = nil) -> Int? {
        guard let e = entry(at: entryLine) else { return nil }
        let indent = e.sets.last.map { Self.indent(of: $0.raw) } ?? "  "
        let at = e.endLine + 1
        lines.insert(Self.setLine(indent: indent.isEmpty ? "  " : indent, checked: checked, value: value.text, comment: comment), at: at)
        analyze()
        return at
    }

    mutating func deleteSet(_ line: Int) {
        guard findSet(line) != nil else { return }
        lines.remove(at: line)
        analyze()
    }

    mutating func deleteEntry(_ line: Int) {
        guard let e = entry(at: line) else { return }
        lines.removeSubrange(e.line...e.endLine)
        collapseBlanks(around: e.line)
        analyze()
    }

    private mutating func collapseBlanks(around index: Int) {
        var i = min(index, lines.count)
        while i > 0, i < lines.count, lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: i)
            i = min(i, lines.count)
        }
    }

    var usesLooseList: Bool {
        let es = entries
        if es.count >= 2 {
            let next = es[0].endLine + 1
            return next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty
        }
        return kind == .daily
    }

    @discardableResult
    mutating func appendBlock(_ block: [String]) -> Int? {
        ensureSelfcare()
        guard let heading = selfcareHeading, !block.isEmpty else { return nil }
        let loose = usesLooseList
        var last = heading
        var i = heading + 1
        while i < selfcareEnd {
            if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { last = i }
            i += 1
        }
        var insert: [String] = []
        if last == heading || loose { insert.append("") }
        let firstLine = last + 1 + insert.count
        insert.append(contentsOf: block)
        lines.insert(contentsOf: insert, at: last + 1)
        let after = last + 1 + insert.count
        if after < lines.count {
            if !lines[after].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: after)
            } else {
                collapseBlanks(around: after + 1)
            }
        }
        analyze()
        return firstLine
    }

    @discardableResult
    mutating func addEntry(name: String, record: Record, value: Value? = nil) -> Int? {
        let link = "[[\(name)]]"
        switch record {
        case .check: return appendBlock([Self.menuLine(checkbox: false, link: link, value: value?.text ?? "", comment: nil)])
        case .avoid: return appendBlock([Self.menuLine(checkbox: true, link: link, value: "", comment: nil)])
        case .sets: return appendBlock([Self.menuLine(checkbox: nil, link: link, value: "", comment: nil)])
        }
    }

    mutating func moveEntry(from: Int, to: Int) {
        var es = entries
        guard from != to, es.indices.contains(from), to >= 0, to <= es.count else { return }
        let blocks = es.map { Array(lines[$0.line...$0.endLine]) }
        let slots = es.map { ($0.line, $0.endLine) }
        var order = Array(es.indices)
        let moved = order.remove(at: from)
        order.insert(moved, at: to > from ? to - 1 : to)
        for (slot, source) in zip(slots.indices, order).reversed() {
            let (start, end) = slots[slot]
            lines.replaceSubrange(start...end, with: blocks[source])
        }
        es = []
        analyze()
    }

    mutating func setMemo(_ memo: String) {
        let body = memo.trimmingCharacters(in: .newlines)
        if memoHeading == nil {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("## Memo")
            analyze()
        }
        guard let heading = memoHeading else { return }
        var replacement: [String] = []
        if !body.isEmpty {
            replacement = [""] + body.components(separatedBy: "\n")
        }
        if memoEnd < lines.count { replacement.append("") }
        lines.replaceSubrange((heading + 1)..<memoEnd, with: replacement)
        analyze()
    }
}

public extension DailyDocument {
    func completion(record: (Entry) -> Record?) -> (done: Int, total: Int) {
        var done = 0
        var total = 0
        for e in entries {
            guard let state = entryState(e, record: record(e)) else { continue }
            total += 1
            if state { done += 1 }
        }
        return (done, total)
    }

    func entryState(_ e: Entry, record: Record?) -> Bool? {
        if e.hasLineProblem { return nil }
        if let checkbox = e.checkbox {
            return checkbox
        }
        if !e.sets.isEmpty {
            return e.sets.allSatisfy(\.checked)
        }
        guard let record else { return nil }
        switch record {
        case .avoid: return true
        case .check, .sets: return false
        }
    }

    func isAllComplete(record: (Entry) -> Record?) -> Bool {
        let c = completion(record: record)
        return c.total > 0 && c.done == c.total
    }
}
