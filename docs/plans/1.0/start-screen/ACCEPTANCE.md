# Start Screen Acceptance Criteria

**Priority:** M = must; S = should. **Check:** XCT = XCTest, background-safe unless stated; FG = foreground app check; MAN = manual product/visual check.

| ID | Priority | Check | Criterion |
|---|---|---|---|
| SS-1 | M | XCT | A default launch with no file URLs selects the empty start-screen state and does not request an Open panel. |
| SS-2 | M | FG | Opening a Markdown file from Finder or `open` goes straight to its tab; the start screen does not flash first. |
| SS-3 | M | XCT | New, Open…, Restore, search, row selection/open, removal, pin/unpin, and `.md` drop actions dispatch the expected callbacks without requiring an active key window in model/view tests. |
| SS-4 | M | MAN | The empty-history screen shows the primary actions and drop hint without empty Pinned/Recent headings; populated screen follows the specified centered layout and editor palette. |
| SS-5 | S | FG | Search accepts ⌘F, filters names and paths without case sensitivity, highlights matches, and Esc clears the query. |
| SS-6 | S | MAN | Missing recent files render muted with “not found”; opening offers removal confirmation, and Show in Finder is unavailable. |
| HIS-1 | M | XCT | A successfully opened file is represented by bookmark data, last-known display path, last-opened date, and pin state; repeated opens update rather than duplicate it. |
| HIS-2 | M | XCT | History survives JSON reload; at most 50 unpinned items remain, ordered newest first, while pinned items do not count toward the cap. |
| HIS-3 | M | XCT | Pins appear in pin order, are excluded from Recent duplicates, and survive Remove Recent and Clear Menu. |
| HIS-4 | M | XCT | First-run migration imports/deduplicates system recents once, applies the 50-item cap, and does not re-run after a successful write. |
| HIS-5 | M | XCT | Stores use injected locations; XCTest uses temporary storage and Debug storage is distinct from installed-app storage. No test or Debug run reads/writes installed history. |
| HIS-6 | S | FG | File ▸ Open Recent shows the same records and actions as the start-screen history. |
| SES-1 | M | XCT | Session JSON is one file containing ordered file-tab bookmarks, active-file identity, and the “Always reopen my tabs” flag, default off. |
| SES-2 | M | XCT | Session snapshots exclude Untitled tabs and preserve surviving tab order and active tab; if the saved active tab is missing, the last restored file becomes active. |
| SES-3 | M | XCT | Cancelled quit leaves the last successful session snapshot unchanged; a successful quit writes the current file-tab snapshot. |
| SES-4 | M | XCT | Restore skips missing files, reports one aggregate missing-file count, and the Restore button is hidden when no saved file resolves. |
| SES-5 | M | FG | With the preference off, startup offers Restore; with it on, startup restores automatically. Incoming launch files are included and become active. |
| WIN-1 | M | XCT | Closing the last tab leaves the existing main window showing the start screen. |
| WIN-2 | M | FG | The red close button closes the window after normal tab save/close handling; the application remains running. |
| WIN-3 | M | FG | Clicking the Dock icon after the window closes reopens the main window on the start screen when no tabs are open. |
| WIN-4 | M | XCT | Reopening through Dock policy with existing tabs shows the existing session/window rather than creating an Open panel. |
| REG-1 | M | XCT | Existing tab open/close, save prompts, active-tab selection, reordering, and file-open error behavior remain intact. |
| REG-2 | M | BUILD | `xcodegen generate && xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -derivedDataPath build/dd build-for-testing` succeeds. |
| REG-3 | M | FG | Background test suite and foreground acceptance suite pass; tests needing key-window/menu equivalents call `requireForeground()` before interaction. |
| REG-4 | S | MAN | Provide light and dark screenshots of populated and empty-history states for product review. |

