import Foundation
import Observation
import SelfcareCore

@Observable
final class SyncService {
    enum Trigger { case foreground, pull, manual }

    unowned let app: AppModel
    private(set) var config: SyncConfig?
    private(set) var state: SyncState
    private(set) var running = false
    var pendingPreview: SyncPreview?
    private var engine: SyncEngine?

    init(model: AppModel) {
        app = model
        state = AppFiles.load(SyncState.self, "sync-state.json") ?? SyncState()
        if let json = Keychain.get("sync.config"), let data = json.data(using: .utf8) {
            config = try? JSONDecoder().decode(SyncConfig.self, from: data)
        }
    }

    var failing: Bool { config != nil && state.lastError != nil }
    var conflicts: [SyncConflict] { state.conflicts.values.sorted { $0.path < $1.path } }

    static func provider(_ config: SyncConfig) throws -> SyncProvider {
        switch config {
        case let .webdav(c): try WebDAVProvider(config: c)
        case let .s3(c): try S3Provider(config: c)
        }
    }

    private func makeEngine() throws -> SyncEngine? {
        guard let config else { return nil }
        if let engine { return engine }
        let e = SyncEngine(vault: app.vault, provider: try Self.provider(config), state: state) { state in
            Task { @MainActor in AppFiles.save(state, "sync-state.json") }
        }
        engine = e
        return e
    }

    func connect(_ config: SyncConfig) async throws {
        let provider = try Self.provider(config)
        if let p = provider as? WebDAVProvider { try await p.testConnection() }
        if let p = provider as? S3Provider { try await p.testConnection() }
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: "sync.config")
        }
        state = SyncState()
        AppFiles.save(state, "sync-state.json")
        engine = nil
        await run(trigger: .manual)
    }

    func disconnect() {
        config = nil
        engine = nil
        pendingPreview = nil
        Keychain.set(nil, for: "sync.config")
        state = SyncState()
        AppFiles.save(state, "sync-state.json")
    }

    func run(trigger: Trigger) async {
        guard config != nil, !running else { return }
        running = true
        defer { running = false }
        do {
            guard let engine = try makeEngine() else { return }
            if engine.state.isInitial && engine.state.conflicts.isEmpty {
                if trigger != .manual && pendingPreview != nil { return }
                let preview = try await engine.preview()
                if preview.localCount > 0 && preview.remoteCount > 0 {
                    pendingPreview = preview
                    state = engine.state
                    return
                }
            }
            try await engine.sync()
            state = engine.state
            app.vaultChanged()
        } catch {
            if let engine { state = engine.state }
            state.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            AppFiles.save(state, "sync-state.json")
        }
    }

    func confirmInitial() async {
        pendingPreview = nil
        guard !running, let engine = try? makeEngine() else { return }
        running = true
        defer { running = false }
        do {
            try await engine.sync()
            state = engine.state
            app.vaultChanged()
        } catch {
            state = engine.state
            state.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func remoteText(_ path: String) async -> String? {
        guard let engine = try? makeEngine(), let data = try? await engine.remoteData(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func resolve(_ path: String, _ resolution: SyncEngine.Resolution) async {
        guard let engine = try? makeEngine() else { return }
        do {
            try await engine.resolve(path, with: resolution)
            state = engine.state
            app.vaultChanged()
        } catch {
            app.alert = error.localizedDescription
        }
    }
}
