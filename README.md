# LilaMD

<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" align="right" alt="LilaMD icon">

A small native Markdown editor for macOS. Open a `.md` file, see it formatted, and edit it right in the
formatted view — the Markdown markers of a block appear only while the cursor is in it (like Typora).

LilaMD does one thing: it opens Markdown files and edits them. It has no vault, no plugins, no sidebar and no settings.

**Version 0.5** — an early release. It works for everyday notes and docs. Read the
[known limitations](#known-limitations) before you use it on files that matter.

## Features

- **Visual mode** (Cmd+1, default): edit in the formatted view. Typing `## ` makes a heading, `- ` a list,
  `> ` a quote, ```` ``` ```` a code block. Cmd+B / Cmd+I / Cmd+K, Cmd+Z / Cmd+Shift+Z.
- **Source mode** (Cmd+2): plain Markdown in a monospaced font.
- GitHub-flavored Markdown: tables, task lists (click to check), code with syntax highlighting, links,
  images next to the file.
- **Faithful to your file**: opening and closing a file does not rewrite it. Editing one paragraph changes
  only that paragraph on disk — untouched blocks keep their original bytes.
- Double-click a `.md` in Finder, Cmd+S, autosave, Open Recent — the standard macOS document behavior.
- Picks up changes made to the file by other apps. When you have unsaved edits, it asks before it reloads.
- Light and dark mode follow the system. Works fully offline.

## Install

Requirements: macOS 14 (Sonoma) or later, Apple Silicon or Intel.

### One-line installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/drkhwo/lilamd/main/install.sh | bash
```

The script downloads the latest release to `/Applications` (or to `~/Applications` if `/Applications` is not
writable). Run it again to update.

### DMG

1. Download `LilaMD.dmg` from [Releases](https://github.com/drkhwo/lilamd/releases/latest).
2. Open it and drag **LilaMD** to **Applications**.
3. The app is not notarized by Apple, so the first launch is blocked. To allow it:
   - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to LilaMD.
   - Or run in Terminal: `xattr -dr com.apple.quarantine /Applications/LilaMD.app`

### Make LilaMD the default app for `.md`

In Finder, select any `.md` file and press **Cmd+I**. Under **Open with**, choose **LilaMD**, then click
**Change All…**.

## Usage

| Action | Keys |
|---|---|
| Visual mode / Source mode | Cmd+1 / Cmd+2 |
| Bold / Italic / Link | Cmd+B / Cmd+I / Cmd+K |
| Undo / Redo | Cmd+Z / Cmd+Shift+Z |
| Add a table row | Cmd+= (cursor in a table) |
| Open a link | Cmd+click (Visual mode) |
| Save | Cmd+S (autosave is on) |

## Known limitations

- **Tables.** When you change a cell or add a row, only that row changes on disk, but its column padding
  can shift. When you delete a row, or add a row and then edit a cell in the same session, the whole table
  is re-aligned (`|---|` becomes `| --- |`).
- **New lines you type** use the editor's formatting. For example, a new task item is written as `- [ ] item`.
- **A table at the very top of a file**: in Visual mode you cannot add text above it. Use Source mode (Cmd+2).
- **Headings**: if you select from the start of a heading line, the selection includes the hidden `# `.
  Typing over the selection turns the heading into a paragraph.
- **Large files** (thousands of lines): typing can stall for 0.2–2 s in the first 5–10 s after the file
  opens. After that, typing takes about 25–50 ms per key.
- Files must be UTF-8.

## Build from source

```bash
brew install xcodegen
git clone https://github.com/drkhwo/lilamd.git && cd lilamd
xcodegen generate
xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -configuration Release -derivedDataPath build/release build
ditto build/release/Build/Products/Release/LilaMD.app /Applications/LilaMD.app
```

- Tests: `xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -derivedDataPath build/dd test`
- Release packages (universal zip and dmg): `scripts/package.sh` → `dist/`
- Design notes and the full test record (in Russian): [docs/DEVELOPMENT.ru.md](docs/DEVELOPMENT.ru.md)

## How it works

LilaMD is a SwiftUI `DocumentGroup` app with one `WKWebView` per window. The web view runs
[Vditor](https://github.com/Vanessa219/vditor) 3.11.2 in instant-rendering mode. Vditor and all its
resources are bundled, and the page cannot reach the network. A Swift layer
(`Sources/SourcePreserver.swift`) compares each edit with the text loaded from disk. It writes back the
original bytes of every line you did not change.

## License

MIT — see [LICENSE](LICENSE). Bundled Vditor is MIT-licensed — see
[Resources/vditor/LICENSE](Resources/vditor/LICENSE).
