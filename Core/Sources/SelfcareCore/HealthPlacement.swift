import Foundation

public struct HealthRecord: Sendable, Hashable, Codable {
    public var type: String
    public var uuid: String?
    public var date: String
    public var quantities: [Quantity]
    public var segments: [[Quantity]]

    public init(type: String, uuid: String?, date: String, quantities: [Quantity], segments: [[Quantity]] = []) {
        self.type = type
        self.uuid = uuid?.uppercased()
        self.date = date
        self.quantities = quantities
        self.segments = segments
    }

    public var marker: HealthMarker {
        if let uuid { return .record(uuid) }
        return .aggregate(type)
    }

    func sameSource(as other: HealthRecord) -> Bool {
        marker == other.marker && (uuid != nil || date == other.date)
    }
}

public struct CatalogEntry: Sendable, Hashable {
    public var type: String
    public var name: String
    public var record: Record
    public var fields: [Field]

    public init(type: String, name: String, record: Record, fields: [Field]) {
        self.type = type
        self.name = name
        self.record = record
        self.fields = fields
    }
}

public struct HealthApplyResult: Sendable, Hashable {
    public var written: [String] = []
    public var failed: [String: String] = [:]
}

public struct HealthPlacement {
    public var menus: [MenuFile]
    public var catalog: (String) -> CatalogEntry?
    public var recentMenu: ([String]) -> String?

    public init(menus: [MenuFile], catalog: @escaping (String) -> CatalogEntry?, recentMenu: @escaping ([String]) -> String?) {
        self.menus = menus
        self.catalog = catalog
        self.recentMenu = recentMenu
    }

    func menu(_ name: String) -> MenuFile? {
        menus.first { $0.name == name } ?? menus.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func fields(for entryName: String, type: String) -> [Field] {
        if let m = menu(entryName), !m.hasProblem { return m.fields }
        return catalog(type)?.fields ?? []
    }

    static func value(_ quantities: [Quantity], fields: [Field]) -> Value {
        Value(quantities.filter { fields.contains($0.field) })
    }

    enum Target {
        case entry(Int)
        case set(entry: Int, line: Int)
    }

    @discardableResult
    public func place(_ rec: HealthRecord, into doc: inout DailyDocument) -> Bool {
        guard doc.fileProblem == nil else { return false }
        let marker = rec.marker
        for e in doc.entries {
            if e.marker == marker {
                if rec.uuid != nil { return false }
                guard e.problem == nil else { return false }
                let v = Self.value(rec.quantities, fields: fields(for: e.name, type: rec.type))
                if v.text == e.valueText && e.checkbox == true { return false }
                doc.setEntryCheck(e.line, true, value: v)
                return true
            }
            if let s = e.sets.first(where: { $0.marker == marker }) {
                if rec.uuid != nil { return false }
                guard s.problem == nil else { return false }
                let v = Self.value(rec.quantities, fields: fields(for: e.name, type: rec.type))
                if v.text == s.valueText && s.checked { return false }
                doc.replace(s.line, DailyDocument.setLine(indent: DailyDocument.indent(of: s.raw), checked: true, value: v.text, comment: s.comment))
                return true
            }
        }

        let units = rec.segments.isEmpty ? [rec.quantities] : rec.segments
        if let first = candidate(rec.type, in: doc) {
            switch first {
            case let .entry(line):
                guard let e = doc.entry(at: line) else { return false }
                let v = Self.value(rec.quantities, fields: fields(for: e.name, type: rec.type))
                doc.replace(line, DailyDocument.menuLine(checkbox: true, link: e.link, value: v.text, comment: marker.comment))
                return true
            case let .set(entryLine, _):
                var lastEntryLine = entryLine
                var index = 0
                while index < units.count, case let .set(eLine, sLine)? = candidate(rec.type, in: doc, setsOnly: true) {
                    guard let e = doc.entry(at: eLine), let s = e.sets.first(where: { $0.line == sLine }) else { break }
                    let v = Self.value(units[index], fields: fields(for: e.name, type: rec.type))
                    doc.replace(sLine, DailyDocument.setLine(indent: DailyDocument.indent(of: s.raw), checked: true, value: v.text, comment: marker.comment))
                    lastEntryLine = eLine
                    index += 1
                }
                if index < units.count, let e = doc.entry(at: lastEntryLine) {
                    let f = fields(for: e.name, type: rec.type)
                    for unit in units[index...] {
                        doc.addSet(to: lastEntryLine, value: Self.value(unit, fields: f), checked: true, comment: marker.comment)
                    }
                }
                return true
            }
        }

        let candidates = menus.filter { $0.appleHealth == rec.type && $0.record != .avoid && !$0.hasProblem }
        let name: String
        let record: Record
        let fields: [Field]
        if let chosen = recentMenu(candidates.map(\.name)), let m = menu(chosen) {
            name = m.name
            record = m.record
            fields = m.fields
        } else if let c = catalog(rec.type) {
            name = c.name
            record = c.record
            fields = c.fields
        } else {
            return false
        }
        let link = "[[\(name)]]"
        switch record {
        case .check, .avoid:
            let v = Self.value(rec.quantities, fields: fields)
            doc.appendBlock([DailyDocument.menuLine(checkbox: true, link: link, value: v.text, comment: marker.comment)])
        case .sets:
            if let e = doc.entries.last(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.checkbox == nil && $0.problem == nil && $0.valueText.isEmpty }) {
                for unit in units {
                    doc.addSet(to: e.line, value: Self.value(unit, fields: fields), checked: true, comment: marker.comment)
                }
            } else {
                var block = [DailyDocument.menuLine(checkbox: nil, link: link, value: "", comment: nil)]
                for unit in units {
                    block.append(DailyDocument.setLine(indent: "  ", checked: true, value: Self.value(unit, fields: fields).text, comment: marker.comment))
                }
                doc.appendBlock(block)
            }
        }
        return true
    }

