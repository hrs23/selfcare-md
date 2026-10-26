import CryptoKit
import Foundation

public struct RemoteItem: Sendable, Hashable {
    public var path: String
    public var version: String

    public init(path: String, version: String) {
        self.path = path
        self.version = version
    }
}

public protocol SyncProvider: Sendable {
    func list() async throws -> [RemoteItem]
    func read(_ path: String) async throws -> Data
    func write(_ path: String, _ data: Data) async throws -> String?
    func delete(_ path: String) async throws
}

public struct SyncBase: Codable, Sendable, Hashable {
    public var localHash: String
    public var remoteVersion: String
}

public struct SyncConflict: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var localDeleted: Bool
    public var remoteDeleted: Bool
}

public struct LocalHashCache: Codable, Sendable, Hashable {
    public var modified: Date
    public var size: Int
    public var hash: String
}

public struct SyncState: Codable, Sendable, Hashable {
    public var base: [String: SyncBase] = [:]
    public var conflicts: [String: SyncConflict] = [:]
    public var hashes: [String: LocalHashCache] = [:]
    public var lastSuccess: Date?
    public var lastError: String?

    public init() {}

    public var isInitial: Bool { base.isEmpty }
}

public struct SyncPreview: Sendable, Hashable {
    public var localCount: Int
    public var remoteCount: Int
    public var conflictCount: Int
}

public enum SyncHash {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public final class SyncEngine: @unchecked Sendable {
    public let vault: Vault
    public let provider: SyncProvider
    public private(set) var state: SyncState
    private let save: @Sendable (SyncState) -> Void

    public init(vault: Vault, provider: SyncProvider, state: SyncState, save: @escaping @Sendable (SyncState) -> Void) {
        self.vault = vault
        self.provider = provider
        self.state = state
        self.save = save
    }

