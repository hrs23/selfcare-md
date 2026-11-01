import Foundation
import SelfcareCore

extension SyncSession {
    convenience init(app: AppModel) {
        let config = Keychain.get("sync.config").flatMap { try? JSONDecoder().decode(SyncConfig.self, from: Data($0.utf8)) }
        self.init(
            vault: app.vault,
            config: config,
            state: AppFiles.load(SyncState.self, "sync-state.json") ?? SyncState(),
            saveConfig: { config in
                let json = config.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                Keychain.set(json, for: "sync.config")
            },
            saveState: { AppFiles.save($0, "sync-state.json") }
        )
        onVaultChange = { [unowned app] in app.vaultChanged() }
    }
}
