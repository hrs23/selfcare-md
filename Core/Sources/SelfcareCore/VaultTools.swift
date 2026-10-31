import Foundation

public enum ToolError: Error, LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .message(m): m
        }
    }
}

public enum ToolOutcome: Sendable {
    case text(String)
    case image(path: String, data: Data)
}

public struct ToolPermission: Sendable, Hashable {
    public var title: String
    public var path: String
    public var detail: String
    public var isDiff: Bool
}

public struct ToolContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var imageGenerator: (@Sendable (String) async throws -> Data)?
    public var fetcher: @Sendable (URL) async throws -> (Data, String?)
    public var allowedWrite: (@Sendable (String) -> Bool)?

    public init(now: Date = Date(), timeZone: TimeZone = .current, imageGenerator: (@Sendable (String) async throws -> Data)?, fetcher: @escaping @Sendable (URL) async throws -> (Data, String?), allowedWrite: (@Sendable (String) -> Bool)? = nil) {
        self.now = now
        self.timeZone = timeZone
        self.imageGenerator = imageGenerator
        self.fetcher = fetcher
        self.allowedWrite = allowedWrite
    }
}

public final class VaultTools: @unchecked Sendable {
    public let vault: Vault
    public static let writeTools: Set<String> = ["edit", "write", "move", "delete", "generate_image"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]

    public init(vault: Vault) {
        self.vault = vault
    }

