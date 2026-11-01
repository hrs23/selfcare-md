import Foundation

public final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: Data?] = [:]
    public let vault: Vault

    public init(vault: Vault) {
        self.vault = vault
    }

    public func record(_ path: String) throws {
        try lock.withLock {
            if originals.keys.contains(path) { return }
            if vault.exists(path) {
                guard let data = try? vault.readData(path) else { throw ToolError.message("Cannot read \(path), so it was not changed") }
                originals[path] = .some(data)
            } else {
                originals[path] = .some(nil)
            }
        }
    }

    public func created(_ path: String) -> Bool {
        lock.withLock {
            guard let original = originals[path] else { return false }
            return original == nil
        }
    }

    public var snapshot: [String: Data?] {
        lock.withLock { originals }
    }
}
