# LilaMD 0.6–0.7: архитектура

Источник: `docs/plans/0.6-0.7-PLAN.md`. Критерии: `docs/plans/0.6-0.7/ACCEPTANCE.md`.
Доказательства (логи и скрипты проб): `~/dev/QA/2026-11-04-lilamd-0.6-0.7/arch/`.

## 0. Факты, проверенные пробами

Пробы запускались 04.11 на macOS 26.6.2 (25G83), сборка Debug из этого worktree (`build/dd`), не из `/Applications`.

| # | Вопрос | Результат | Лог |
|---|---|---|---|
| P1 | Какой класс документа даёт `DocumentGroup` | `PlatformDocument_1` (SwiftUI) | `arch-doc-policy-probe.log` |
| P2 | Автосохранение | `autosavesInPlace = YES` | там же |
| P3 | Versions | `preservesVersions = YES` | там же |
| P4 | Черновики Untitled | `autosavesDrafts = YES` | там же |
| P5 | Окно при запуске без файла | панель Open (окно с заголовком `Open`) | там же |
| P6 | Меню File сейчас | New ⌘N, Open… ⌘O, Open Recent, Close ⌘W, Close All, Save ⌘S, Save As…, Duplicate (⇧⌘S), Rename…, Move To…, Revert To Saved, Revert To, Share | `arch-menu-probe.log` |
| P7 | Кто первым получает ⌘-клавишу: меню или страница WKWebView | Меню. ⌘= и ⌘Z ушли в меню, страница их не увидела, хотя `preventDefault` на `KeyZ` стоял | `arch-keyorder-probe.log` |
| P8 | ⌘= при **неактивном** пункте меню | Не дошло ни до меню, ни до страницы | там же |
| P9 | ⇧⌘= и ⌥⌘= при пункте `"="` + `.command` | Меню не взяло (`performKeyEquivalent` = false). Страница получила: ⇧⌘= → `key="+"` или `"="` (зависит от `characters` события), `code=Equal`; ⌥⌘= → `key="≠"`, `code=Equal`, `altKey=true` | там же |
| P10 | `pageZoom` | `clientWidth` страницы 900 → 600 при `pageZoom = 1.5`. Масштаб применяется к CSS-пикселям, как в Safari | там же |

Ограничения проб:
- Пробы P7–P10 — отдельное AppKit-приложение с `NSMenuItem`, не SwiftUI `.keyboardShortcut`. SwiftUI строит такие же `NSMenuItem`, но это надо подтвердить тестом в `Round4Tests` (раздел 3).
- macOS 14 не проверялся: машины с 14 нет. `WKWebView.pageZoom` есть с macOS 11.0 (документация Apple), deployment target 14.0.
- События в пробах синтетические (`NSEvent.keyEvent`). Что даёт настоящая клавиатура для ⇧⌘= (`characters` = `"+"` или `"="`), не проверено (см. 1.5).

---

## 1. Масштаб (0.6, релиз R2)

### 1.1 Механизм

`WKWebView.pageZoom`. Без JS, работает в обоих режимах Vditor, масштабирует шрифт и отступы (P10).
Ставится на каждый `WKWebView`. Сохраняется ли значение после перезагрузки страницы (`webViewWebContentProcessDidTerminate`), не проверено. Если нет — `setZoom` повторяется в обработчике `ready`.

### 1.2 `Sources/Zoom.swift` (новый)

```swift
/// Text zoom shared by all editors, stored in UserDefaults (the app reads it through `@AppStorage(ZoomPreference.key)`).
enum ZoomPreference {
    static let key = "editorZoom"
    static let defaultValue = 1.0
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.5]

    static func load(from defaults: UserDefaults = .standard) -> Double   // snapped; 1.0 if missing
    static func save(_ zoom: Double, to defaults: UserDefaults = .standard)
    /// Nearest step (values written by hand, e.g. 1.05, are snapped).
    static func snap(_ zoom: Double) -> Double
    /// Next step above `zoom`, nil at 1.5.
    static func next(after zoom: Double) -> Double?
    /// Next step below `zoom`, nil at 0.8.
    static func previous(before zoom: Double) -> Double?
    static func label(_ step: Double) -> String   // "110 %"
}
```

ACCEPTANCE Z-2 пишет `next(1.5) == 1.5`. Здесь `next` возвращает `nil` на краю: так пункт меню проще сделать неактивным. Тест Z-2 надо писать под `nil`.

### 1.3 Меню (`MDEditorApp.swift`)

```swift
@AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue
...
.commands {
    // existing CommandGroup(replacing: .undoRedo) and CommandGroup(before: .toolbar) { Visual, Source } stay
    CommandGroup(after: .toolbar) {
        Button("Zoom In") { zoom = ZoomPreference.next(after: zoom) ?? zoom }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(ZoomPreference.next(after: zoom) == nil)
        Button("Zoom Out") { zoom = ZoomPreference.previous(before: zoom) ?? zoom }
            .keyboardShortcut("-", modifiers: .command)          // ASCII hyphen, not U+2212
            .disabled(ZoomPreference.previous(before: zoom) == nil)
        Button("Actual Size") { zoom = ZoomPreference.defaultValue }
            .keyboardShortcut("0", modifiers: .command)
        Menu("Zoom") {
            ForEach(ZoomPreference.steps, id: \.self) { step in
                Toggle(ZoomPreference.label(step), isOn: Binding(
                    get: { ZoomPreference.snap(zoom) == step }, set: { _ in zoom = step }))
            }
        }
        Divider()
    }
}
```

