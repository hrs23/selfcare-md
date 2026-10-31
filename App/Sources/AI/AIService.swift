import Foundation
import Observation
import SelfcareCore

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []
}

struct QuickRun {
    var kind: QuickKind
    var target: String
    var running = true
    var error: String?
    var originals: [String: Data?] = [:]

    var canUndo: Bool { !running && !originals.isEmpty }
}

enum ConnectionResult: Equatable {
    case ok
    case invalidKey
    case unreachable(String)
    case modelUnavailable(String)
    case other(String)

    var message: String {
        switch self {
        case .ok: "Connected"
        case .invalidKey: "The API key is invalid"
        case let .unreachable(m): "Cannot connect: \(m)"
        case let .modelUnavailable(m): "The model is not available: \(m)"
        case let .other(m): m
        }
    }
}

@Observable
final class AIService {
    unowned let app: AppModel
    var quick: QuickRun?
    private var quickTask: Task<Void, Never>?
    var conversations: [Conversation] = []
    var models: [String] = []
    var testing = false
    var testResult: ConnectionResult?

    init(model: AppModel) {
        app = model
        loadConversations()
        models = settings.model.map { [$0] } ?? []
        if let cached = app.settings.prefs.modelCache[cacheKey] { models = cached }
    }

    var settings: AISettings {
        get { app.settings.prefs.ai }
        set { app.settings.prefs.ai = newValue }
    }

    var cacheKey: String { settings.preset.rawValue + "|" + baseURLString }

    var baseURLString: String {
        settings.preset == .custom ? settings.customBaseURL.trimmingCharacters(in: .whitespaces) : settings.preset.baseURL
    }

    var apiKey: String {
        get { Keychain.get("ai.key." + settings.preset.rawValue) ?? "" }
        set { Keychain.set(newValue, for: "ai.key." + settings.preset.rawValue) }
    }

    var configured: Bool {
        !apiKey.isEmpty && URL(string: baseURLString)?.scheme != nil && !resolvedModel.isEmpty
    }

    var resolvedModel: String {
        if let m = settings.model, !m.isEmpty { return m }
        if settings.preset == .custom { return models.first ?? "" }
        return ModelChooser.pick(family: settings.preset.family, from: models, fallback: settings.preset.fallbackModel)
    }

    var imageGenerationAvailable: Bool {
        configured && settings.preset.supportsImageGeneration && settings.imageGeneration
    }

