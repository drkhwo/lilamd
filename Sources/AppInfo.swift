import AppKit

/// Web addresses of the project: About credits and the Help menu.
enum AppLinks {
    static let repo = URL(string: "https://github.com/drkhwo/lilamd")!
    static let issues = URL(string: "https://github.com/drkhwo/lilamd/issues")!

    /// Help menu items, in menu order.
    static let help: [(title: String, url: URL)] = [
        ("LilaMD on GitHub", repo),
        ("Report an Issue", issues),
    ]
}

/// LilaMD ▸ About LilaMD: the standard panel with the build's commit and a link to the project.
enum AboutPanel {
    /// `info`: the app's Info.plist. Version line: "<CFBundleShortVersionString> (<MDEGitCommit>)".
    static func options(info: [String: Any]) -> [NSApplication.AboutPanelOptionKey: Any] {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info["MDEGitCommit"] as? String ?? "unknown"
        let credits = NSMutableAttributedString(string: AppLinks.repo.absoluteString, attributes: [
            .link: AppLinks.repo,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
        return [
            .applicationVersion: "\(version) (\(commit))",
            // Empty: no second "(CFBundleVersion)" after the line above.
            .version: "",
            .credits: credits,
        ]
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options(info: Bundle.main.infoDictionary ?? [:]))
    }
}

/// The LilaMD menu. SwiftUI leaves two separators around the empty Settings slot; the second one is hidden,
/// not removed, so SwiftUI's own updates of the menu still find every item it made.
@MainActor
enum AppMenu {
    static func hideDoubleSeparators(_ menu: NSMenu?) {
        guard let menu else { return }
        var previousVisible: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem, previousVisible?.isSeparatorItem ?? true {
                item.isHidden = true // also a separator at the very top
                continue
            }
            if !item.isHidden { previousVisible = item }
        }
    }

    /// Now and whenever SwiftUI adds items to the app menu.
    static func install() {
        hideDoubleSeparators(NSApp.mainMenu?.items.first?.submenu)
        // Any menu: the check is a few items long, and the app menu may be rebuilt as a new object.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideDoubleSeparators(NSApp.mainMenu?.items.first?.submenu) }
        }
    }
}