- Пункты встают в меню View после Visual/Source (сейчас в View только они, P6).
- Неактивный пункт на краю безопасен: ⌘= не доходит до страницы (P8), строка таблицы не добавится. Подтвердить тестом (раздел 3, `testCmdEqualsAtMaxZoomDoesNothing`).
- ⌘0 Vditor не использует (`grep '"⌘0"' index.js` пусто).
- Подсказка про ⌥⌘= — в README и `DEVELOPMENT.ru.md` (Z-18). Отдельного пункта меню не делаем.

### 1.4 Поток значения до каждого `EditorController`

Источник правды — `UserDefaults` (`editorZoom`). Все читатели — `@AppStorage`, поэтому смена в одном месте обновляет все окна.

0.6 (ещё `DocumentGroup`):
1. `DocumentWindow`: `@AppStorage(ZoomPreference.key) var zoom`, передаёт `ZoomPreference.snap(zoom)` в `EditorView(zoom:)`.
2. `EditorView.makeNSView`: `controller.setZoom(zoom)` сразу после создания (до загрузки страницы).
3. `EditorView.updateNSView`: `controller.setZoom(zoom)`.
4. `EditorController`:
   ```swift
   private(set) var zoom = 1.0
   /// Native page zoom (fonts and paddings, both modes). Kept by WKWebView across page reloads.
   func setZoom(_ newZoom: Double) {
       guard newZoom != zoom else { return }
       zoom = newZoom
       webView.pageZoom = newZoom
   }
   ```

0.7 (табы): `TabbedWindow` читает `@AppStorage` и передаёт `zoom` в `EditorView` каждого таба. Скрытые табы тоже получают значение (дёшево). Новый таб получает его при создании WebView.

### 1.5 Хоткеи Vditor: что занято, как сравнивается

`index.html` грузит `index.min.js`. Строки ниже — по `index.js` той же версии (`"⇧⌘="` и логика `Digit/Key` есть в обоих файлах).

`isCtrl(event)` (`index.js:4189`): на Mac = `metaKey && !ctrlKey`.

`matchHotKey(hotKey, event)` (`index.js:5552`):
- Хоткей без ⌘/⇧/⌥ — сравнение по `event.code`.
- Хоткей с `⌥` (`⌥X`, `⌥⌘X`) — по `event.code === "Digit"+X` или `"Key"+X`. Для `=` и `-` это `"Key="`, такого кода нет. Значит, `⌥⌘=` / `⌥⌘-` Vditor совпасть не могут в принципе.
- `⌘X` / `⇧⌘X` — по `event.key.toLowerCase()`, плюс `!event.altKey` и точное совпадение `shiftKey`. На Mac `=`→`+` не подменяется (подмена только в Firefox и не на Mac).

Отдельные проверки в общем обработчике keydown (`index.js:8880`): `⌥⌘1–6` (уровень заголовка) и `⌥⌘7–9` (смена режима Vditor). Обе — по `Digit`, `=`/`-` не задевают. Другого кода с `altKey` + `Equal/Minus` нет.

Кто использует ⌘= / ⌘−:
- таблица: `⌘=` строка ниже, `⌘-` удалить строку (`index.js:10631`, `10649`);
- заголовок в IR: уровень выше/ниже (`index.js:5804`, `5813`); в WYSIWYG — `6919`, `6929` (режим не используется).

Вывод: ⌥⌘= и ⌥⌘− в Vditor свободны. Обработчик Vditor не проверяет `isTrusted` (`grep isTrusted index.js` пусто), поэтому синтетическое событие он примет.

⇧⌘= (добавить колонку): Vditor ждёт `event.key === "="`. По P9 страница получает `key` из `characters` события. Если настоящая клавиатура даёт `"+"`, колонка не добавляется **уже в 0.5.1**. Это надо проверить вручную на 0.5.1 до R2. Если не работает и сейчас — это не регрессия R2, записать в «Известные ограничения».

### 1.6 Шим в `editor.js`

Место: верхний уровень IIFE, рядом с обработчиком `click`, до `window.mdeditor`. Не в `speedUp`: `speedUp` вызывается на каждый новый экземпляр Vditor, слушатель на `document` размножился бы.

```js
  // Cmd+= / Cmd+- belong to View > Zoom: the menu takes them before the page. Vditor's own Cmd+= / Cmd+-
  // (table: add / delete row; heading: level up / down) move to Opt+Cmd+= / Opt+Cmd+-, re-sent here as
  // the keys Vditor matches. Matched by event.code: with Option, macOS reports event.key as "≠" / "–".
  document.addEventListener("keydown", (e) => {
    if (!e.isTrusted || !e.metaKey || !e.altKey || e.ctrlKey || e.shiftKey) return;
    if (e.code !== "Equal" && e.code !== "Minus") return;
    e.preventDefault();
    e.stopImmediatePropagation();
    e.target.dispatchEvent(new KeyboardEvent("keydown", {
      key: e.code === "Equal" ? "=" : "-", code: e.code, metaKey: true,
      bubbles: true, cancelable: true, composed: true,
    }));
  }, true);
```