    static func syncable(_ path: String) -> Bool {
        !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    func localFiles() -> [String: String] {
        var result: [String: String] = [:]
        var cache: [String: LocalHashCache] = [:]
        for path in vault.list() where Self.syncable(path) {
            guard let info = vault.info(path), let modified = info.modified else { continue }
            if let c = state.hashes[path], c.modified == modified, c.size == info.size {
                result[path] = c.hash
                cache[path] = c
                continue
            }
            guard let data = try? vault.readData(path) else { continue }
            let hash = SyncHash.of(data)
            result[path] = hash
            cache[path] = LocalHashCache(modified: modified, size: info.size, hash: hash)
        }
        state.hashes = cache
        return result
    }

    public func preview() async throws -> SyncPreview {
        let remote = try await provider.list().filter { Self.syncable($0.path) }
        let local = localFiles()
        var conflicts = 0
        for item in remote {
            guard let l = local[item.path] else { continue }
            let data = try await provider.read(item.path)
            if SyncHash.of(data) != l { conflicts += 1 }
        }
        return SyncPreview(localCount: local.count, remoteCount: remote.count, conflictCount: conflicts)
    }

    public func sync() async throws {
        do {
            try await run()
            state.lastSuccess = Date()
            state.lastError = nil
            save(state)
        } catch {
            state.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            save(state)
            throw error
        }
    }

    private func run() async throws {
        let remoteItems = try await provider.list().filter { Self.syncable($0.path) }
        var remote: [String: String] = [:]
        for item in remoteItems { remote[item.path] = item.version }
        let local = localFiles()
        var needsVersion: [String] = []
        let paths = Set(remote.keys).union(local.keys).union(state.base.keys).sorted()
        for path in paths {
            try Task.checkCancellation()
            let l = local[path]
            let r = remote[path]
            if state.conflicts[path] != nil {
                if let l, let r {
                    let data = try await provider.read(path)
                    if SyncHash.of(data) == l {
                        state.conflicts[path] = nil
                        state.base[path] = SyncBase(localHash: l, remoteVersion: r)
                    }
                } else if l == nil && r == nil {
                    state.conflicts[path] = nil
                    state.base[path] = nil
                }
                save(state)
                continue
            }
            guard let b = state.base[path] else {
                if let l, r == nil {
                    if let v = try await upload(path) { state.base[path] = SyncBase(localHash: l, remoteVersion: v) } else { needsVersion.append(path); state.base[path] = SyncBase(localHash: l, remoteVersion: "") }
                } else if l == nil, let r {
                    let data = try await provider.read(path)
                    try vault.writeData(path, data)
                    state.base[path] = SyncBase(localHash: SyncHash.of(data), remoteVersion: r)
                } else if let l, let r {
                    let data = try await provider.read(path)
                    if SyncHash.of(data) == l {
                        state.base[path] = SyncBase(localHash: l, remoteVersion: r)
                    } else {
                        state.conflicts[path] = SyncConflict(path: path, localDeleted: false, remoteDeleted: false)
                    }
                }
                save(state)
                continue
            }
            let localChanged = l != b.localHash
            let remoteChanged = r != b.remoteVersion
            switch (localChanged, remoteChanged) {
            case (false, false):
                break
            case (true, false):
                if let l {
                    if let v = try await upload(path) { state.base[path] = SyncBase(localHash: l, remoteVersion: v) } else { needsVersion.append(path); state.base[path] = SyncBase(localHash: l, remoteVersion: "") }
                } else {
                    if r != nil { try await provider.delete(path) }
                    state.base[path] = nil
                }
            case (false, true):
                if let r {
                    let data = try await provider.read(path)
                    try vault.writeData(path, data)
                    state.base[path] = SyncBase(localHash: SyncHash.of(data), remoteVersion: r)
                } else {
                    if l != nil { try? vault.delete(path) }
                    state.base[path] = nil
                }
            case (true, true):
                if l == nil && r == nil {
                    state.base[path] = nil
                } else if let l, let r {
                    let data = try await provider.read(path)
                    if SyncHash.of(data) == l {
                        state.base[path] = SyncBase(localHash: l, remoteVersion: r)
                    } else {
                        state.conflicts[path] = SyncConflict(path: path, localDeleted: false, remoteDeleted: false)
                    }
                } else {
                    state.conflicts[path] = SyncConflict(path: path, localDeleted: l == nil, remoteDeleted: r == nil)
                }
            }
            save(state)
        }
        if !needsVersion.isEmpty {
            let fresh = try await provider.list()
            let map = Dictionary(fresh.map { ($0.path, $0.version) }, uniquingKeysWith: { a, _ in a })
            for path in needsVersion {
                if let v = map[path] { state.base[path]?.remoteVersion = v }
            }
            save(state)
        }
        state.hashes = state.hashes.filter { vault.exists($0.key) }
    }

    private func upload(_ path: String) async throws -> String? {
        let data = try vault.readData(path)
        return try await provider.write(path, data)
    }

    public func remoteData(_ path: String) async throws -> Data? {
        guard let conflict = state.conflicts[path], !conflict.remoteDeleted else { return nil }
        return try await provider.read(path)
    }

    public enum Resolution: Sendable {
        case local
        case remote
        case merged(Data)
    }

    public func resolve(_ path: String, with resolution: Resolution) async throws {
        guard state.conflicts[path] != nil else { return }
        let remoteList = try await provider.list()
        let remoteVersion = remoteList.first { $0.path == path }?.version
        switch resolution {
        case .local:
            if vault.exists(path) {
                let data = try vault.readData(path)
                let v = try await provider.write(path, data)
                state.base[path] = SyncBase(localHash: SyncHash.of(data), remoteVersion: v ?? "")
                if v == nil { try await refreshVersion(path) }
            } else {
                if remoteVersion != nil { try await provider.delete(path) }
                state.base[path] = nil
            }
        case .remote:
            if let remoteVersion {
                let data = try await provider.read(path)
                try vault.writeData(path, data)
                state.base[path] = SyncBase(localHash: SyncHash.of(data), remoteVersion: remoteVersion)
            } else {
                try? vault.delete(path)
                state.base[path] = nil
            }
        case let .merged(data):
            try vault.writeData(path, data)
            let v = try await provider.write(path, data)
            state.base[path] = SyncBase(localHash: SyncHash.of(data), remoteVersion: v ?? "")
            if v == nil { try await refreshVersion(path) }
        }
        state.conflicts[path] = nil
        save(state)
    }

    private func refreshVersion(_ path: String) async throws {
        if let v = try await provider.list().first(where: { $0.path == path })?.version {
            state.base[path]?.remoteVersion = v
        }
    }
}
