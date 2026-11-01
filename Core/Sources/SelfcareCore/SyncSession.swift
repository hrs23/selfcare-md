import Foundation
import Observation

@MainActor
@Observable
public final class SyncSession {
    public enum Trigger: Sendable { case automatic, manual }

    public private(set) var config: SyncConfig?
    public private(set) var state: SyncState
    public private(set) var running = false
    public private(set) var pendingPreview: SyncPreview?
    @ObservationIgnored public var onVaultChange: () -> Void = {}

    @ObservationIgnored private let vault: Vault
    @ObservationIgnored private let makeProvider: (SyncConfig) throws -> SyncProvider
    @ObservationIgnored private let saveConfig: (SyncConfig?) -> Void
    @ObservationIgnored private let writer: StateWriter
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var current: (id: Int, done: Task<Void, Never>, cancel: () -> Void)?
    @ObservationIgnored private var nextID = 0

    public init(
        vault: Vault,
        config: SyncConfig?,
        state: SyncState,
        makeProvider: @escaping (SyncConfig) throws -> SyncProvider = { try $0.makeProvider() },
        saveConfig: @escaping (SyncConfig?) -> Void,
        saveState: @escaping @Sendable (SyncState) -> Void
    ) {
        self.vault = vault
        self.config = config
        self.state = state
        self.makeProvider = makeProvider
        self.saveConfig = saveConfig
        writer = StateWriter(saveState)
    }

    public var failing: Bool { config != nil && state.lastError != nil }
    public var conflicts: [SyncConflict] { state.conflicts.values.sorted { $0.path < $1.path } }

    public func run(_ trigger: Trigger) async {
        guard config != nil, current == nil else { return }
        try? await exclusive { await self.runBody(trigger) }
    }

    public func confirm() async {
        try? await exclusive {
            guard self.pendingPreview != nil else { return }
            let generation = self.writer.generation
            do {
                guard let engine = try self.makeEngine() else { return }
                self.pendingPreview = nil
                try await self.sync(engine, allowingMassDeletion: true)
            } catch {
                self.record(error, generation: generation)
            }
        }
    }

    public func connect(_ config: SyncConfig) async throws {
        try await makeProvider(config).testConnection()
        try? await replace(with: config) { await self.runBody(.manual) }
    }

    public func disconnect() async {
        try? await replace(with: nil) {}
    }

    public func resolve(_ path: String, _ resolution: SyncEngine.Resolution) async throws {
        try await exclusive {
            guard let engine = try self.makeEngine() else { throw SyncError.invalidConfig("Sync is off") }
            defer { self.state = engine.state }
            try await engine.resolve(path, with: resolution)
            self.onVaultChange()
        }
    }

    public func remoteData(_ path: String) async -> Data? {
        guard let conflict = state.conflicts[path], !conflict.remoteDeleted, let provider = try? makeEngine()?.provider else { return nil }
        return try? await provider.read(path)
    }

    private func replace(with config: SyncConfig?, then body: @escaping @MainActor () async -> Void) async throws {
        writer.invalidate()
        try await exclusive(cancelling: true) {
            self.writer.invalidate()
            self.engine = nil
            self.config = config
            self.saveConfig(config)
            self.pendingPreview = nil
            self.state = SyncState()
            self.writer.save(self.state, generation: self.writer.generation)
            await body()
        }
    }

    private func exclusive<T: Sendable>(cancelling: Bool = false, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        while let c = current {
            if cancelling { c.cancel() }
            await c.done.value
        }
        nextID += 1
        let id = nextID
        let task = Task { @MainActor in
            defer {
                if self.current?.id == id {
                    self.current = nil
                    self.running = false
                }
            }
            return try await body()
        }
        current = (id, Task { _ = try? await task.value }, { task.cancel() })
        running = true
        return try await task.value
    }

    private func runBody(_ trigger: Trigger) async {
        let generation = writer.generation
        do {
            guard let engine = try makeEngine() else { return }
            if pendingPreview != nil && trigger != .manual { return }
            if engine.state.isInitial && engine.state.conflicts.isEmpty {
                let preview = try await engine.preview()
                if preview.localCount > 0 && preview.remoteCount > 0 {
                    pendingPreview = preview
                    state = engine.state
                    return
                }
            }
            pendingPreview = nil
            try await sync(engine, allowingMassDeletion: false)
        } catch let SyncError.massDeletion(local, remote) {
            pendingPreview = SyncPreview(localCount: 0, remoteCount: 0, conflictCount: 0, localDeletions: local, remoteDeletions: remote)
        } catch {
            record(error, generation: generation)
        }
    }

    private func sync(_ engine: SyncEngine, allowingMassDeletion: Bool) async throws {
        defer {
            state = engine.state
            onVaultChange()
        }
        try await engine.sync(allowingMassDeletion: allowingMassDeletion)
    }

    private func record(_ error: Error, generation: Int) {
        if let engine { state = engine.state }
        state.lastError = error.localizedDescription
        writer.save(state, generation: generation)
    }

    private func makeEngine() throws -> SyncEngine? {
        guard let config else { return nil }
        if let engine { return engine }
        let writer = self.writer
        let generation = writer.generation
        let e = SyncEngine(vault: vault, provider: try makeProvider(config), state: state) { writer.save($0, generation: generation) }
        engine = e
        return e
    }
}

final class StateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private let write: @Sendable (SyncState) -> Void

    init(_ write: @escaping @Sendable (SyncState) -> Void) {
        self.write = write
    }

    var generation: Int { lock.withLock { current } }

    func invalidate() {
        lock.withLock { current += 1 }
    }

    func save(_ state: SyncState, generation: Int) {
        lock.withLock {
            if generation == current { write(state) }
        }
    }
}