    public func apply(_ records: [HealthRecord], retrying retry: [HealthRecord], vault: Vault, newDaily: (String) throws -> DailyDocument) -> (result: HealthApplyResult, retry: [HealthRecord]) {
        let all = retry.filter { old in !records.contains { $0.sameSource(as: old) } } + records
        let result = apply(all, vault: vault, newDaily: newDaily)
        return (result, all.filter { result.failed[$0.date] != nil })
    }

    public func apply(_ records: [HealthRecord], vault: Vault, newDaily: (String) throws -> DailyDocument) -> HealthApplyResult {
        var result = HealthApplyResult()
        for (date, group) in Dictionary(grouping: records, by: \.date).sorted(by: { $0.key < $1.key }) {
            let path = Vault.dailyPath(date)
            do {
                var doc = try vault.readIfExists(path).map { DailyDocument(text: $0) } ?? newDaily(date)
                if let problem = doc.fileProblem {
                    result.failed[date] = "\(path): \(problem)"
                    continue
                }
                let before = doc.text
                for r in group.sorted(by: { ($0.uuid ?? "") < ($1.uuid ?? "") }) {
                    place(r, into: &doc)
                }
                if doc.text != before {
                    try vault.write(path, doc.text)
                    result.written.append(date)
                }
            } catch let error as VaultError {
                result.failed[date] = error.localizedDescription
            } catch {
                result.failed[date] = "\(path): \(error.localizedDescription)"
            }
        }
        return result
    }

    func candidate(_ type: String, in doc: DailyDocument, setsOnly: Bool = false) -> Target? {
        var manual: Target?
        for e in doc.entries where e.problem == nil {
            guard let m = menu(e.name), !m.hasProblem, m.appleHealth == type else { continue }
            switch m.record {
            case .check:
                if setsOnly { continue }
                guard e.sets.isEmpty, e.marker == nil else { continue }
                if e.checkbox == true {
                    if manual == nil { manual = .entry(e.line) }
                } else {
                    return .entry(e.line)
                }
            case .sets:
                guard e.checkbox == nil, e.valueText.isEmpty else { continue }
                for s in e.sets where s.marker == nil && s.problem == nil {
                    if s.checked {
                        if manual == nil { manual = .set(entry: e.line, line: s.line) }
                    } else {
                        return .set(entry: e.line, line: s.line)
                    }
                }
            case .avoid:
                continue
            }
        }
        return manual
    }
}
