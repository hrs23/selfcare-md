import Foundation
import Observation
import SelfcareCore

enum AIPreset: String, Codable, CaseIterable, Identifiable {
    case openai, anthropic, openrouter, google, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .openrouter: "OpenRouter"
        case .google: "Google"
        case .custom: "Custom"
        }
    }

    var baseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: ""
        }
    }

    var family: String {
        switch self {
        case .openai, .openrouter: "luna"
        case .anthropic: "claude-sonnet"
        case .google: "flash"
        case .custom: ""
        }
    }

    var fallbackModel: String {
        switch self {
        case .openai: "gpt-6-luna"
        case .openrouter: "openai/gpt-6-luna"
        case .anthropic: "claude-sonnet-5"
        case .google: "gemini-flash-latest"
        case .custom: ""
        }
    }

    var supportsImageGeneration: Bool {
        self == .openai || self == .custom
    }

    var fallbackImageModel: String { "gpt-image-2" }
}

enum QuickKind: String, Codable, CaseIterable, Identifiable {
    case dayPlan, menuTidy, menuImage, libraryCreate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dayPlan: "Plan the day"
        case .menuTidy: "Tidy up Menu"
        case .menuImage: "Menu image"
        case .libraryCreate: "Create Menu"
        }
    }
}

struct AISettings: Codable, Hashable {
    var preset: AIPreset = .openai
    var customBaseURL: String = ""
    var model: String?
    var customPrompt: String = ""
    var quickPrompts: [String: String] = [:]
    var imageGeneration: Bool = true
    var imageModel: String?
}

struct HealthSettings: Codable, Hashable {
    var autoImport = false
    var autoSince: Date?
    var enabledTypes: [String]?
    var requested = false
    var anchors: [String: Data] = [:]
}

struct Preferences: Codable, Hashable {
    var units: UnitPreferences = .defaults(for: .current)
    var enabledPacks: [String]?
    var health = HealthSettings()
    var ai = AISettings()
    var timerCounts: [String: Int] = [:]
    var lastActiveDay: String?
    var modelCache: [String: [String]] = [:]
}

@Observable
final class Settings {
    var prefs: Preferences {
        didSet { AppFiles.save(prefs, "preferences.json") }
    }

    init() {
        prefs = AppFiles.load(Preferences.self, "preferences.json") ?? Preferences()
    }
}