Почему так:
- Слушатель в фазе capture на `document` срабатывает раньше всех слушателей на элементе редактора, в том числе capture-слушателей из `speedUp`.
- `e.target` — элемент с фокусом (`vditor.ir.element` или `vditor.sv.element`). Событие всплывает до обработчика Vditor на этом элементе. `getSelection()` не меняется, Vditor берёт ту же каретку.
- `!e.isTrusted` отсекает наше же синтетическое событие. Оно и так без `altKey`, но так явнее.
- ⇧ не трогаем: ⇧⌘= / ⇧⌘− идут в Vditor как есть (меню их не берёт, P9).
- Остальные document-слушатели `editor.js` на `metaKey` выходят сразу (замер задержки), поэтому синтетическое событие их не задевает.
- Защищать обычный ⌘= на странице не нужно: и активный, и неактивный пункт меню забирают его раньше страницы (P7, P8). Если тест `testCmdEqualsAtMaxZoomDoesNothing` упадёт на SwiftUI-меню, добавить в шим ветку: обычный ⌘= / ⌘− → только `stopImmediatePropagation()` без `preventDefault()`, чтобы WebKit вернул событие в меню.

### 1.7 Как проверить, что ⌘= не забирает ⇧⌘=

Три проверки в `Round4Tests`, все в процессе тестового хоста (меню там — настоящее меню `MDEditorApp`):
1. Найти пункт: `NSApp.mainMenu` → View → `Zoom In`. `keyEquivalent == "="`, `keyEquivalentModifierMask == [.command]`.
2. `NSApp.mainMenu!.performKeyEquivalent(with: e)` для ⇧⌘= (`characters "+"`, `ignoring "+"`, keyCode 24) и для варианта `characters "="` → `false`. Для ⌥⌘= (`"≠"`, `ignoring "="`) → `false`. Для ⌘= → `true` (затем вернуть `editorZoom`).
3. Через `h.key` в ячейке таблицы: ⇧⌘= не меняет `editorZoom`. Добавилась ли колонка — записать как наблюдение (см. 1.5).

Вручную (R2): на раскладках U.S. и RussianWin нажать ⌘=, ⇧⌘=, ⌥⌘= в ячейке. Результат смотреть по diff файла после ⌘S.

### 1.8 Файлы R2

`Sources/Zoom.swift` (новый), `Sources/MDEditorApp.swift`, `Sources/EditorView.swift` (`zoom` в `EditorView` и `DocumentWindow`), `Sources/EditorController.swift` (`setZoom`), `Resources/web/editor.js` (шим), `Tests/Support.swift` (параметр `ignoringModifiers` у `key`), `Tests/Round3Tests.swift` (⌘= → ⌥⌘=), `Tests/Round4Tests.swift`, README, `docs/DEVELOPMENT.ru.md`.

---

## 2. Табы (0.7, релиз R3)

### 2.1 Что даёт `DocumentGroup` сейчас и что решаем

| Функция | 0.5.1, факт | 0.7, решение |
|---|---|---|
| Автосохранение на место | Есть (P2). Закрытие окна с правками не спрашивает, файл пишется | **Сохраняем, делаем сами.** Запись через 2 с после последней правки, при уходе из приложения, при закрытии таба и при выходе |
| Вопрос «Сохранить?» для файла с путём | Нет (следствие автосохранения) | Нет. Вопрос только если запись не удалась |
| Untitled | Черновик хранит система (P4) | Своего хранения нет. Закрытие или выход с текстом в Untitled → Save / Don't Save / Cancel. ⌘S в Untitled → панель Save As |
| Versions (Revert To, Browse All Versions) | Есть (P3, P6) | **Отказываемся.** Пункты пропадают. Откат — Time Machine или git. Запись в README |
| Rename… / Move To… / Duplicate / Revert To Saved | Есть в меню File (P6) | **Отказываемся** в MVP. Взамен Reveal in Finder в контекстном меню таба. Proxy-иконка и ⌘-клик по заголовку остаются (`representedURL`) |
| Переименование кликом по заголовку окна | Не проверял на экране. Для `autosavesInPlace` AppKit его даёт | Нет |
| Проверка «файл изменился на диске» перед записью | Делает `NSDocument` | Своя: байты на диске сравниваются с последними прочитанными или записанными |
| Запуск без файла | Панель Open (P5) | Панель Open, как сейчас |
| Закрытие последнего окна | Приложение остаётся запущенным (умолчание AppKit, `DocumentGroup` его не меняет; на экране не проверял) | Так же |
| Open Recent | Системный | Своё подменю из `NSDocumentController.shared.recentDocumentURLs` |
| Размер окна | 1100×800, восстановление — системой | 1100×800 при каждом создании окна |
| Отмена правок до исходного текста | Окно остаётся «изменённым», автосохранение пишет те же байты (`DEVELOPMENT.ru.md`, п. 6) | Таб чистый, записи нет, mtime не меняется |

Расхождение с ACCEPTANCE: TB-11, TB-30, TB-39 требуют вопроса «Сохранить?» при ⌘W и ⌘Q для таба с правками. С сохранённым автосохранением файл с путём пишется молча, как сейчас. Вопрос остаётся для Untitled и для неудачной записи. Эти три критерия надо переписать под это решение (или Стас выбирает: «вопрос вместо автосохранения»).

Ответы на открытые вопросы ACCEPTANCE: 1 — см. строку Untitled. 2 — при активации таба (2.6). 3 — сосед справа, иначе слева.

### 2.2 Кто владеет окном

Решение: окно создаёт и держит `AppDelegate` (`NSWindowController` + `NSHostingController(rootView: TabbedWindow)`). В SwiftUI-сцене остаётся только `Settings` для меню.

Почему не SwiftUI `Window`:
- Файл из Finder при закрытом окне. `application(_:open:)` в делегате не может открыть SwiftUI-сцену: `openWindow` есть только в окружении View.
- «Сохранить?» при закрытии окна красной кнопкой. Нужен `windowShouldClose`. Делегат окна SwiftUI-сцены принадлежит SwiftUI, подмена ломкая.
- Тесты. `MainWindowController(store:)` можно создать в XCTest с временными файлами, как `EditorHarness` создаёт окно сейчас.

