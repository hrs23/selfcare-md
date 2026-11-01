import Foundation
import Testing
@testable import SelfcareCore

final class SavedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [SyncState] = []

    func append(_ state: SyncState) { lock.withLock { states.append(state) } }
    var last: SyncState? { lock.withLock { states.last } }
}

final class BrokenWriteProvider: SyncProvider, @unchecked Sendable {
    let inner = MemoryProvider()

    func list() async throws -> [RemoteItem] { try await inner.list() }
    func read(_ path: String) async throws -> Data { try await inner.read(path) }
    func write(_ path: String, _ data: Data) async throws -> String? { throw SyncError.http(500, path) }
    func delete(_ path: String) async throws { try await inner.delete(path) }
}

func server(_ name: String) -> SyncConfig {
    .webdav(WebDAVConfig(url: "https://\(name).example.com/", username: "u", password: "p"))
}

@MainActor
func makeSession(_ vault: Vault, _ providers: [String: SyncProvider], connectedTo name: String, saved: SavedStates = SavedStates()) -> SyncSession {
    SyncSession(
        vault: vault,
        config: server(name),
        state: SyncState(),
        makeProvider: { config in
            guard case let .webdav(c) = config, let p = providers.first(where: { server($0.key) == .webdav(c) })?.value else { throw SyncError.badResponse }
            return p
        },
        saveConfig: { _ in },
        saveState: { saved.append($0) }
    )
}

@MainActor
struct SyncSessionTests {
    @Test func connectDuringRunStartsFreshWithPreview() async throws {
        let vault = tempVault()
        try vault.write("menus/A.md", "a")
        try vault.write("menus/B.md", "b")
        let one = GatedProvider(gated: false)
        let two = MemoryProvider()
        two.files["menus/C.md"] = Data("c\n".utf8)
        let saved = SavedStates()
        let session = makeSession(vault, ["one": one, "two": two], connectedTo: "one", saved: saved)
        await session.run(.manual)
        #expect(one.inner.files.count == 2 && session.state.base.count == 2)

        one.arm()
        let run = Task { await session.run(.manual) }
        for await _ in one.entered { break }
        try await session.connect(server("two"))
        await run.value

        #expect(session.config == server("two"))
        #expect(session.pendingPreview == SyncPreview(localCount: 2, remoteCount: 1, conflictCount: 0))
        #expect(session.state.base.isEmpty && saved.last?.base.isEmpty == true)
        #expect(vault.exists("menus/A.md") && vault.exists("menus/B.md"))

        await session.confirm()
        #expect(session.pendingPreview == nil)
        #expect(try vault.read("menus/C.md") == "c\n")
        #expect(Set(two.files.keys) == ["menus/A.md", "menus/B.md", "menus/C.md"])
        #expect(vault.exists("menus/A.md") && vault.exists("menus/B.md"))
    }

    @Test func disconnectDuringRunClearsEverything() async throws {
        let vault = tempVault()
        try vault.write("menus/A.md", "a")
        let one = GatedProvider(gated: false)
        let saved = SavedStates()
        let session = makeSession(vault, ["one": one], connectedTo: "one", saved: saved)
        await session.run(.manual)
        one.arm()
        let run = Task { await session.run(.manual) }
        for await _ in one.entered { break }
        await session.disconnect()
        await run.value
        #expect(session.config == nil && session.state.base.isEmpty && saved.last?.base.isEmpty == true)
        #expect(vault.exists("menus/A.md"))
    }

    @Test func resolveWaitsForRunningSync() async throws {
        let vault = tempVault()
        let p = GatedProvider(gated: false)
        p.inner.files["menus/A.md"] = Data("a\n".utf8)
        let session = makeSession(vault, ["one": p], connectedTo: "one")
        await session.run(.manual)
        try vault.write("menus/A.md", "local")
        p.inner.files["menus/A.md"] = Data("remote\n".utf8)
        await session.run(.manual)
        #expect(session.conflicts.map(\.path) == ["menus/A.md"])

        p.arm()
        let run = Task { await session.run(.manual) }
        for await _ in p.entered { break }
        let resolving = Task { try await session.resolve("menus/A.md", .local) }
        await Task.yield()
        p.releaseContinuation.yield()
        await run.value
        try await resolving.value
        #expect(session.conflicts.isEmpty)
        #expect(p.inner.files["menus/A.md"] == Data("local\n".utf8))
    }

    @Test func failedResolveThrowsAndKeepsConflict() async throws {
        let vault = tempVault()
        let p = BrokenWriteProvider()
        p.inner.files["menus/A.md"] = Data("remote\n".utf8)
        try vault.write("menus/A.md", "local")
        let session = makeSession(vault, ["one": p], connectedTo: "one")
        await session.run(.manual)
        #expect(session.pendingPreview != nil)
        await session.confirm()
        #expect(session.conflicts.map(\.path) == ["menus/A.md"])
        await #expect(throws: SyncError.http(500, "menus/A.md")) { try await session.resolve("menus/A.md", .local) }
        #expect(session.conflicts.map(\.path) == ["menus/A.md"])
    }

    @Test func confirmWhileRunningKeepsPreview() async throws {
        let vault = tempVault()
        try vault.write("menus/A.md", "a")
        let p = GatedProvider(gated: false)
        p.inner.files["menus/B.md"] = Data("b\n".utf8)
        let session = makeSession(vault, ["one": p], connectedTo: "one")
        await session.run(.automatic)
        #expect(session.pendingPreview == SyncPreview(localCount: 1, remoteCount: 1, conflictCount: 0))

        p.arm()
        let run = Task { await session.run(.manual) }
        for await _ in p.entered { break }
        let confirming = Task { await session.confirm() }
        await Task.yield()
        #expect(session.pendingPreview != nil)
        p.releaseContinuation.yield()
        await run.value
        await confirming.value
        #expect(session.pendingPreview == nil)
        #expect(try vault.read("menus/B.md") == "b\n")
        #expect(p.inner.files["menus/A.md"] == Data("a\n".utf8))
    }
}
