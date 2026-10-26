import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ChatImage: Codable, Sendable, Hashable {
    public var mime: String
    public var base64: String

    public init(mime: String, base64: String) {
        self.mime = mime
        self.base64 = base64
    }
}

public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var args: [String: Any] {
        guard let data = arguments.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var text: String
    public var images: [ChatImage]
    public var toolCalls: [ToolCall]
    public var toolCallId: String?
    public var toolName: String?
    public var attachments: [String]
    public var omitted: Bool
    public var hidden: Bool

    public init(id: UUID = UUID(), role: ChatRole, text: String, images: [ChatImage] = [], toolCalls: [ToolCall] = [], toolCallId: String? = nil, toolName: String? = nil, attachments: [String] = [], omitted: Bool = false, hidden: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.attachments = attachments
        self.omitted = omitted
        self.hidden = hidden
    }

    public var apiJSON: [String: Any] {
        switch role {
        case .system:
            return ["role": "system", "content": text]
        case .user:
            if images.isEmpty { return ["role": "user", "content": text] }
            var parts: [[String: Any]] = []
            if !text.isEmpty { parts.append(["type": "text", "text": text]) }
            for image in images {
                parts.append(["type": "image_url", "image_url": ["url": "data:\(image.mime);base64,\(image.base64)"]])
            }
            return ["role": "user", "content": parts]
        case .assistant:
            var obj: [String: Any] = ["role": "assistant"]
            obj["content"] = text.isEmpty && !toolCalls.isEmpty ? NSNull() : text
            if !toolCalls.isEmpty {
                obj["tool_calls"] = toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] }
            }
            return obj
        case .tool:
            return ["role": "tool", "tool_call_id": toolCallId ?? "", "content": omitted ? "[Omitted to save context. Call the tool again if needed.]" : text]
        }
    }

    public var estimatedTokens: Int {
        let chars = text.count + toolCalls.reduce(0) { $0 + $1.arguments.count + $1.name.count }
        return (omitted ? 12 : chars / 3) + images.count * 1200 + 8
    }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public var apiJSON: [String: Any] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parameters.utf8))) ?? ["type": "object", "properties": [:]]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": params]]
    }
}

public enum AIError: Error, LocalizedError, Equatable {
    case invalidKey
    case unreachable(String)
    case modelUnavailable(String)
    case imagesUnsupported
    case server(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The API key is invalid"
        case let .unreachable(m): "Cannot connect: \(m)"
        case let .modelUnavailable(m): "The model is not available: \(m)"
        case .imagesUnsupported: "This model cannot read images"
        case let .server(code, m): "Error \(code): \(m)"
        case .badResponse: "Unexpected response"
        }
    }
}

public enum StreamEvent: Sendable {
    case text(String)
    case toolCalls([ToolCall])
    case finished(String?)
}

public struct AIEndpoint: Sendable, Hashable {
    public var baseURL: URL
    public var apiKey: String
    public var anthropic: Bool

    public init(baseURL: URL, apiKey: String, anthropic: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.anthropic = anthropic
    }
}

public final class ChatClient: @unchecked Sendable {
    public let endpoint: AIEndpoint
    let session: URLSession