`NSApplicationDelegateAdaptor` остаётся, как в плане.

```swift
@main
struct MDEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual
    @AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue

    static var defaultWindowSize: CGSize { ... }   // unchanged, used by MainWindowController

    var body: some Scene {
        // No SwiftUI-owned window: the single main window belongs to AppDelegate (Finder opens, close prompts).
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                FileCommands(app: appDelegate)          // New, Open, Open Recent, Save, Save As, Close Tab
                CommandGroup(replacing: .undoRedo) { ... }   // as now
                CommandGroup(before: .toolbar) { ... }       // Visual / Source, as now
                CommandGroup(after: .toolbar) { ... }        // Zoom, from R2
                TabCommands(app: appDelegate)           // Show Next / Previous Tab
            }
    }
}
```

Риск: `.commands` на `Settings`-сцене. Проверка на шаге 2 — `NSApp.mainMenu` в тесте содержит File → Close Tab ⌘W ровно один раз и нет `Close All`, `Duplicate`, `Rename…`.

### 2.3 Типы

`Sources/AppDelegate.swift`
```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TabStore(prompter: AlertPrompter())
    private(set) lazy var mainWindow = MainWindowController(store: store)

    func applicationWillFinishLaunching(_ n: Notification)       // MDEditorAppearance test hook moves here
    func application(_ app: NSApplication, open urls: [URL])     // Finder, open -a, Dock drop: tabs + show window
    func applicationDidFinishLaunching(_ n: Notification)        // no tabs and not under XCTest → Open panel (P5)
    func applicationShouldOpenUntitledFile(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool  // tabs → show window, else Open panel
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply       // .terminateLater + store.prepareToQuit()
    func applicationWillResignActive(_ n: Notification)         // store.saveAll(reason: .autosave)
    /// The store of the key main window, else the app's store (tests create their own windows).
    func targetStore() -> TabStore
}
```
Под XCTest (`ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`) панель Open при запуске не показывается.

`Sources/OpenDocument.swift`
```swift
@MainActor
final class OpenDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL?
    @Published private(set) var isDirty = false
    @Published private(set) var displayName: String          // file name or "Untitled 2"
    private(set) var file: MarkdownDocument                  // text + BOM, bytes via data()
    private(set) var diskData: Data?                         // bytes last read or written; nil for Untitled
    private(set) var savedText: String                       // text that matches diskData
    private(set) var pendingConflict = false                 // changed on disk while dirty, tab hidden
    private(set) var controller: EditorController?           // created on first show (TB-16)
    let watcher = FileWatcher()
    static var autosaveDelay: Duration = .seconds(2)         // tests set it lower

    init(untitledName: String)
    init(contentsOf url: URL) throws                         // MarkdownDocumentError.notUTF8 passes through
    var text: String { file.text }
    func data() -> Data { file.data() }
    func makeController(mode: EditorMode, zoom: Double) -> EditorController
    /// From controller.onTextChange.
    func editorChanged(_ text: String)                       // isDirty = text != savedText; schedules autosave
    /// Writes if dirty (or `force`). Checks the disk first; asks before overwriting a foreign change.
    func save(prompter: SavePrompting, force: Bool = false) async -> Bool
    func saveAs(_ target: URL, prompter: SavePrompting) async -> Bool
    func reload(from data: Data) throws                      // external change, "Reload from Disk"
}
```

`Sources/TabStore.swift`
```swift
@MainActor
final class TabStore: ObservableObject {
    /// Creation order. ZStack order: never reordered, so moving a tab never re-parents a WKWebView.
    @Published private(set) var documents: [OpenDocument] = []
    /// Tab bar order.
    @Published private(set) var order: [OpenDocument.ID] = []
    @Published private(set) var activeID: OpenDocument.ID?
    /// Tabs that already have a web view.
    @Published private(set) var shown: Set<OpenDocument.ID> = []
    let prompter: SavePrompting
    var recordsRecents = true                                // tests: false, so Stas's Open Recent stays clean

    init(prompter: SavePrompting)
    var tabs: [OpenDocument] { get }                         // in `order`
    var active: OpenDocument? { get }
    @discardableResult func open(_ url: URL) throws -> OpenDocument   // dedupe → activate existing
    @discardableResult func newUntitled() -> OpenDocument
    func activate(_ id: OpenDocument.ID)                     // adds to `shown`; shows a pending conflict
    func activateNext()                                      // wraps around (TB-8)
    func activatePrevious()
    func close(_ id: OpenDocument.ID) async -> Bool           // false = cancelled
    func closeOthers(_ id: OpenDocument.ID) async
    func closeToTheRight(_ id: OpenDocument.ID) async
    func move(fromOffsets: IndexSet, toOffset: Int)
    func saveAll(reason: SaveReason) async -> Bool
    func prepareToQuit() async -> Bool
}
```
Дубль файла: сравнение `standardizedFileURL.resolvingSymlinksInPath()`, затем `URLResourceValues.fileResourceIdentifier` (жёсткие ссылки, регистр имени на APFS).

