import AppKit

/// XCTest runs without taking the screen from the user: no Dock icon, no activation, windows parked off-screen.
/// Opt out with `TEST_RUNNER_MDEDITOR_TEST_FOREGROUND=1 xcodebuild … test` (IME, screenshots, real-input checks).
@MainActor
enum TestBackground {
    static var isOn: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil && env["MDEDITOR_TEST_FOREGROUND"] != "1"
    }

    private static var previousApp: NSRunningApplication?

    /// Call from `applicationWillFinishLaunching`.
    static func prepare() {
        guard isOn else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.accessory)
    }

    /// Call from `applicationDidFinishLaunching`: the launch by xcodebuild activated us; give focus back.
    static func returnFocus() {
        guard isOn, let app = previousApp, app != NSRunningApplication.current else { return }
        app.activate()
    }

    /// Activates the app only in normal runs.
    static func activateApp() {
        if !isOn { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Moves the window far outside every screen (after it is ordered in, so AppKit does not constrain it back).
    static func park(_ window: NSWindow) {
        guard isOn else { return }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }
}
