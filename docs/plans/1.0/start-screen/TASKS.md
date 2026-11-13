# Start Screen Implementation Tasks

Tasks are sequential: complete each task's model and background-safe tests before starting the next. Tests use injected temporary storage and must not require a key window, menu key equivalent, Dock activation, or app activation. Do not run XCTest in the restricted sandbox; build with the repository's prescribed command and have the test runner report XCTest results.

## T1 — Add persistent recent history

- **Goal:** Implement `HistoryStore`, JSON persistence, bookmark/path records, pin ordering, 50-unpinned-item cap, remove/clear behavior, and one-time migration from `NSDocumentController` recents. Inject its location; Debug and XCTest must never use the installed app's data.
- **Files:** `Sources/HistoryStore.swift` (new), `Sources/AppDelegate.swift`, `Sources/TabStore.swift`, `Sources/MDEditorApp.swift`; `Tests/HistoryStoreTests.swift` (new).
- **Tests to add:** `HistoryStoreTests` for insert/update/deduplication, pin/unpin order, 50-item cap excluding pins, remove/clear preserving pins, JSON round-trip, missing bookmark/path retention, idempotent migration, migration cap, and injected temp-directory isolation. Model/filesystem only; no window or menu.
- **Build-for-testing filter:** `-only-testing:MDEditorTests/HistoryStoreTests`
- **Suggested reasoning effort:** high

## T2 — Persist and restore file-tab sessions

- **Goal:** Implement `SessionStore` as one JSON file with ordered file bookmarks, active file reference, and the default-off “Always reopen my tabs” flag. Add file-only snapshot/restore support to `TabStore`, preserving order and active selection while excluding Untitled tabs. Save the session only after quit preparation succeeds.
- **Files:** `Sources/SessionStore.swift` (new), `Sources/TabStore.swift`, `Sources/AppDelegate.swift`; `Tests/SessionStoreTests.swift` (new).
- **Tests to add:** `SessionStoreTests` for one-file JSON round-trip, default preference, order and active identity, exclusion of Untitled tabs, missing-file filtering and active fallback, cancelled-quit snapshot preservation, and injected temp-directory isolation. Use model objects and temporary files only.
- **Build-for-testing filter:** `-only-testing:MDEditorTests/SessionStoreTests`
- **Suggested reasoning effort:** high

## T3 — Build the SwiftUI start screen

- **Goal:** Add the start-screen presentation and interactions for New, Open, Restore, the preference checkbox, searchable Pinned/Recent sections, missing-file rows, row/context actions, and file drops. Keep visible strings English and styling aligned to `START-SCREEN.md` and `EditorPalette`.
- **Files:** `Sources/StartScreenView.swift` (new), `Sources/EditorView.swift`, `Sources/TabBarView.swift` if drop/action wiring needs it; `Tests/StartScreenViewTests.swift` (new).
- **Tests to add:** `StartScreenViewTests` for empty-history state, pin/recent grouping, pinned deduplication, case-insensitive name/path search and match ranges, missing-file state, restore-button visibility/count, and action callbacks. Prefer a view model or pure presentation model so tests do not need a key window.
- **Build-for-testing filter:** `-only-testing:MDEditorTests/StartScreenViewTests`
- **Suggested reasoning effort:** medium

## T4 — Integrate startup, recent menu, and window lifecycle

- **Goal:** Wire injected stores into app startup and the main window; show the start screen for default empty launch and Dock reopen; restore according to the saved preference; preserve incoming-file launch behavior; source Open Recent from HistoryStore; transition to the start screen after last-tab close; and make red-button close close the window while the app remains running.
- **Files:** `Sources/AppDelegate.swift`, `Sources/MainWindowController.swift`, `Sources/MDEditorApp.swift`, `Sources/EditorView.swift`, `Sources/TabStore.swift`; `Tests/StartScreenLifecycleTests.swift` (new), update `Tests/TabWindowTests.swift` and `Tests/MacConventionsTests.swift` as needed.
- **Tests to add:** `StartScreenLifecycleTests` for launch decision routing, empty-store content state, last-tab transition, red-button close policy, Dock-reopen destination, incoming URLs taking precedence as active, and shared history data for menu/screen. Keep XCTest assertions at model/controller-policy level and background-safe; actual keyboard focus and real Dock behavior are acceptance checks.
- **Build-for-testing filter:** `-only-testing:MDEditorTests/StartScreenLifecycleTests`
- **Suggested reasoning effort:** xhigh

