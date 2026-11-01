import Foundation
import Observation
import SelfcareCore

enum QuickKind: String, CaseIterable, Identifiable {
    case dayPlan, menuTidy, menuImage, libraryCreate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dayPlan: "Plan with AI"
        case .menuTidy: "Tidy up with AI"
        case .menuImage: "Create image"
        case .libraryCreate: "Create Menu with AI"
        }
    }
}

@Observable
final class Settings {
    var prefs: Preferences {
        didSet { if canSave { AppFiles.save(prefs, "preferences.json") } }
    }

    @ObservationIgnored private let canSave: Bool

    init() {
        let loaded = Preferences.load(from: AppFiles.support.appendingPathComponent("preferences.json"))
        prefs = loaded.preferences
        canSave = loaded.canSave
    }
}