`Sources/SavePrompter.swift`
```swift
enum CloseChoice { case save, discard, cancel }
enum OverwriteChoice { case overwrite, cancel }
enum SaveReason { case explicit, autosave, close, quit }

@MainActor
protocol SavePrompting {
    func askToSave(_ doc: OpenDocument) async -> CloseChoice        // Untitled with text, or failed write
    func askOverwrite(_ doc: OpenDocument) async -> OverwriteChoice  // disk changed since diskData
    func chooseSaveURL(for doc: OpenDocument) async -> URL?          // NSSavePanel, .markdownText
    func showConflict(_ doc: OpenDocument) async -> NSApplication.ModalResponse  // FileWatcher.makeConflictAlert
    func report(_ error: Error, for doc: OpenDocument) async
}
final class AlertPrompter: SavePrompting   // sheets on the main window
```
В тестах — фейк с заранее заданными ответами. Так диалоги закрытия и выхода тестируются без кликов.

`Sources/MainWindowController.swift`
```swift
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: TabStore
    init(store: TabStore)            // NSWindow 1100×800 (MDEditorApp.defaultWindowSize), tabbingMode = .disallowed,
                                     // isReleasedWhenClosed = false, min 480×320
    func show()
    func windowShouldClose(_ sender: NSWindow) -> Bool   // false; closes all tabs async, then orderOut
    // Combine: active doc → window.title, representedURL, isDocumentEdited
}
```

`Sources/TabBarView.swift`
```swift
struct TabBarView: View {
    @ObservedObject var store: TabStore
    // HStack in ScrollView(.horizontal); TabItem: name (truncated middle), dirty dot, × on hover.
    // .contextMenu: Close, Close Others, Close Tabs to the Right, Reveal in Finder, Copy Path (last two disabled for Untitled).
    // Reorder: .draggable(id string) + .dropDestination → store.move. Drop of file URLs → store.open.
}
```

`Sources/EditorView.swift`: `DocumentWindow` удаляется, появляется `TabbedWindow`.
```swift
struct TabbedWindow: View {
    @ObservedObject var store: TabStore
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual
    @AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue
    var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store)
            ZStack {
                ForEach(store.documents.filter { store.shown.contains($0.id) }) { doc in
                    EditorView(document: doc, mode: mode, zoom: ZoomPreference.snap(zoom), isActive: doc.id == store.activeID)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar { /* Visual / Source picker, as now */ }
    }
}

struct EditorView: NSViewRepresentable {
    let document: OpenDocument
    var mode: EditorMode
    var zoom: Double
    var isActive: Bool
    func makeNSView(context: Context) -> NSView        // container; the web view of document.makeController(...)
    func updateNSView(_ view: NSView, context: Context) {
        // zoom → every tab; view.isHidden = !isActive;
        // mode only for the active tab (switching recreates Vditor and drops its undo history);
        // a tab that became active gets its mode now and the first responder.
    }
}
```
Тулбар в окне, которым владеет AppKit: `hosting.sceneBridgingOptions = [.toolbars]` (macOS 14). Если не заработает — переключатель режимов уходит в правый край полосы табов.

`Sources/FileWatcher.swift`: без `NSDocumentController`.
```swift
@MainActor
final class FileWatcher {
    /// Bytes the app last read or wrote (not the current text): our own saves are never "foreign".
    var knownData: () -> Data? = { nil }
    var isDirty: () -> Bool = { false }
    /// Clean document: take the disk version.
    var reload: (Data) -> Void = { _ in }
    /// Dirty document: ask (OpenDocument shows the sheet now or when its tab becomes active).
    var conflict: (Data) -> Void = { _ in }
    func watch(_ newURL: URL?)
    static func makeConflictAlert(fileName: String) -> NSAlert   // unchanged (REG-5)
}
```
Сейчас `check()` сравнивает диск с `document.data()` — с текущим текстом. Если пользователь печатает между автосохранением и проверкой (300 мс), своя запись выглядит как чужая. Сравнение с `knownData` это убирает (TB-25).

`EditorController.swift`:
- `static func forKeyWindow()`: сначала `(NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? MainWindowController` → `store.active?.controller`. Иначе — текущий поиск по иерархии, но с пропуском `isHiddenOrHasHiddenAncestor`. Поиск по иерархии нужен окнам `EditorHarness`: без него `testB7_undoRedo` (REG-7) перестанет попадать в контроллер. Это отступление от формулировки TB-19.
- Перетаскивание `.md` на WebView: подкласс `EditorWebView: WKWebView`, `performDragOperation` для `fileURL` → `onOpenFiles`. Без этого WKWebView сам примет файл как навигацию, и её отменит `decidePolicyFor`.

`MarkdownDocument.swift`: соответствие `FileDocument` (`init(configuration:)`, `fileWrapper`) больше не нужно, удаляется на шаге 2. `init(data:)`, `data()`, `utf8BOM`, ошибка — без изменений.

### 2.4 Запись файла

1. `diskNow = try? Data(contentsOf: url)`. Если `diskNow != diskData` → `prompter.askOverwrite`. Cancel → не пишем. Для автосохранения: Cancel ставит автосохранение этого таба на паузу до явного ⌘S.
2. Пишем во временный файл в `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)`.
3. `FileManager.default.replaceItemAt(target, withItemAt: tmp)`. Цель — `url.resolvingSymlinksInPath()`: симлинк остаётся симлинком. `replaceItemAt` сохраняет права и дату создания оригинала. Простой `Data.write(.atomic)` их не сохраняет.
4. `diskData = bytes`, `savedText = text`, `isDirty = false`. `NSDocumentController.shared.noteNewRecentDocumentURL(url)`, если `recordsRecents`.
5. Ошибка записи → `prompter.report`, таб остаётся dirty.

Нетронутый таб (`!isDirty`) не пишется ни автосохранением, ни ⌘S. `save(force: true)` нужен только тесту байтов TB-20.

### 2.5 Закрытие и выход

