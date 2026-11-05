import Foundation

/// Text zoom shared by all editors, stored in UserDefaults (the app reads it through `@AppStorage(ZoomPreference.key)`).
enum ZoomPreference {
    static let key = "editorZoom"
    static let defaultValue = 1.0
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.5]

    static func load(from defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return snap(defaults.double(forKey: key))
    }

    static func save(_ zoom: Double, to defaults: UserDefaults = .standard) {
        defaults.set(snap(zoom), forKey: key)
    }

    static func snap(_ zoom: Double) -> Double {
        steps.min { abs($0 - zoom) < abs($1 - zoom) } ?? defaultValue
    }

    static func next(after zoom: Double) -> Double? {
        steps.first { $0 > zoom + 0.000001 }
    }

    static func previous(before zoom: Double) -> Double? {
        steps.last { $0 < zoom - 0.000001 }
    }

    static func label(_ step: Double) -> String { "\(Int((step * 100).rounded())) %" }
}
