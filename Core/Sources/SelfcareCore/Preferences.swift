import Foundation

extension KeyedDecodingContainer {
    public func decode<T: Decodable>(_ key: Key, default value: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? value()
    }
}

public enum AIPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, anthropic, openrouter, google, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .openrouter: "OpenRouter"
        case .google: "Google"
        case .custom: "Custom"
        }
    }

    public var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: ""
        }
    }

    public var family: String {
        switch self {
        case .openai, .openrouter: "luna"
        case .anthropic: "claude-sonnet"
        case .google: "flash"
        case .custom: ""
        }
    }

    public var fallbackModel: String {
        switch self {
        case .openai: "gpt-6-luna"
        case .openrouter: "openai/gpt-6-luna"
        case .anthropic: "claude-sonnet-5"
        case .google: "gemini-flash-latest"
        case .custom: ""
        }
    }

    public var supportsImageGeneration: Bool {
        self == .openai || self == .custom
    }

    public var fallbackImageModel: String { "gpt-image-2" }
}

public struct AISettings: Codable, Hashable, Sendable {
    public var preset: AIPreset = .openai
    public var customBaseURL: String = ""
    public var model: String?
    public var customPrompt: String = ""
    public var quickPrompts: [String: String] = [:]
    public var imageGeneration: Bool = true
    public var imageModel: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        preset = c.decode(.preset, default: d.preset)
        customBaseURL = c.decode(.customBaseURL, default: d.customBaseURL)
        model = c.decode(.model, default: d.model)
        customPrompt = c.decode(.customPrompt, default: d.customPrompt)
        quickPrompts = c.decode(.quickPrompts, default: d.quickPrompts)
        imageGeneration = c.decode(.imageGeneration, default: d.imageGeneration)
        imageModel = c.decode(.imageModel, default: d.imageModel)
    }
}

public struct HealthSettings: Codable, Hashable, Sendable {
    public var autoImport = false
    public var autoSince: Date?
    public var enabledTypes: [String]?
    public var requested = false
    public var anchors: [String: Data] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HealthSettings()
        autoImport = c.decode(.autoImport, default: d.autoImport)
        autoSince = c.decode(.autoSince, default: d.autoSince)
        enabledTypes = c.decode(.enabledTypes, default: d.enabledTypes)
        requested = c.decode(.requested, default: d.requested)
        anchors = c.decode(.anchors, default: d.anchors)
    }
}

public struct Preferences: Codable, Hashable, Sendable {
    public var units: UnitPreferences = .defaults(for: .current)
    public var enabledPacks: [String]?
    public var health = HealthSettings()
    public var ai = AISettings()
    public var timerCounts: [String: Int] = [:]
    public var lastActiveDay: String?
    public var modelCache: [String: [String]] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        units = c.decode(.units, default: d.units)
        enabledPacks = c.decode(.enabledPacks, default: d.enabledPacks)
        health = c.decode(.health, default: d.health)
        ai = c.decode(.ai, default: d.ai)
        timerCounts = c.decode(.timerCounts, default: d.timerCounts)
        lastActiveDay = c.decode(.lastActiveDay, default: d.lastActiveDay)
        modelCache = c.decode(.modelCache, default: d.modelCache)
    }

    public static func load(from url: URL) -> (preferences: Preferences, canSave: Bool) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (Preferences(), !FileManager.default.fileExists(atPath: url.path))
        }
        if let preferences = try? JSONDecoder().decode(Preferences.self, from: data) {
            return (preferences, true)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        let moved = (try? FileManager.default.moveItem(at: url, to: backup)) != nil
        return (Preferences(), moved)
    }
}
