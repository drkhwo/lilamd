import Foundation

enum EditorMode: String, CaseIterable {
    case visual
    case source
}

/// Last chosen mode, stored in UserDefaults (the app reads it through `@AppStorage(EditorModePreference.key)`).
enum EditorModePreference {
    static let key = "editorMode"

    static func load(from defaults: UserDefaults = .standard) -> EditorMode {
        defaults.string(forKey: key).flatMap(EditorMode.init(rawValue:)) ?? .visual
    }

    static func save(_ mode: EditorMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