    public init(endpoint: AIEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func request(_ path: String, method: String = "POST", body: [String: Any]? = nil) -> URLRequest {
        let url = endpoint.baseURL.appendingPathComponent(path)
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        if endpoint.anthropic {
            r.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    static func classify(status: Int, body: String) -> AIError {
        let lower = body.lowercased()
        if status == 401 || status == 403 { return .invalidKey }
        if lower.contains("image") && (lower.contains("support") || lower.contains("vision") || lower.contains("invalid")) && status == 400 {
            return .imagesUnsupported
        }
        if status == 404 || (status == 400 && lower.contains("model")) {
            return .modelUnavailable(message(body))
        }
        return .server(status, message(body))
    }

    static func message(_ body: String) -> String {
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            if let dict = obj as? [String: Any] {
                if let e = dict["error"] as? [String: Any], let m = e["message"] as? String { return m }
                if let m = dict["message"] as? String { return m }
            }
            if let arr = obj as? [[String: Any]], let e = arr.first?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        }
        return String(body.prefix(300))
    }

    static func wrap(_ error: Error) -> Error {
        if let e = error as? AIError { return e }
        if error is CancellationError { return error }
        if let u = error as? URLError {
            if u.code == .cancelled { return CancellationError() }
            return AIError.unreachable(u.localizedDescription)
        }
        return error
    }

    public func models() async throws -> [String] {
        do {
            let (data, response) = try await session.data(for: request("models", method: "GET"))
            guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.classify(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }
            let list = (obj["data"] as? [[String: Any]]) ?? (obj["models"] as? [[String: Any]]) ?? []
            return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        } catch {
            throw Self.wrap(error)
        }
    }

    public func ping(model: String) async throws {
        do {
            let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Reply with OK."]], "max_completion_tokens": 16]
            let (data, response) = try await session.data(for: request("chat/completions", body: body))
            guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
            if http.statusCode == 400, String(decoding: data, as: UTF8.self).contains("max_completion_tokens") {
                let retry: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Reply with OK."]], "max_tokens": 16]
                let (d2, r2) = try await session.data(for: request("chat/completions", body: retry))
                guard let h2 = r2 as? HTTPURLResponse, (200..<300).contains(h2.statusCode) else {
                    throw Self.classify(status: (r2 as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: d2, as: UTF8.self))
                }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.classify(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
            }
        } catch {
            throw Self.wrap(error)
        }
    }

    nonisolated(unsafe) private static var noReasoning = Set<String>()
    private static let lock = NSLock()

    func requiresNoReasoning(_ model: String) -> Bool {
        Self.lock.withLock { Self.noReasoning.contains(endpoint.baseURL.absoluteString + "|" + model) }
    }

    func markNoReasoning(_ model: String) {
        _ = Self.lock.withLock { Self.noReasoning.insert(endpoint.baseURL.absoluteString + "|" + model) }
    }

    static func asksNoReasoning(_ error: Error) -> Bool {
        guard let e = error as? AIError else { return false }
        switch e {
        case let .server(400, m), let .modelUnavailable(m):
            return m.contains("reasoning_effort") && m.contains("none")
        default:
            return false
        }
    }

    public func stream(model: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.apiJSON),
            "stream": true,
        ]
        if !tools.isEmpty { body["tools"] = tools.map(\.apiJSON) }
        let session = self.session
        let plain = request("chat/completions", body: body)
        body["reasoning_effort"] = "none"
        let noReasoning = request("chat/completions", body: body)
        let hasTools = !tools.isEmpty
        return AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    attempt += 1
                    let req = self.requiresNoReasoning(model) && hasTools ? noReasoning : plain
                    do {
                        try await Self.run(req, session: session, continuation: continuation)
                        continuation.finish()
                        return
                    } catch {
                        let wrapped = Self.wrap(error)
                        if attempt == 1, !self.requiresNoReasoning(model), Self.asksNoReasoning(wrapped) {
                            self.markNoReasoning(model)
                            continue
                        }
                        continuation.finish(throwing: wrapped)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func run(_ req: URLRequest, session: URLSession, continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        if !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line + "\n" }
            throw classify(status: http.statusCode, body: text)
        }
        var accumulator = ToolCallAccumulator()
        var finish: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw AIError.server(0, (err["message"] as? String) ?? "Stream error")
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    continuation.yield(.text(content))
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    accumulator.add(calls)
                }
            }
            if let f = choice["finish_reason"] as? String { finish = f }
        }
        let calls = accumulator.calls
        if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
        continuation.yield(.finished(finish))
    }

    public func generateImage(model: String, prompt: String) async throws -> Data {
        do {
            let body: [String: Any] = ["model": model, "prompt": prompt, "n": 1, "size": "1024x1024"]
            let (data, response) = try await session.data(for: request("images/generations", body: body))
            guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.classify(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (obj["data"] as? [[String: Any]])?.first else { throw AIError.badResponse }
            if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) { return d }
            if let urlString = first["url"] as? String, let url = URL(string: urlString) {
                let (d, _) = try await session.data(from: url)
                return d
            }
            throw AIError.badResponse
        } catch {
            throw Self.wrap(error)
        }
    }
}

struct ToolCallAccumulator {
    var byIndex: [Int: (id: String, name: String, args: String)] = [:]

    mutating func add(_ deltas: [[String: Any]]) {
        for d in deltas {
            let index = (d["index"] as? Int) ?? byIndex.count
            var current = byIndex[index] ?? ("", "", "")
            if let id = d["id"] as? String, !id.isEmpty { current.id = id }
            if let f = d["function"] as? [String: Any] {
                if let n = f["name"] as? String { current.name += current.name == n ? "" : n }
                if let a = f["arguments"] as? String { current.args += a }
            }
            byIndex[index] = current
        }
    }

    var calls: [ToolCall] {
        byIndex.keys.sorted().compactMap { i in
            guard let c = byIndex[i], !c.name.isEmpty else { return nil }
            return ToolCall(id: c.id.isEmpty ? "call_\(i)_\(UUID().uuidString.prefix(8))" : c.id, name: c.name, arguments: c.args)
        }
    }
}

public enum ModelChooser {
    public static func pick(family: String, from models: [String], fallback: String) -> String {
        let lower = family.lowercased()
        let matches = models.filter { m in
            let l = m.lowercased()
            guard l.contains(lower) else { return false }
            if l.contains(":") { return false }
            if l.range(of: #"\d{4}-\d{2}-\d{2}|\d{8}|preview|-pro\b|-mini\b|-nano\b|lite|image|tts|audio|realtime|embedding|search|transcribe|live|exp"#, options: .regularExpression) != nil { return false }
            return true
        }
        guard !matches.isEmpty else { return fallback }
        return matches.max { versionKey($0).lexicographicallyPrecedes(versionKey($1)) } ?? fallback
    }

    public static func versionKey(_ id: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let ns = id as NSString
        let nums = regex.matches(in: id, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
        return nums + [-Double(id.count)]
    }
}