- `close(id)`: dirty с `url` → `save(.close)`. Неудача → `askToSave` (Save — повтор, Don't Save, Cancel). Untitled с текстом → `askToSave`; Save → `chooseSaveURL` → `saveAs`. Затем `watcher.watch(nil)`, контроллер и WebView освобождаются.
- Закрыт последний таб → `window.orderOut`. Приложение работает дальше.
- `windowShouldClose` → возвращает `false`, закрывает табы по одному через `close`. Cancel в любом вопросе останавливает закрытие.
- `applicationShouldTerminate` → `.terminateLater`, затем `store.prepareToQuit()` → `NSApp.reply(toApplicationShouldTerminate:)`.
- Вопросы — sheet на главном окне. Перед вопросом таб становится активным.

### 2.6 Внешнее изменение файла

- Таб чистый → `reload(from:)`: `MarkdownDocument(data:)`, `diskData`, `savedText`, `controller?.load(text:)`. Не UTF-8 → оставить текст, `log.error`.
- Таб dirty и активен → sheet `makeConflictAlert` сразу.
- Таб dirty и скрыт → `pendingConflict = true`, автосохранение этого таба на паузе. Sheet при активации таба.
- «Keep My Version» → `diskData` не меняется, следующая запись спросит перед перезаписью (текст алерта это обещает).

### 2.7 Меню File и табы

| Пункт | Клавиша | Действие |
|---|---|---|
| New | ⌘N | `targetStore().newUntitled()` + показать окно |
| Open… | ⌘O | `NSOpenPanel`, `allowedContentTypes = [.markdownText]`, несколько файлов |
| Open Recent | — | подменю из `recentDocumentURLs` + Clear Menu |
| Close Tab | ⌘W | если ключевое окно главное — `close(active)`, иначе `keyWindow.performClose` |
| Save | ⌘S | `save(.explicit)`; Untitled → Save As |
| Save As… | ⇧⌘S | `NSSavePanel` → `saveAs`; таб, `representedURL`, `FileWatcher` переходят на новый файл |
| Show Next Tab | ⌃Tab, ⇧⌘] | `activateNext()` |
| Show Previous Tab | ⌃⇧Tab, ⇧⌘[ | `activatePrevious()` |

SwiftUI даёт один `keyboardShortcut` на кнопку. Для второй клавиши — вторая скрытая кнопка с тем же действием или `NSEvent.addLocalMonitorForEvents` в `MainWindowController`. Проверка — тест.
Vditor не использует ⇧⌘[ / ⇧⌘] (`grep` пусто). Часть обработчиков Tab в Vditor не проверяет `ctrlKey` (например `index.js:10510`, таблица). По P7 меню получает клавишу раньше страницы. Подтвердить тестом: ⌃Tab в ячейке переключает таб и не двигает каретку.

### 2.8 Порядок работ (шаги плана 0–6)

| Шаг | Что | Проверка |
|---|---|---|
| 0 | Таблица «было / будет» (2.1) в `DEVELOPMENT.ru.md`. Факты P1–P6 уже есть, логи в `arch/`. Скриншот меню File на 0.5.1 — в папку R3 | Ревью, TB-0 |
| 1 | `OpenDocument`, `TabStore`, `SavePrompting` + фейк. Без UI, без WebView. `FileWatcher` пока старый | `TabStoreTests` (раздел 3) |
| 2 | `AppDelegate`, `MainWindowController`, `TabbedWindow`, `TabBarView`, новый `EditorView`, `MDEditorApp` без `DocumentGroup`, `forKeyWindow`. Удалить `FileDocument` из `MarkdownDocument` | `TabWindowTests` (окно, меню, заголовок), все старые тесты. Вручную: 3 файла через `open -a` из `build/dd` → одно окно |
| 3 | Запись, автосохранение, закрытие, выход, Save As | `TabStoreTests` (запись, конфликт, автосохранение), `TabWindowTests` (⌘W, ⌘S через NSEvent) |
| 4 | `FileWatcher` на колбэках | `FileWatcherTests`, `Round2Tests` |
| 5 | Меню, ⌃Tab / ⇧⌘], контекстное меню, перетаскивание табов и файлов | `TabWindowTests` для клавиш; остальное — ручной чек-лист |
| 6 | `scripts/smoke.sh` и `windowid.swift` под одно окно. Запускать только со Стасом: скрипт ставит сборку в `/Applications` | Правка, без запуска |

### 2.9 Риски

1. **Потеря правок.** Своё автосохранение заменяет `NSDocument`. Митигация: шаг 1 до UI, тесты байтов и конфликтов, пауза автосохранения при конфликте.
2. **Versions и Rename пропадают.** Видимая потеря функций. Записать в README; решение подтверждает Стас.
3. **ACCEPTANCE TB-11/30/39** ждут вопроса «Сохранить?», который при автосохранении не появляется. Нужно решение Стаса до шага 3.
4. **`.commands` на `Settings`-сцене** и тулбар в AppKit-окне (`sceneBridgingOptions`). Проверка на шаге 2; запасные варианты указаны.
5. **Общий домен UserDefaults.** Тестовый хост — тот же bundle id `com.drkhwo.lilamd`, что у установленного приложения. Тест, который жмёт ⌘= через меню, пишет `editorZoom` Стасу. Тесты обязаны вернуть значение в `tearDown`. То же для Open Recent: `recordsRecents = false`.
6. **Память.** Каждый показанный таб держит WebView. Замер TB-36; выгрузка WebView — только если > 1,5 ГБ.
7. **Смена режима** пересоздаёт Vditor и теряет undo. Поэтому режим применяется только к активному табу, скрытые получают его при показе.
8. **iCloud Drive и сетевые диски.** Нет `NSFileCoordinator`. Для MVP принимаем; записать в «Не проверено».

