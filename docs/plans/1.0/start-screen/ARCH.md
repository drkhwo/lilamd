# Start Screen Architecture

## Current code paths

Line numbers refer to the current tree and will move as implementation lands.

| Concern | Current path | Change |
|---|---|---|
| Default launch without files | [AppDelegate.swift:40-48](../../../../Sources/AppDelegate.swift#L40) checks `launchIsDefaultUserInfoKey`, then calls `openDocument()`; [AppDelegate.swift:91-101](../../../../Sources/AppDelegate.swift#L91) presents `NSOpenPanel`. | A default launch with no incoming URLs should show the main window with `StartScreenView`. Keep the launch-event distinction so a Finder/open URL launch never flashes the start screen. |
| Dock reopen | [AppDelegate.swift:52-55](../../../../Sources/AppDelegate.swift#L52) calls `openDocument()` when there are no tabs. | Reopen the main window on the start screen when it has no tabs; show its existing tabs otherwise. |
| Last-tab close | [MainWindowController.swift:80-88](../../../../Sources/MainWindowController.swift#L80) handles Close Tab; [MainWindowController.swift:115-127](../../../../Sources/MainWindowController.swift#L115) handles the red close button; [MainWindowController.swift:150-155](../../../../Sources/MainWindowController.swift#L150) hides the window when `store.order` empties. | Keep the window and replace the editor body with the start screen after the last tab closes. The red button closes the window after the existing sequential close/save flow; the app remains running. |
| Main-window content | [MainWindowController.swift:24-29](../../../../Sources/MainWindowController.swift#L24) hosts `TabbedWindow`; [EditorView.swift:47-79](../../../../Sources/EditorView.swift#L47) always builds the tab strip and editor stack. | Make the central content conditional on whether there are tabs. Preserve the window and menu/toolbar ownership. Add `StartScreenView` as a SwiftUI view in the no-tabs branch. |
| Open Recent | [MDEditorApp.swift:35](../../../../Sources/MDEditorApp.swift#L35) installs `OpenRecentMenu`; [MDEditorApp.swift:89-115](../../../../Sources/MDEditorApp.swift#L89) implements `RecentDocuments` against `NSDocumentController`; [MDEditorApp.swift:118-131](../../../../Sources/MDEditorApp.swift#L118) renders the menu; [AppDelegate.swift:103-108](../../../../Sources/AppDelegate.swift#L103) opens and refreshes a recent URL. | Replace the system-only source with `HistoryStore`. The menu and start screen must read and mutate the same pinned/recent records. “Clear Menu” clears unpinned recent records and preserves pinned records. |
| Record file opens/saves | [TabStore.swift:36-51](../../../../Sources/TabStore.swift#L36) opens a URL and records a recent; [TabStore.swift:140-156](../../../../Sources/TabStore.swift#L140) records successful saves and Save As; [TabStore.swift:268-271](../../../../Sources/TabStore.swift#L268) calls `RecentDocuments.shared`. | Inject a history dependency and update `lastOpened` for a successful open. Save As updates/adds the target record. Do not persist failed opens or Untitled tabs. |
| Tab order and close | [TabStore.swift:5-28](../../../../Sources/TabStore.swift#L5) owns `order` and `activeID`; [TabStore.swift:85-97](../../../../Sources/TabStore.swift#L85) adds tabs; [TabStore.swift:131-136](../../../../Sources/TabStore.swift#L131) reorders; [TabStore.swift:169-193](../../../../Sources/TabStore.swift#L169) closes; [TabStore.swift:255-266](../../../../Sources/TabStore.swift#L255) removes tabs and chooses the next active tab. | Add a snapshot/restore boundary that serializes file tabs in `order` and the active file tab. Exclude Untitled tabs. Keep the existing tab identity, editor lifecycle, and close/save semantics. |
| Test isolation | [AppDelegate.swift:13-14,29-33](../../../../Sources/AppDelegate.swift#L13) disables system recents under XCTest and supports a Debug opt-out; [TestBackground.swift](../../../../Sources/TestBackground.swift) keeps XCTest inactive. | Inject storage URLs. XCTest always uses a fresh temporary directory; Debug uses a separate location from the installed app. Never let tests or Debug read or write the installed app's history/session files. |

## Design

### Storage boundary

- Add `HistoryStore` as the single source of truth for the start-screen list and File ▸ Open Recent. Persist it as JSON in Application Support. Each entry contains bookmark data, a last-known display path, `lastOpened`, and `pinned`; preserve pin order explicitly.
- Keep at most 50 unpinned entries, newest first. Pinned entries do not count toward the cap and do not appear again in Recent. Removing a recent or clearing the menu never removes a pin.
- Migrate `NSDocumentController.shared.recentDocumentURLs` once on first store creation. Resolve or create bookmarks where possible, deduplicate URLs, retain the newest entries within the cap, and record migration completion only after the imported store is safely written. Repeated launches must not re-import or reorder the user's curated list.
- Add `SessionStore` with one human-readable JSON file containing the ordered file-tab bookmarks, the active tab reference, and the “Always reopen my tabs” boolean. Save only file-backed tabs; Untitled tabs are deliberately omitted. Keep the preference in this file so the session has one inspectable representation.
- Both stores take an injected storage location/URL and filesystem dependencies where needed. Production Release resolves to the app's Application Support directory. Debug resolves to a distinct Debug directory; XCTest uses a fresh temporary directory. Tests must assert the injected URL is the one used. This avoids Debug's shared bundle identifier touching installed-app data.
- Store bookmark data and a display path separately: the path supports useful names and “not found” rows if bookmark resolution fails. Keep bookmark resolution behind a small boundary so the planned App Store security-scoped bookmark/access work can be added without coupling SwiftUI to it. The current non-sandboxed build does not start security-scoped access.

### Session behavior

- `TabStore` exposes an ordered, file-only session snapshot and a restore operation that accepts resolved URLs plus the active file identity. The store remains responsible for deduplication, ordering, and activation.
- On a successful app termination, persist the current file tabs in tab-bar order and active selection after the existing `prepareToQuit()` flow succeeds. A cancelled quit must not replace the last good session. Persist the reopen preference with the snapshot.
- With the preference off (default), launch shows the start screen and offers “Restore last session · N tabs” if at least one saved file still resolves. With it on, restore on launch. When launch also supplies file URLs, restore prior tabs first and make the incoming file active. Skip missing files and report one aggregate “N files not found” result.
- The restore button is hidden if no saved file resolves. A partial restore preserves surviving order and selects the saved active tab if it survived; otherwise select the last successfully restored tab.

### Start screen and window lifecycle

- `StartScreenView` is SwiftUI content inside the existing main window, shown whenever `TabStore` has no tabs. Keep the current tab strip area empty and use the specified editor palette, centered ~560 pt content, and English, user-facing copy.
- The screen owns New, Open…, Restore, the preference checkbox, search, Pinned/Recent rows, context actions, missing-file state, and `.md` drop handling as described in `START-SCREEN.md`. Model filtering, highlighted match ranges, list selection, and commands so they can be tested without an active/key window.
- Closing the last tab transitions the same window to the start screen. Pressing the red close button runs the existing sequential save/close flow, then really closes the window; it does not terminate the app. Dock reopen with no visible window shows the start screen. A window closed while it still had tabs must not silently discard its session snapshot; the existing close flow remains responsible for resolving those tabs.
- A default no-file launch creates/shows the start-screen window without an Open panel. File URLs delivered at launch go directly through `MainWindowController.open` and show the editor. Keep `applicationShouldHandleReopen` as the Dock entry point, updating only its empty-store behavior.
- File ▸ Open Recent uses the same `HistoryStore` rows and open action. Opening a missing bookmark should use the existing open-error presentation and keep the record visibly missing until the user removes it; Show in Finder is only enabled for a resolvable file.

## Risks and decisions to preserve

- **Storage isolation:** Debug and XCTest share the product bundle ID with the installed app. A default `Application Support/LilaMD` URL in either mode would leak or mutate production user data. Require injected locations and test this boundary.
- **Bookmark lifetime and permissions:** Files can move, disappear, or lose access. Keep the last-known path, treat bookmark resolution as fallible, and do not silently delete an entry. Security-scoped bookmarks are a later sandbox-phase dependency.
- **Migration correctness:** System recents may contain duplicates, missing files, or more than 50 entries. Make migration one-time, deterministic, capped, and safe to retry after a failed write.
- **Session write timing:** An async quit can be cancelled after save prompts. Write the session only after `prepareToQuit()` returns success; otherwise preserve the previous snapshot. Test active-tab fallback when the saved active file disappears.
- **Open-at-launch race:** Finder/open URLs can be delivered around finish-launch. Continue distinguishing default launch from document launch and ensure no transient start screen or Open panel is presented for URL launches.
- **Window lifecycle:** Current empty-store observation hides the window and current red-button handling never closes it. Ensure the new empty view and actual window close do not fight each other or create a hidden empty window that Dock reopen fails to show.
- **SwiftUI/AppKit focus:** Search shortcuts and row keyboard navigation can depend on key-window behavior. Keep model/view tests background-safe; reserve actual key-equivalent and Dock behavior for foreground/manual checks.
- **History/session consistency:** A successful file open should update HistoryStore once even when the URL is already open; restore and batch-open must not create duplicate rows or reorder tabs unexpectedly.