    public static func specs(imageGeneration: Bool) -> [ToolSpec] {
        var specs = [
            ToolSpec(name: "glob", description: "List vault files matching a glob pattern (e.g. menus/*.md, daily/2026-09-*.md, **/*.tcx). Returns path, created and modified times. Sorted by modified time, newest first, unless sort is name.", parameters: #"{"type":"object","properties":{"pattern":{"type":"string"},"sort":{"type":"string","enum":["modified","name"]},"limit":{"type":"integer"}},"required":["pattern"]}"#),
            ToolSpec(name: "grep", description: "Search text files in the vault with a regular expression. Returns path:line: text.", parameters: #"{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string","description":"Optional glob to limit files"},"ignore_case":{"type":"boolean"}},"required":["pattern"]}"#),
            ToolSpec(name: "read", description: "Read a vault file. Text files return their content. Images are attached for you to see.", parameters: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
            ToolSpec(name: "edit", description: "Replace an exact string in a vault file. old_string must match exactly once unless replace_all is true.", parameters: #"{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}"#),
            ToolSpec(name: "write", description: "Create a new vault file or rewrite a whole file.", parameters: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#),
            ToolSpec(name: "move", description: "Move or rename a vault file. Renaming a Menu (menus/A.md to menus/B.md) also updates every [[A]] link.", parameters: #"{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}},"required":["from","to"]}"#),
            ToolSpec(name: "delete", description: "Delete a vault file.", parameters: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
            ToolSpec(name: "fetch", description: "Fetch a web page or file over HTTP(S) and return its text.", parameters: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
            ToolSpec(name: "now", description: "Current date, time, weekday and time zone of the device.", parameters: #"{"type":"object","properties":{}}"#),
        ]
        if imageGeneration {
            specs.append(ToolSpec(name: "generate_image", description: "Generate an image from a prompt and save it in the vault (png). Default folder is media/.", parameters: #"{"type":"object","properties":{"prompt":{"type":"string"},"path":{"type":"string","description":"Vault path ending in .png"}},"required":["prompt"]}"#))
        }
        return specs
    }

    func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String else { throw ToolError.message("Missing \(key)") }
        return v
    }

    func checkWrite(_ path: String, _ context: ToolContext) throws -> String {
        let clean = try Vault.clean(path)
        guard !clean.isEmpty else { throw ToolError.message("Invalid path") }
        _ = try vault.url(clean)
        if let allowed = context.allowedWrite, !allowed(clean) {
            throw ToolError.message("Writing \(clean) is not allowed for this action")
        }
        return clean
    }

    public func permission(_ call: ToolCall) -> ToolPermission {
        let args = call.args
        let path = (args["path"] as? String) ?? ""
        switch call.name {
        case "edit":
            let old = (try? vault.read(path)) ?? ""
            var new = old
            if let o = args["old_string"] as? String, let n = args["new_string"] as? String, !o.isEmpty {
                new = Self.replace(old, o, n, all: (args["replace_all"] as? Bool) == true)
            }
            return ToolPermission(title: "Edit", path: path, detail: LineDiff.render(old: old, new: new), isDiff: true)
        case "write":
            let content = (args["content"] as? String) ?? ""
            if let old = try? vault.read(path) {
                return ToolPermission(title: "Rewrite", path: path, detail: LineDiff.render(old: old, new: content), isDiff: true)
            }
            return ToolPermission(title: "Create", path: path, detail: content, isDiff: false)
        case "move":
            return ToolPermission(title: "Move", path: "\((args["from"] as? String) ?? "") → \((args["to"] as? String) ?? "")", detail: "", isDiff: false)
        case "delete":
            return ToolPermission(title: "Delete", path: path, detail: "", isDiff: false)
        case "generate_image":
            return ToolPermission(title: "Generate image", path: path.isEmpty ? "media/" : path, detail: (args["prompt"] as? String) ?? "", isDiff: false)
        default:
            return ToolPermission(title: call.name, path: path, detail: call.arguments, isDiff: false)
        }
    }

    static func replace(_ s: String, _ old: String, _ new: String, all: Bool) -> String {
        if all { return s.replacingOccurrences(of: old, with: new) }
        guard let r = s.range(of: old) else { return s }
        return s.replacingCharacters(in: r, with: new)
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolOutcome {
        let args = call.args
        switch call.name {
        case "now":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = context.timeZone
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX EEEE"
            return .text("\(f.string(from: context.now)) (\(context.timeZone.identifier))")
        case "glob":
            let pattern = try string(args, "pattern")
            let regex = try Glob.regex(pattern)
            var infos = vault.list().filter { Glob.matches(regex, $0) }.compactMap { vault.info($0) }
            if (args["sort"] as? String) == "name" {
                infos.sort { $0.path < $1.path }
            } else {
                infos.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            }
            let limit = (args["limit"] as? Int) ?? 500
            let iso = ISO8601DateFormatter()
            iso.timeZone = context.timeZone
            let lines = infos.prefix(limit).map { i in
                "\(i.path)\tcreated \(i.created.map { iso.string(from: $0) } ?? "-")\tmodified \(i.modified.map { iso.string(from: $0) } ?? "-")"
            }
            return .text(lines.isEmpty ? "No files" : lines.joined(separator: "\n") + (infos.count > limit ? "\n… \(infos.count - limit) more" : ""))
        case "grep":
            let pattern = try string(args, "pattern")
            let options: NSRegularExpression.Options = (args["ignore_case"] as? Bool) == true ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { throw ToolError.message("Invalid regular expression") }
            let filter = try (args["glob"] as? String).map { try Glob.regex($0) }
            var results: [String] = []
            for path in vault.list() where !Self.isBinary(path) {
                if let filter, !Glob.matches(filter, path) { continue }
                guard let text = try? vault.read(path) else { continue }
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let ns = line as NSString
                    if regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                        results.append("\(path):\(i + 1): \(line)")
                        if results.count >= 300 { break }
                    }
                }
                if results.count >= 300 { break }
            }
            return .text(results.isEmpty ? "No matches" : results.joined(separator: "\n"))
        case "read":
            let path = try Vault.clean(try string(args, "path"))
            if vault.isDirectory(path) {
                return .text(vault.list(path, recursive: false, includeDirectories: true).joined(separator: "\n"))
            }
            if Self.isImage(path) {
                return .image(path: path, data: try vault.readData(path))
            }
            return .text(try vault.read(path))
        case "edit":
            let path = try checkWrite(try string(args, "path"), context)
            let old = try string(args, "old_string")
            let new = try string(args, "new_string")
            guard !old.isEmpty else { throw ToolError.message("old_string is empty") }
            let text = try vault.read(path)
            let count = text.components(separatedBy: old).count - 1
            guard count > 0 else { throw ToolError.message("old_string not found in \(path)") }
            let all = (args["replace_all"] as? Bool) == true
            guard count == 1 || all else { throw ToolError.message("old_string matches \(count) times; add more context or set replace_all") }
            let updated = Self.replace(text, old, new, all: all)
            try vault.writeRaw(path, updated.hasSuffix("\n") ? updated : updated + "\n")
            return .text("Edited \(path)")
        case "write":
            let path = try checkWrite(try string(args, "path"), context)
            let content = try string(args, "content")
            let existed = vault.exists(path)
            try vault.write(path, content)
            return .text("\(existed ? "Rewrote" : "Created") \(path)")
        case "move":
            let from = try checkWrite(try string(args, "from"), context)
            let to = try checkWrite(try string(args, "to"), context)
            if from.hasPrefix("menus/"), to.hasPrefix("menus/"), from.hasSuffix(".md"), to.hasSuffix(".md"),
               !from.dropFirst(6).contains("/"), !to.dropFirst(6).contains("/") {
                try vault.renameMenu(from: String(from.dropFirst(6).dropLast(3)), to: String(to.dropFirst(6).dropLast(3)))
                return .text("Renamed Menu and updated links: \(from) → \(to)")
            }
            try vault.move(from, to)
            return .text("Moved \(from) → \(to)")
        case "delete":
            let path = try checkWrite(try string(args, "path"), context)
            try vault.delete(path)
            return .text("Deleted \(path)")
        case "fetch":
            let raw = try string(args, "url")
            guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme) else { throw ToolError.message("Invalid URL") }
            let (data, mime) = try await context.fetcher(url)
            let text = String(decoding: data, as: UTF8.self)
            let body = (mime ?? "").contains("html") || text.lowercased().contains("<html") ? HTMLText.extract(text) : text
            return .text(String(body.prefix(30000)))
        case "generate_image":
            guard let generator = context.imageGenerator else { throw ToolError.message("Image generation is not available") }
            let prompt = try string(args, "prompt")
            var path = (args["path"] as? String) ?? ""
            if path.isEmpty {
                path = "media/\(Self.slug(prompt))-\(UUID().uuidString.prefix(6)).png"
            }
            path = try checkWrite(path, context)
            let data = try await generator(prompt)
            try vault.writeData(path, data)
            return .text("Saved image to \(path)")
        default:
            throw ToolError.message("Unknown tool \(call.name)")
        }
    }

    static func slug(_ s: String) -> String {
        let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        return collapsed.isEmpty ? "image" : String(collapsed.prefix(40))
    }

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isBinary(_ path: String) -> Bool {
        isImage(path) || ["pdf", "zip", "mov", "mp4"].contains((path as NSString).pathExtension.lowercased())
    }
}

public enum Glob {
    public static func regex(_ pattern: String) throws -> NSRegularExpression {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasPrefix("/") { p.removeFirst() }
        var r = "^"
        var i = p.startIndex
        while i < p.endIndex {
            let c = p[i]
            let next = p.index(after: i)
            if c == "*" {
                if next < p.endIndex, p[next] == "*" {
                    let after = p.index(after: next)
                    if after < p.endIndex, p[after] == "/" {
                        r += "(?:.*/)?"
                        i = p.index(after: after)
                    } else {
                        r += ".*"
                        i = after
                    }
                    continue
                }
                r += "[^/]*"
            } else if c == "?" {
                r += "[^/]"
            } else if c == "{" {
                r += "(?:"
            } else if c == "}" {
                r += ")"
            } else if c == ",", p[..<i].contains("{") {
                r += "|"
            } else {
                r += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = next
        }
        r += "$"
        do {
            return try NSRegularExpression(pattern: r)
        } catch {
            throw ToolError.message("Invalid pattern")
        }
    }

    public static func matches(_ regex: NSRegularExpression, _ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }
}

public enum LineDiff {
    public static func render(old: String, new: String, context: Int = 2) -> String {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        if removed.isEmpty && inserted.isEmpty { return "No changes" }
        var ops: [(Character, String, Bool)] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                ops.append(("-", a[i], true))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                ops.append(("+", b[j], true))
                j += 1
            } else {
                if i < a.count { ops.append((" ", a[i], false)) }
                i += 1
                j += 1
            }
        }
        var keep = Set<Int>()
        for (index, op) in ops.enumerated() where op.2 {
            for k in max(0, index - context)...min(ops.count - 1, index + context) { keep.insert(k) }
        }
        var out: [String] = []
        var last = -2
        for index in keep.sorted() {
            if index != last + 1 && !out.isEmpty { out.append("⋯") }
            let op = ops[index]
            out.append("\(op.0) \(op.1)")
            last = index
        }
        return out.joined(separator: "\n")
    }
}

public enum HTMLText {
    public static func extract(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        var title = ""
        if let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (e, r) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? body : "Title: \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(body)"
    }
}

public enum SystemPrompt {
    public static func build(today: Date, timeZone: TimeZone, language: String, custom: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd EEEE"
        var s = """
        You are the assistant inside selfcare.md, a local-first self-care log (training, habits, body records). The records are Markdown files in a vault that you read and edit with the tools.

        Vault layout:
        - menus/<Menu name>.md — a Menu. The file name is its name and its [[wikilink]]. Frontmatter keys: record (check | avoid | sets, default check), fields (list of weight, reps, distance, duration, heart-rate, percent, blood-pressure, volume, energy, temperature), tags, apple-health (Apple HealthKit constant name), thumbnail, initial (first value, e.g. 25kg × 10). Body: form notes, images.
        - daily/YYYY-MM-DD.md — one page per day with only `# YYYY-MM-DD`, `## Selfcare` and `## Memo`.
        - templates/Daily.md — the `## Selfcare` plan copied into each new day.
        - workouts/YYYY-MM-DD-<UUID>.tcx — Apple Health workouts exported as TCX. The UUID matches a Daily line marker.
        - media/ — images.

        Selfcare lines:
        - check: `- [x] [[Morning Run]] 5.0km × 28:00` (one record per line, value after the link, [ ] = not done).
        - avoid: `- [x] [[No Snacking]]` ([x] = kept, [ ] = broken). No value.
        - sets: a Menu line without checkbox, then one indented value line per set: `  - [x] 30kg × 10`.
        - A Menu line with no checkbox and no value lines is a plan.
        - Values join items with ` × `. Formats: 30kg, 22.5lb, 10 (reps), 5.0km, 400m, 28:00 or 1:30:45 (duration), 152bpm, 18.5%, 120/80mmHg, 250ml, 1.5l, 320kcal, 36.5°C.
        - `<!-- apple-health:... -->` marks lines imported from Apple Health. Do not change imported values or markers.

        Today is \(f.string(from: today)) (\(timeZone.identifier)).

        Rules:
        - Reply in the user's language (\(language)) unless asked otherwise.
        - Read a file before editing it. Make the smallest edit that does the job.
        - Never write in `## Memo` unless the user asks.
        - Keep unknown content, frontmatter keys and formatting as they are.
        - Rename a Menu with the move tool so links are updated.
        - Menu names cannot contain / \\ [[ ]] | # ^.
        """
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            s += "\n\nUser instructions:\n" + trimmed
        }
        return s
    }
}