### 2.10 Отклонения (шаги 2–3)

1. `TabStore.open(_:activate:)`, по умолчанию `true`. `MainWindowController.open(_:)` открывает пачку файлов с `activate: false` и активирует только последний. Причина: `activate` добавляет таб в `shown`, и пять файлов из Finder создали бы пять WebView сразу (TB-16, TB-36).
2. Панель Open при запуске: проверка `NSApplication.launchIsDefaultUserInfoKey`, а не только «табов нет». Наблюдение 04.11 (`open -n -a … 3 файла`): `application(_:open:)` пришёл после `applicationDidFinishLaunching`, и панель Open открылась поверх табов.
3. `AppDelegate.targetWindow()` рядом с `targetStore()`: ⌘N и ⌘O должны показать окно, а не только изменить store.
4. Тестовый хук `-MDEditorRecordsRecents NO`. Ручной запуск сборки из `build/dd` с тем же bundle id иначе пишет временные файлы в Open Recent установленного приложения.
5. `EditorController.focus()` и пропуск скрытого WebView в `focusWhenInWindow`. Иначе таб, который стал готов в фоне, забирает клавиатуру у видимого.
6. На шагах 2–3 нет Open Recent и Show Next / Previous Tab (шаг 5). `FileWatcher` не подключён к табам (шаг 4): внешние изменения файла до шага 4 не видны.

### 2.11 Отклонения (шаги 4–6)

