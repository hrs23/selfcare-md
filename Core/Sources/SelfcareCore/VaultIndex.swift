import Foundation

public struct HistoryItem: Sendable, Hashable, Identifiable {
    public var id: String { "\(date)#\(entry.line)" }
    public var date: String
    public var entry: Entry
}

public struct VaultProblem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var message: String
    public var isFileProblem: Bool
}

public final class VaultIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var dailyCache: [String: (Date?, DailyDocument)] = [:]

    public init() {}

    public func dailies(_ vault: Vault) -> [(date: String, doc: DailyDocument)] {
        let dates = vault.dailyDates()
        var result: [(String, DailyDocument)] = []
        lock.lock()
        defer { lock.unlock() }
        var fresh: [String: (Date?, DailyDocument)] = [:]
        for date in dates {
            let path = Vault.dailyPath(date)
            let modified = vault.modified(path)
            if let cached = dailyCache[path], cached.0 == modified, modified != nil {
                fresh[path] = cached
                result.append((date, cached.1))
                continue
            }
            guard let text = try? vault.read(path) else { continue }
            let doc = DailyDocument(text: text)
            fresh[path] = (modified, doc)
            result.append((date, doc))
        }
        dailyCache = fresh
        return result
    }

    public func lastUsed(_ vault: Vault) -> [String: String] {
        var map: [String: String] = [:]
        for (date, doc) in dailies(vault) {
            for e in doc.entries {
                map[e.name.lowercased()] = date
            }
        }
        return map
    }

    public func history(_ vault: Vault, menu: String) -> [HistoryItem] {
        var items: [HistoryItem] = []
        for (date, doc) in dailies(vault).reversed() {
            for e in doc.entries where e.name.caseInsensitiveCompare(menu) == .orderedSame {
                items.append(HistoryItem(date: date, entry: e))
            }
        }
        return items
    }

    public func previousValue(_ vault: Vault, menu: String, date: String, current: DailyDocument?, beforeLine: Int?) -> Value? {
        Self.previousValue(in: dailies(vault), menu: menu, date: date, current: current, beforeLine: beforeLine)
    }

    public static func previousValue(in dailies: [(date: String, doc: DailyDocument)], menu: String, date: String, current: DailyDocument?, beforeLine: Int?) -> Value? {
        if let current, let beforeLine {
            let sameDay = current.entries.filter { $0.name.caseInsensitiveCompare(menu) == .orderedSame }
            for e in sameDay.reversed() {
                if let v = lastValue(e, beforeLine: beforeLine) { return v }
            }
        }
        for (d, doc) in dailies.reversed() where d < date {
            for e in doc.entries.reversed() where e.name.caseInsensitiveCompare(menu) == .orderedSame {
                if let v = lastValue(e, beforeLine: nil) { return v }
            }
        }
        return nil
    }

    static func lastValue(_ e: Entry, beforeLine: Int?) -> Value? {
        for s in e.sets.reversed() where s.checked {
            if let beforeLine, s.line >= beforeLine { continue }
            if let v = s.value, !v.isEmpty { return v }
        }
        if e.checkbox == true, let v = e.value, !v.isEmpty {
            if let beforeLine, e.line >= beforeLine { return nil }
            return v
        }
        return nil
    }

    public func recentMenu(_ vault: Vault, candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        let lower = Set(candidates.map { $0.lowercased() })
        for (_, doc) in dailies(vault).reversed() {
            for e in doc.entries.reversed() where lower.contains(e.name.lowercased()) {
                return candidates.first { $0.caseInsensitiveCompare(e.name) == .orderedSame }
            }
        }
        return candidates.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
    }

    public func problems(_ vault: Vault, menus: [MenuFile]) -> [VaultProblem] {
        var result: [VaultProblem] = []
        for m in menus where m.hasProblem {
            result.append(VaultProblem(path: Vault.menuPath(m.name), message: m.problems.joined(separator: ", "), isFileProblem: true))
        }
        for (date, doc) in dailies(vault) {
            if let p = doc.fileProblem {
                result.append(VaultProblem(path: Vault.dailyPath(date), message: p, isFileProblem: true))
            } else if doc.hasLineProblems {
                result.append(VaultProblem(path: Vault.dailyPath(date), message: "Lines with problems", isFileProblem: false))
            }
        }
        for date in vault.dailyDates() where (try? vault.read(Vault.dailyPath(date))) == nil {
            result.append(VaultProblem(path: Vault.dailyPath(date), message: "Not UTF-8", isFileProblem: true))
        }
        if let text = try? vault.read(Vault.templatePath) {
            let doc = DailyDocument(text: text, kind: .template)
            if let p = doc.fileProblem {
                result.append(VaultProblem(path: Vault.templatePath, message: p, isFileProblem: true))
            } else if doc.hasLineProblems {
                result.append(VaultProblem(path: Vault.templatePath, message: "Lines with problems", isFileProblem: false))
            }
        } else if vault.exists(Vault.templatePath) {
            result.append(VaultProblem(path: Vault.templatePath, message: "Not UTF-8", isFileProblem: true))
        }
        return result.sorted { $0.path < $1.path }
    }
}

public enum MenuStats {
    public struct Point: Sendable, Hashable, Identifiable {
        public var id: String { "\(date)-\(series)" }
        public var date: String
        public var series: String
        public var value: Double
    }

    public static func points(history: [HistoryItem], field: Field, units: UnitPreferences) -> [Point] {
        var byDate: [String: [Quantity]] = [:]
        for item in history {
            var values: [Value] = []
            if item.entry.checkbox == true, let v = item.entry.value { values.append(v) }
            for s in item.entry.sets where s.checked { if let v = s.value { values.append(v) } }
            for v in values {
                if let q = v[field] { byDate[item.date, default: []].append(q.converted(to: units)) }
            }
        }
        var points: [Point] = []
        for (date, qs) in byDate {
            if field == .bloodPressure {
                let sys = qs.map { $0.numbers[0] }
                let dia = qs.map { $0.numbers[1] }
                points.append(Point(date: date, series: "systolic", value: sys.reduce(0, +) / Double(sys.count)))
                points.append(Point(date: date, series: "diastolic", value: dia.reduce(0, +) / Double(dia.count)))
                continue
            }
            let nums = qs.map { $0.numbers[0] }
            let v: Double
            switch field {
            case .weight: v = nums.max() ?? 0
            case .reps, .distance, .duration, .volume, .energy: v = nums.reduce(0, +)
            case .heartRate, .percent, .temperature: v = nums.reduce(0, +) / Double(nums.count)
            case .bloodPressure: v = 0
            }
            points.append(Point(date: date, series: field.rawValue, value: v))
        }
        return points.sorted { $0.date < $1.date }
    }

    public static func weeklyCounts(history: [HistoryItem], weeks: Int, today: String, calendar: Calendar = .current) -> [(weekStart: Date, count: Int)] {
        guard let todayDate = DayDate.date(today, calendar: calendar),
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: todayDate)?.start else { return [] }
        var result: [(Date, Int)] = []
        for i in stride(from: weeks - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -i, to: thisWeek),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { continue }
            let days = Set(history.filter { item in
                guard let d = DayDate.date(item.date, calendar: calendar) else { return false }
                let done = item.entry.checkbox == true || item.entry.sets.contains(where: \.checked)
                return done && d >= start && d < end
            }.map(\.date))
            result.append((start, days.count))
        }
        return result
    }
}