    var resolvedImageModel: String {
        if let m = settings.imageModel, !m.isEmpty { return m }
        let plain = models.filter { $0.range(of: #"^gpt-image-\d+(\.\d+)?$"#, options: .regularExpression) != nil }
        return plain.max { ModelChooser.versionKey($0).lexicographicallyPrecedes(ModelChooser.versionKey($1)) } ?? settings.preset.fallbackImageModel
    }

    func client() -> ChatClient? {
        guard let url = URL(string: baseURLString), !apiKey.isEmpty else { return nil }
        return ChatClient(endpoint: AIEndpoint(baseURL: url, apiKey: apiKey, anthropic: settings.preset == .anthropic))
    }

    func refreshModels() async {
        guard let client = client() else { return }
        if let list = try? await client.models(), !list.isEmpty {
            storeModels(list)
        } else {
            models = app.settings.prefs.modelCache[cacheKey] ?? []
        }
    }

    private func storeModels(_ list: [String]) {
        models = list.sorted()
        app.settings.prefs.modelCache[cacheKey] = models
    }

    func testConnection() async {
        testing = true
        defer { testing = false }
        testResult = nil
        guard let client = client() else {
            testResult = .invalidKey
            return
        }
        do {
            let list = try await client.models()
            if !list.isEmpty { storeModels(list) }
            try await client.ping(model: resolvedModel)
            testResult = .ok
        } catch let error as AIError {
            switch error {
            case .invalidKey: testResult = .invalidKey
            case let .unreachable(m): testResult = .unreachable(m)
            case let .modelUnavailable(m): testResult = .modelUnavailable(m)
            default: testResult = .other(error.localizedDescription)
            }
        } catch {
            testResult = .other(error.localizedDescription)
        }
    }

    func applyDebugKey() {
        guard let key = BuildInfo.debugOpenAIKey else {
            app.alert = "No debug key in this build"
            return
        }
        settings.preset = .openai
        settings.model = nil
        apiKey = key
        Task {
            await refreshModels()
            await testConnection()
        }
    }

    func toolContext(allowedWrite: (@Sendable (String) -> Bool)? = nil) -> ToolContext {
        let client = self.client()
        let imageModel = resolvedImageModel
        var generator: (@concurrent @Sendable (String) async throws -> Data)?
        let extra = settings.quickPrompts[QuickKind.menuImage.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if imageGenerationAvailable, let client {
            generator = { @Sendable prompt in
                try await client.generateImage(model: imageModel, prompt: extra.isEmpty ? prompt : prompt + "\n\n" + extra)
            }
        }
        return ToolContext(imageGenerator: generator, fetcher: { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
        }, allowedWrite: allowedWrite)
    }

    func systemPrompt() -> String {
        SystemPrompt.build(today: Date(), timeZone: .current, language: BuildInfo.languageName, custom: settings.customPrompt)
    }

    var quickRunning: Bool { quick?.running == true }

    func quickRunning(for target: String) -> Bool {
        quick?.running == true && quick?.target == target
    }

    func runQuick(_ kind: QuickKind, target: String, date: String, input: String = "") {
        guard configured, let client = client() else {
            app.tab = .settings
            app.settingsPath = [.aiSettings]
            return
        }
        guard !quickRunning else { return }
        let vault = app.vault
        let recorder = WriteRecorder(vault: vault)
        let allowed: @Sendable (String) -> Bool
        switch kind {
        case .dayPlan, .menuTidy:
            allowed = { path in
                guard path == target else { return false }
                recorder.record(path)
                return true
            }
        case .menuImage:
            allowed = { path in
                guard path == target || path.hasPrefix("media/generated/") else { return false }
                recorder.record(path)
                return true
            }
        case .libraryCreate:
            allowed = { path in
                guard path.hasPrefix("menus/"), path.hasSuffix(".md") else { return false }
                if recorder.created(path) { return true }
                guard !vault.exists(path) else { return false }
                recorder.record(path)
                return true
            }
        }
        let extra = settings.quickPrompts[kind.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var prompt = Self.prompt(kind, target: target, date: date, input: input)
        if !extra.isEmpty { prompt += "\n\nAdditional instructions:\n" + extra }
        let messages = [ChatMessage(role: .system, text: systemPrompt()), ChatMessage(role: .user, text: prompt)]
        let runner = AgentRunner(client: client, model: resolvedModel, tools: VaultTools(vault: vault), specs: VaultTools.specs(imageGeneration: kind == .menuImage && imageGenerationAvailable), context: toolContext(allowedWrite: allowed), askPermission: false, messages: messages)
        quick = QuickRun(kind: kind, target: target)
        quickTask = Task {
            do {
                try await runner.run()
                quick?.running = false
            } catch is CancellationError {
                quick?.running = false
            } catch {
                quick?.running = false
                quick?.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            quick?.originals = recorder.snapshot
            if quick?.originals.isEmpty == true && quick?.error == nil {
                quick = nil
            }
            app.vaultChanged()
        }
    }

    func stopQuick() {
        quickTask?.cancel()
    }

    func undoQuick() {
        guard let quick else { return }
        for (path, data) in quick.originals {
            if let data {
                try? app.vault.writeData(path, data)
            } else {
                try? app.vault.delete(path)
            }
        }
        self.quick = nil
        app.vaultChanged()
    }

    func dismissQuick() {
        quick = nil
    }

    static func prompt(_ kind: QuickKind, target: String, date: String, input: String) -> String {
        switch kind {
        case .dayPlan:
            """
            Plan the Selfcare for \(date) in \(target).
            1. Use glob on daily/*.md (newest first) and read the recent pages, the template (templates/Daily.md) and the Menus in menus/.
            2. Choose a sensible set of Menus for this day from what the user usually does, their balance and rest.
            3. Append them to the end of the ## Selfcare section of \(target) as plans: `- [ ] [[Menu]]` for check Menus, `- [[Menu]]` for sets Menus, `- [x] [[Menu]]` for avoid Menus. Use existing Menu names exactly. Skip Menus already on the page.
            4. Do not change existing lines and do not write in ## Memo. If the file does not exist, create it with `# \(date)`, `## Selfcare` and `## Memo`.
            Reply with a one-line summary.
            """
        case .menuTidy:
            """
            Tidy up the Menu \(target).
            Improve the body (short, clear form notes in the Menu's language), tags, apple-health (only a valid HealthKit constant name that fits, or none) and initial (a sensible first value using the Menu's fields, for someone about one month into training).
            Do not change the file name, record or fields. Keep unknown keys and images. Edit only this file.
            Reply with a one-line summary.
            """
        case .menuImage:
            """
            Create an image for the Menu \(target).
            Read the Menu, then call generate_image with a clean illustration of it (no text), saved as media/generated/<a short slug>.png.
            Then edit \(target) so its frontmatter has `thumbnail: ../media/generated/<same file>.png`.
            Reply with a one-line summary.
            """
        case .libraryCreate:
            """
            Create one Menu from: \(input)
            If it is a URL, fetch it and decide a short, clear name. Otherwise use it as the Menu name (fix obvious typos).
            Check existing Menus with glob menus/*.md and do not overwrite one.
            Write menus/<Name>.md with frontmatter: record (check, avoid or sets), fields if any, tags, apple-health only if it clearly fits, initial if it has fields; and a short body with the key points of form.
            Reply with the Menu name.
            """
        }
    }

    func loadConversations() {
        let dir = AppFiles.conversations
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        conversations = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Conversation.self, from: data)
        }.sorted { $0.updated > $1.updated }
    }

    func save(_ conversation: Conversation) {
        guard !conversation.messages.filter({ $0.role != .system }).isEmpty else { return }
        let url = AppFiles.conversations.appendingPathComponent(conversation.id.uuidString + ".json")
        if let data = try? JSONEncoder().encode(conversation) {
            try? data.write(to: url, options: .atomic)
        }
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updated > $1.updated }
    }

    func delete(_ conversation: Conversation) {
        try? FileManager.default.removeItem(at: AppFiles.conversations.appendingPathComponent(conversation.id.uuidString + ".json"))
        conversations.removeAll { $0.id == conversation.id }
    }
}
