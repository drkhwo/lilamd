#!/bin/bash
# Makes "LilaMD" the default app for .md / .markdown (net.daringfireball.markdown).
# Changes a per-user Launch Services setting; macOS may ask for confirmation. Not run by smoke.sh.
set -euo pipefail
APP="${1:-/Applications/LilaMD.app}"
swift - "$APP" <<'SWIFT'
import AppKit
import UniformTypeIdentifiers
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let type = UTType(importedAs: "net.daringfireball.markdown")
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
    if let error { print("failed: \(error.localizedDescription)") } else { print("default for .md: \(app.path)") }
    done.signal()
}
while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
print("now opens with:", NSWorkspace.shared.urlForApplication(toOpen: type)?.path ?? "none")
SWIFT