1. `OpenDocument.answeredDiskData`: чужие байты, о которых пользователь уже ответил (вопрос о перезаписи или sheet конфликта). `FileWatcher` по ним второй раз не спрашивает. Причина: автосохранение и проверка файла могут сработать в одном окне 0,3 с. Без этого пользователь получил бы два вопроса подряд об одной и той же правке.
2. Конфликт ставит автосохранение таба на паузу и для активного таба, не только для скрытого. После «Keep My Version» пауза остаётся до ⌘S (⌘S спрашивает о перезаписи, как обещает текст алерта). Причина: иначе через 2 с автосохранение покажет второй sheet поверх первого.
3. Ответ на вопрос о перезаписи снимает `pendingConflict`. При закрытии и выходе sheet конфликта не показывается (`TabStore.select` вместо `activate`): вопрос о перезаписи при записи покрывает тот же случай.
4. ⌃Tab, ⌃⇧Tab, ⇧⌘], ⇧⌘[ перехватывает `NSEvent.addLocalMonitorForEvents` в `MainWindowController`, все четыре. В меню Window стоят пункты с ⌃Tab / ⌃⇧Tab (для показа и для окон без монитора). Причина: SwiftUI даёт пункту одну клавишу, а монитор срабатывает раньше окна и страницы. Клавиши сравниваются по `keyCode`, поэтому работают в любой раскладке.
5. `NSWindow.allowsAutomaticWindowTabbing = false` в `AppDelegate`. Иначе AppKit добавляет свои пункты Show Next / Previous Tab с теми же клавишами.
6. Open Recent: `RecentDocuments` (`MDEditorApp.swift`) публикует `recentDocumentURLs` для меню SwiftUI. Меню не наблюдает `NSDocumentController`, поэтому `TabStore` пополняет список через `RecentDocuments.shared.note`.
7. Перетаскивание таба несёт строку `lilamd-tab:<UUID>`. `EditorWebView` такую строку не принимает, иначе UUID вставился бы в текст документа. Перетащенный таб встаёт на место таба, на который его бросили.
8. `ZStack` редакторов в `TabbedWindow` получил `.frame(maxWidth: .infinity, maxHeight: .infinity)`. Без него окно без табов сжималось до 320 pt по высоте (`testWindowHasDefaultSizeAndNoSystemTabs`). Падение появилось после правок шага 5 в `TabBarView`; какая именно правка его вызвала, я не выяснял.
9. `TabStore.open` пишет в лог `tab opened: <путь>`. По этой строке `scripts/smoke.sh` (шаг TB1) считает табы. `windowid.swift` печатает третьим полем число окон приложения.

### 2.12 Отклонения (правки по замечаниям приёмки)

1. Вопрос «Сохранить?» для таба с файлом. Решение 2.1 («⌘W и ⌘Q сначала пишут файл») ждало Стаса (C-2). Ответа нет, поэтому сделано по ACCEPTANCE TB-11/30/39: закрытие таба и выход с правками спрашивают Save / Don't Save / Cancel для любого таба. Автосохранение через 2 с и при уходе из приложения осталось. `SaveReason.close` и `.quit` удалены. Вернуть запись без вопроса — одна строка в начале цикла `TabStore.resolveUnsaved`: `if doc.url != nil, await save(doc) { return true }`.
2. ⇧⌘= / ⇧⌘− (Z-13): `editor.js` пересылает их Vditor как «=» / «-» с `shiftKey` и гасит исходное событие. Причина и проба — `DEVELOPMENT.ru.md`, «Решения». Это код R2, правка нужна для зелёного `Round4Tests`.
3. `Round4Tests` (R2): события ⇧⌘ переведены на форму клавиатуры US («+» / «_»). `setStoredZoom` вызывает `menuNeedsUpdate` меню View, `testZoomMenuItems` ищет пункты заново.

---

## 3. Тесты по релизам

Общее:
- Как в `Round3Tests`: `EditorHarness` + `h.key(...)` → `NSApp.sendEvent` (тот же путь, что клавиатура, включая меню).
- В `Support.swift` у `key` новый параметр: `key(_ chars: String, ignoringModifiers: String? = nil, keyCode:, flags:)`. Для ⌥⌘= нужно `characters "≠"`, `ignoring "="`; для ⌥⌘− — `"–"` (U+2013) и `"-"`, keyCode 27.
- Тесты, меняющие `editorZoom` через меню, сохраняют старое значение в `setUp` и возвращают в `tearDown`.
- Один прогон за раз: XCTest открывает настоящие окна.

### R1 (0.6, таблицы): `Tests/Round4Tests.swift`
T-1…T-9 из ACCEPTANCE на `samples/wide-table.md`. Проверки через `h.js` (`getComputedStyle`, `scrollWidth`, `getBoundingClientRect`).

### R2 (0.6, масштаб): `Tests/Round4Tests.swift` (дописать), `Tests/Round3Tests.swift` (правка)

| Тест | Что делает |
|---|---|
| `testZoomLadder` | `steps`, `snap`, `next`/`previous`, края → `nil`, `load/save` на отдельном suite (как `testA7`) |
| `testSetZoomScalesPage` | `setZoom(1.5)` → `pageZoom == 1.5`, `document.documentElement.clientWidth` ≈ 900 / 1.5 (P10) |
| `testZoomSurvivesModeSwitch` | `setZoom(1.2)`, `setMode(.source)`, ready → `pageZoom == 1.2` |
| `testZoomMenuItems` | В `NSApp.mainMenu` → View: Zoom In `=`/[.command], Zoom Out `-`, Actual Size `0`, подменю Zoom из 6 пунктов |
| `testMenuDoesNotTakeShiftOrOptionCmdEquals` | `performKeyEquivalent` → false для ⇧⌘= (`"+"` и `"="`) и ⌥⌘= (1.7) |
| `testCmdEqualsZoomsAndDoesNotAddRow` | Каретка в ячейке, ⌘= → `editorZoom` 1.0 → 1.1, через 500 мс текст не изменился, `h.changes` пуст |
| `testCmdMinusInHeadingZoomsOnly` | Каретка в `## Two`, ⌘− → зум 0.9, уровень заголовка тот же |
| `testCmdEqualsAtMaxZoomDoesNothing` | `editorZoom = 1.5`, ⌘= в ячейке → 1.5, текст тот же (P8 на SwiftUI-меню) |
| `testOptCmdMinusDeletesRow`, `testOptCmdEqualsRaisesHeading` | ⌥⌘− в строке таблицы удаляет её; ⌥⌘= в `## Two` → `# Two`, diff — одна строка |
| `testShiftCmdEqualsObservation` | ⇧⌘= в ячейке: зум не меняется; число колонок до/после — в лог теста (1.5) |
| `Round3Tests.testCmdEqualsAddsOnlyTheRow` | `h.key("≠", ignoringModifiers: "=", keyCode: 24, flags: [.command, .option])`, ожидания те же (REG-9) |

Как проверить зум в окне `EditorHarness`: harness не в SwiftUI, поэтому меню меняет только `UserDefaults`. Тест проверяет `editorZoom` в `UserDefaults.standard`. Цепочку `@AppStorage → EditorView → pageZoom` проверяет ручной Z-8, а в R3 — `TabWindowTests`.

### R3 (0.7, табы)

| Файл | Шаг | Что |
|---|---|---|
| `Tests/TabStoreTests.swift` | 1, 3 | Без окон и WebView. Файлы — копии `samples/*` во временной папке (`samples/` не писать). open/dedupe (тот же путь, симлинк, другой регистр), `newUntitled` → «Untitled», «Untitled 2», порядок активации после close (TB-3), `move`, `isDirty` через `editorChanged` и возврат к исходному тексту, `save(force: true)` нетронутого → SHA-256 совпадает (TB-20: crlf, cyrillic, empty, big, sample, BOM, без финального `\n`), не UTF-8 → ошибка, табов не прибавилось (TB-21), внешняя правка + `save` → `askOverwrite`, Cancel не пишет (TB-28), автосохранение при `autosaveDelay = .milliseconds(100)`, `prepareToQuit` с фейком (Untitled → askToSave, Cancel → false) |
| `Tests/TabWindowTests.swift` | 2, 3, 5 | `MainWindowController(store:)` с фейковым prompter, временные файлы. `window.title`/`representedURL` при смене таба (TB-15), `controller == nil` до показа (TB-16), ⌃Tab / ⇧⌘] / ⌃⇧Tab / ⇧⌘[ через `NSApp.sendEvent` (TB-8), ⌘W закрывает активный таб (TB-10), ⌘Z из меню меняет только активный таб (TB-18), undo в табе A после A→B→A (TB-17), зум общий для двух табов (TB-26), картинки из двух каталогов (TB-33), меню File: Close Tab ⌘W один раз, нет Duplicate / Rename / Revert |
| `Tests/FileWatcherTests.swift` | 4 | Внешняя запись в чистый таб → текст перезагружен, диалога нет (TB-23). Dirty активный → `showConflict` вызван (TB-24). Dirty скрытый → `pendingConflict`, вопрос при `activate`. Своя запись + ожидание 1 с → ни reload, ни conflict (TB-25) |

Не автоматизируется: двойной клик в Finder, `open -a` (только вручную со сборкой из `build/dd`), перетаскивание из Finder, клики по контекстному меню, перетаскивание табов мышью, Open Recent, сам вид полосы табов. Это ручной чек-лист R3 со скриншотами в `~/dev/QA/2026-11-04-lilamd-0.6-0.7/R3/`.
