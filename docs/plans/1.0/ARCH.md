# LilaMD 1.0, этап 1 «Продукт»: архитектура

Источник: `docs/plans/1.0-appstore-PLAN.md`, раздел 1 (пункты 1.1–1.6). Задачи: `TASKS.md`. Критерии: `ACCEPTANCE.md`. Шаги с экраном: `FOREGROUND.md`.
Доказательства: `/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0/<task-id>/`.

Номера строк — по коммиту `4ed08c5` (ветка `worktree-plan-appstore-1.0`).

## 0. Общие ограничения

- Стас работает на этом Mac. Тесты — только `scripts/test.sh` (фон: приложение `.accessory`, не активируется, окна за экраном, `TestBackground.swift:15–36`).
- В фоне у приложения **нет ключевого окна**: `NSApp.keyWindow == nil`, `controlActiveState` всегда неактивный. Всё, что зависит от ключевого окна, проверяется в `FOREGROUND.md` или через чистую функцию.
- Меню в фоне доступно: `NSApp.mainMenu` читается, `NSMenu.performActionForItem(at:)` вызывает действие кнопки SwiftUI. Так уже работают `TabWindowTests.testFileMenuHasCloseTabOnceAndNoDocumentItems` и `testOpenRecentAndTabSwitchingMenus`.
- Снимок вью без экрана: `NSView.cacheDisplay(in:to:)` на хостинг-вью окна за экраном или `ImageRenderer`. Это не захват экрана, в фоне разрешено.

## 1.1 Подсветка активной вкладки

**Причина в коде.**
- `Sources/TabBarView.swift:74`: фон активной вкладки `Color(nsColor: .controlBackgroundColor)`.
- `Sources/TabBarView.swift:20`: фон полосы `.bar` (материал). В светлой теме оба почти белые, в тёмной — почти одного серого.
- `Sources/TabBarView.swift:69`: другое отличие только `.primary` против `.secondary` у текста. На глаз этого мало.
- Состояние окна (ключевое / нет) не читается: `controlActiveState` в коде нет.

**Решение.**
- Фон активной вкладки = фон страницы редактора. План и задача называют `.textBackgroundColor`. В светлой теме это `#ffffff`, совпадает со страницей (`Resources/web/editor.css:2`). В тёмной теме страница рисует `#1d2125` (`editor.css:3`), web view прозрачен (`EditorController.swift:56`). Системный `.textBackgroundColor` в тёмной теме ≈ `#1e1e1e`. Между вкладкой и документом будет шов. Берём динамический цвет `NSColor(name:dynamicProvider:)`: `#ffffff` / `#1d2125`. Константа одна, в Swift (`EditorPalette.pageBackground`); в `editor.css` — комментарий со ссылкой на неё. Это отступление от буквы плана ради его цели («вкладка сливается с документом»). Если Стас хочет строго `.textBackgroundColor`, D1 меняет одну строку.
- Полоса 2 pt по верхнему краю активной вкладки (`overlay(alignment: .top)`). Ключевое окно — `Color.accentColor`. Неключевое — серый `Color(nsColor: .tertiaryLabelColor)`. Источник — `@Environment(\.controlActiveState)`: `.key` → акцент, иначе серый.
- Заголовок активной вкладки `.fontWeight(.semibold)`. Чтобы имя не прыгало при смене активной вкладки, ширину резервирует скрытый semibold-текст (`.hidden()` под видимым в `ZStack`). Проверка — скриншот.
- Стиль — чистая структура `TabAppearance(isActive:isKeyWindow:)` → `background`, `stripe`, `weight`. Её проверяет XCT без пикселей и без ключевого окна.
- AX: у вкладки `accessibilityAddTraits(.isSelected)` для активной и `accessibilityIdentifier("tab:<displayName>")` у всех. Сейчас вкладка в AX — только `static text` в `scroll area 1` (так её искал скрипт `race-closetab.sh`). Идентификаторы нужны XCT, пробе CLOSE и скриптам скриншотов.
- Активная вкладка за краем полосы: полоса — горизонтальный `ScrollView` (`TabBarView.swift:10`). При ⌃Tab на вкладку за краем полоса не прокручивается. Решение: `ScrollViewReader` + `scrollTo(activeID)` на смену `store.activeID`. Критерий S (TAB-7).

**Проверка без экрана.** XCT рисует `TabBarView` с 3 вкладками через `ImageRenderer` (или `cacheDisplay` окна за экраном) с `.environment(\.colorScheme, …)` и `.environment(\.controlActiveState, …)`. Считает средний цвет в центре активной и соседней вкладки и цвет верхних 2 pt. Это 4 состояния без ключевого окна. Настоящие скриншоты окна (4 шт.) — шаг в `FOREGROUND.md`.

**Риски.**
- `Color(nsColor:)` в `ImageRenderer` может брать тему из `NSAppearance.current`, а не из `.colorScheme`. Тогда XCT ставит `NSAppearance.current` (или `NSApp.appearance`) на время рендера и возвращает.
- `semibold` и длинное имя: проверить усечение посередине (`TabBarView.swift:66–68`) на скриншоте с длинным именем.
- Пиксельная проверка хрупкая (сглаживание, Retina). Порог — разница цветов, а не точное значение. Основная проверка — `TabAppearance` и AX `isSelected`.

## 1.2 Ввод на других языках (IME)

**Что есть в коде.** Своей обработки `compositionstart` / `compositionend` в `editor.js` нет. Композицию ведёт Vditor 3.11.2. Места, где наш код может её сломать:

1. `Resources/web/editor.js:142–156`. Перехват `keydown` в корне IR: если каретка прямо в корне, текстовый узел переносится в новый `<p>`, `Selection` ставится заново. Фильтр (строка 143) — `e.isComposing`. В WebKit на macOS первый `keydown`, который начинает композицию, может прийти с `isComposing = false` и `keyCode = 229`. Тогда перенос узла и новая `Selection` случаются в момент старта композиции. Главный подозреваемый для места «первая строка документа» и «после ⌘↓ за последним блоком кода». Фикс, если баг подтвердится: `e.keyCode === 229` в фильтр. Сначала воспроизвести.
2. `editor.js:71–72` и `198–200`. Внутри события `input` `VditorIRDOM2Md` возвращает заглушку `LAZY`, Markdown приходит через `lazyTimer` (строка 225). Это задержка, не потеря. Проверить: текст на стороне Swift совпадает с DOM после `compositionend`.
3. `editor.js:175–190`. `selectionchange` переносит каретку в первую ячейку таблицы, если каретка в корне перед таблицей. Во время композиции WebKit двигает выделение по marked text. Риск — «таблица в начале документа».
4. `editor.js:294–297`. Замер задержки. Только читает событие, безвреден.

**Нативная сторона.**
- Автосохранение (`OpenDocument.swift:224–234`) пишет файл и не трогает web view. `controller.load(text:)` вызывается только при перезагрузке с диска (`OpenDocument.swift:135`). Само автосохранение композицию не сорвёт.
- `flushInput` (`EditorController.swift:129–138`) только читает `mdeditor.getValue()`.
- `applicationWillResignActive` → `saveAll` (`AppDelegate.swift:67–69`). Окно кандидатов IME не делает приложение неактивным. Проверяется только живым вводом (FG).
- Мониторы клавиш (`MainWindowController.swift:36–38`, `ZoomMenuSupport`) берут события по `keyCode` с модификаторами ⌃/⌘. Обычный ввод не трогают.

**Решение.**
- Сначала тест, потом фикс. D3 пишет XCT-класс `IMETests` на `EditorHarness` (фон).
  - Путь A: `NSTextInputClient` у `WKWebView`: `setMarkedText(_:selectedRange:replacementRange:)` несколько раз, затем `insertText(_:replacementRange:)`. WebKit сам генерирует `compositionstart` / `compositionupdate` / `compositionend`. Первый шаг D3 — доказать, что путь работает в фоне: страница видит события композиции (счётчик в тесте через `h.js`). В фоне окно не ключевое; WebKit может не принять marked text без фокуса.
  - Путь B (запасной): JS-симуляция в странице. `keydown` (`keyCode 229`, `isComposing` как у WebKit), `compositionstart`, `compositionupdate`, `beforeinput`/`input` с `isComposing: true`, затем `compositionend` и `execCommand('insertText')`. Путь B проверяет наши обработчики и Vditor, но не WebKit. D3 записывает в отчёт, какой путь сработал.
  - Шесть мест: абзац, заголовок, ячейка таблицы, элемент списка, первая строка документа, таблица в начале документа.
  - Строки: русская «привет», китайская «你好世界», японская «こんにちは». Для Pinyin marked text — латиница («ni hao»), затем коммит иероглифов.
  - Проверка: `controller.text` после `compositionend` содержит вставку ровно один раз; соседний текст не изменился; каретка (`getSelection()`) сразу после вставки.
  - Автосохранение во время композиции: `OpenDocument.autosaveDelay` = 0,2 с, композиция держится 1 с. После коммита текст один раз, файл на диске = текст.
- Живой ввод — шаг FG (`scripts/fg/ime-live.sh`). Сейчас включены U.S., RussianWin, Ukrainian-PC, PressAndHold (`defaults read com.apple.HIToolbox AppleEnabledInputSources`, 11.11). Pinyin и Kana **не включены**. Скрипт запоминает текущий источник и список включённых, включает Pinyin – Simplified и Japanese Kana через `TISEnableInputSource`, печатает через CGEvent в Debug-сборке, проверяет файл, затем выключает добавленные источники и возвращает исходный. Это временное изменение системных настроек; оркестратор запускает шаг только в отсутствие Стаса.
- Фикс — только в `Resources/web/editor.js`, только для подтверждённого случая, с регресс-тестом в `IMETests`.

**Риски.**
- Программная композиция не равна настоящему IME (нет окна кандидатов, другой порядок `keydown`). Зелёный XCT не закрывает живой ввод. IME-7 (FG) — M.
- Press-and-hold (удержание буквы → меню акцентов) — тоже marked text. Включён у Стаса. S-критерий IME-9.
- Путь A может не работать в фоне. Тогда XCT по пути B и FG-шаг становятся единственной проверкой WebKit.

## 1.3 Поведение по правилам macOS

### About LilaMD
**Сейчас.** Пункт About создаёт SwiftUI: стандартная панель с `CFBundleShortVersionString` и `CFBundleVersion`. Коммит лежит в `Info.plist` под ключом `MDEGitCommit` (`project.yml`, `preBuildScripts` и `info.properties`), но в панель не попадает. Ссылки на GitHub нет. `NSHumanReadableCopyright` пустой.

**Решение.** `MDEditorApp.swift`, `.commands`: `CommandGroup(replacing: .appInfo)` с кнопкой «About LilaMD». Она вызывает `NSApp.orderFrontStandardAboutPanel(options:)`:
- `.applicationVersion`: `"<CFBundleShortVersionString> (<MDEGitCommit>)"`;
- `.credits`: `NSAttributedString` со ссылкой `https://github.com/drkhwo/lilamd` (атрибут `.link`).
Опции собирает `AboutPanel.options(info:)` — XCT проверяет её без показа панели. URL — в `enum AppLinks` (общий с Help).

**Риски.** Сборка из грязного дерева даёт `<sha>-dirty`. Для релиза — чистое дерево. Под XCTest `MDEGitCommit` есть (тест-хост = приложение).

### Перетаскивание окна
**Сейчас.** `MainWindowController.swift:17–19`: окно `.titled` без `fullSizeContentView`. Заголовок и тулбар (`sceneBridgingOptions = [.toolbars]`, строка 28) системные, их перетаскивание работает само (FG подтверждает). Полоса вкладок — SwiftUI `ScrollView` в `NSHostingView`. `isMovableByWindowBackground` выключен. Пустая часть полосы окно, скорее всего, не двигает. D2 проверяет это до изменения (FG-шаг) и пишет результат.

**Решение.** В пустой части полосы справа от последней вкладки — `NSViewRepresentable` `WindowDragArea`: `mouseDown` → `window?.performDrag(with: event)`; двойной клик → действие из `AppleActionOnDoubleClick` (по умолчанию `performZoom`), как у заголовка. Область занимает остаток ширины видимой полосы (`GeometryReader` вокруг `ScrollView`, `minWidth` у последнего элемента `HStack`). `WindowDragGesture` не подходит: он с macOS 15, deployment target 14.0.

**Риски.**
- Сброс файлов на полосу (`dropDestination`, `TabBarView.swift:21–26`) должен работать и над `WindowDragArea`. Теста на сброс сейчас нет. Проверка — FG.
- Перетаскивание вкладок (`.draggable`, строка 83) не должно двигать окно. `WindowDragArea` только в пустом месте.
- `isMovableByWindowBackground` не включать: окно поедет при выделении текста мышью в web view.

### File → Open Recent
**Сейчас.** `MDEditorApp.swift:26` → `appDelegate.targetWindow().open([$0])` → `MainWindowController.open` (`MainWindowController.swift:52–65`). Ошибка ловится, `NSAlert` из `makeOpenErrorAlert` (строки 68–74) показывается через `runModal` (строка 64). Падения в коде не видно. Список `RecentDocuments.urls` (`MDEditorApp.swift:84`) — снимок `NSDocumentController.recentDocumentURLs`, обновляется только в `note` и `clear`.

**Что проверить.**
- Удалённый файл: алерт «The document “x.md” could not be opened.» + текст Foundation. Текст проверяет XCT через `makeOpenErrorAlert` с настоящей ошибкой от `OpenDocument(contentsOf:)` на несуществующем пути.
- Перемещённый файл: `NSDocumentController` хранит закладки и может отдать новый путь, но наш снимок устарел до перезапуска. Клик даёт старый путь → ошибка.
- Файл в Корзине: закладка может разрешиться в `~/.Trash/…`. Записать фактическое поведение, править не обязательно.

**Решение.** `RecentDocuments.refresh()` перечитывает `recentDocumentURLs`. Вызывать после неудачного открытия из Open Recent и при открытии меню (если SwiftUI даёт хук; иначе только после ошибки). `runModal` в XCT не вызывать: открыть ошибку через выделенную функцию, которая возвращает алерт, а показ — отдельно.

**Риск.** `runModal` блокирует тест. Тест вызывает только построение алерта.

### Settings
`MDEditorApp.swift:18` — `Settings { EmptyView() }`, строка 20 — `CommandGroup(replacing: .appSettings) {}`. Пункт должен исчезнуть. XCT перечисляет меню LilaMD: нет «Settings…», нет пункта с пустым заголовком, нет двух разделителей подряд, нет ⌘, у любого пункта. Кода, скорее всего, не будет.

### Help
**Сейчас.** Своего меню Help нет. SwiftUI оставляет системный пункт «LilaMD Help»; для приложения без справки система показывает «Help isn't available for LilaMD» (не проверено на этой сборке).

**Решение.** `CommandGroup(replacing: .help)`: «LilaMD on GitHub» → `https://github.com/drkhwo/lilamd`, «Report an Issue» → `https://github.com/drkhwo/lilamd/issues`. Открытие через `NSWorkspace.shared.open`. Поле поиска система оставит сама.

**Риск.** Тесты не открывают браузер: XCT проверяет пункты меню и `AppLinks`, без нажатия.

## 1.4 Close Tab иногда не закрывает вкладку

**Данные прошлого прогона** (`~/dev/QA/2026-11-04-lilamd-0.6-0.7/R3-tabs/round2/auto/`):
- `race-closetab/run.txt`, проба 2: перед кликом Close Tab скрипт пишет «frontmost pid=13133, retrying» — LilaMD терял активность. Файл записан в 14:12:29.298 (`race-closetab-stream.log:42`), раньше 2 с автосохранения: это `applicationWillResignActive` → `saveAll`. Вкладка r29.md осталась, листа нет. Это настоящий отказ закрытия.
- `race-closetab-run1/run.txt`, проба 5: «retrying» перед вводом. Вкладка r12.md **закрылась**, правка не записана (хеш не изменился). Это потерянное синтетическое нажатие (харнесс), не отказ Close Tab.
- Итог: подтверждён 1 отказ закрытия из 46, не 2.

**Причина в коде (гипотеза, средняя–высокая вероятность).** `Sources/AppDelegate.swift:114–120`:
```swift
func closeTab() {
    if let main = NSApp.keyWindow?.windowController as? MainWindowController {
        main.closeActiveTab()
    } else {
        NSApp.keyWindow?.performClose(nil)
    }
}
```
AX нажимает пункт меню и у приложения без ключевого окна (сразу после повторной активации ключевое окно восстанавливается асинхронно). Тогда `NSApp.keyWindow == nil`, обе ветки ничего не делают. Вкладка остаётся, листа нет. Остальные действия меню берут `targetWindow()` с запасным `mainWindow` (`AppDelegate.swift:74–76`); `closeTab` — нет.

Мышью пользователь сюда не попадёт: клик в меню активирует приложение. VoiceOver, Shortcuts, AppleScript и автоматизация ревьюера — попадут.

**Воспроизведение в фоне.** В фоновом прогоне XCTest у приложения нет ключевого окна. Значит, `closeTab()` в фоне — это ровно ветка `keyWindow == nil`. Тест: вкладка в окне `AppDelegate`, вызов пункта меню «Close Tab» через `performActionForItem` → вкладка должна закрыться. До фикса тест красный, это и есть репро. Нужен доступ теста к экземпляру `AppDelegate`: `@NSApplicationDelegateAdaptor` прячет его за прокси SwiftUI, поэтому добавить `AppDelegate.shared` (слабая ссылка, ставится в `applicationWillFinishLaunching`).

**Вторая возможная причина (низкая вероятность).** `TabStore.close` → `resolveUnsaved` → `doc.flushEditor()` (`TabStore.swift:218`) ждёт `callAsyncJavaScript` (`EditorController.swift:131`, `146`). Если ответ не приходит, закрытие висит без листа. В логах этого не видно, но логов на входе и выходе закрытия не было.

**Решение.**
1. Инструментировать: `log.info` на входе `AppDelegate.closeTab` (класс `keyWindow`, `NSApp.isActive`), в `closeActiveTab`, на входе и выходе `TabStore.close` (длительность `flushEditor`, результат).
2. Красный XCT (фон) на ветку `keyWindow == nil`, затем фикс: ключевое окно с `MainWindowController` → закрыть его вкладку; ключевое окно другое (панель, Settings) → `performClose`; ключевого окна нет → `targetWindow().closeActiveTab()`. Выбор — чистая функция, её проверяет XCT.
3. Защита от двойного закрытия (S): если закрытие вкладки уже идёт, второй вызов ждёт первый, а не запускает второй `resolveUnsaved` (иначе два листа «Save?» на Untitled). Набор `closing: Set<ID>` в `TabStore`.
4. Фоновая проба 100 раз (XCT): правка через `execCommand('insertText')` → 0,3 с или 2,0 с → пункт меню Close Tab через `performActionForItem` → вкладка закрыта, файл содержит правку, листа нет.
5. Проба 100 раз на экране (FG, `scripts/fg/close-100.sh`): Debug-сборка, правка, ⌘W через CGEvent и клик меню через AX поочерёдно. Каждый запуск проверяется через AX (`tab:<имя>` нет в полосе) и SHA файла. Запуск, где правка не дошла до файла и вкладка открыта, — «не засчитан», в 100 не входит, записан с причиной.

**Риски.**
- Если гипотеза неверна, фикс п. 2 ничего не даст на экране. Поэтому FG-проба обязательна, а лог п. 1 остаётся в коде.
- `log.info` на каждом закрытии — дёшево; приватность пути `.public` как у соседних логов.

## 1.5 Строка в README

`README.md`, раздел «Usage»: `alias lilamd='open -a LilaMD'` и одна фраза, куда её вставить (`~/.zshrc`). Код не меняется.

Попутно: README пишет «**Version 0.5** — an early release» (строка 10), версия 0.6.0. Это вне 1.5. D1 не правит строку без согласия Стаса; записывает в REPORT как замечание.

## 1.6 Mermaid и формулы

**Что есть.** В `Resources/vditor/dist/js` лежат `mermaid/`, `katex/` (с `fonts`, `mhchem.min.js`), а также `mathjax`, `echarts`, `graphviz`, `markmap`, `flowchart.js`, `plantuml`, `abcjs`, `smiles-drawer`. CSP (`Resources/web/index.html:5`) разрешает `mdedit:` для скриптов, шрифтов и стилей, `'unsafe-eval'` есть.

**Находка.** `Resources/web/editor.js:46`: `mathBlockPreview: false`. Vditor передаёт это в Lute. Блочные формулы `$$…$$` в Visual (IR), скорее всего, **не рендерятся** — только исходник. Строчные `$…$` — неизвестно. Mermaid идёт через `codeBlockPreview: true` — должен рендериться. Ничего не проверено.

**Решение.**
- XCT (фон) на `EditorHarness`: документ с блоком `mermaid`, блоком `$$…$$` и строчной `$…$`. Проверка через JS: `svg` внутри превью mermaid, `.katex` внутри превью формулы. Событие `blocked` (`editor.js:311–313`) не пришло.
- Байты: открыть и закрыть → SHA-256 файла не изменился.
- Образец `samples/mermaid-math.md` (новый файл). Скриншоты Visual, светлая и тёмная: `cacheDisplay` окна за экраном (фон) или FG-шаг, если снимок web view за экраном пустой.
- Если блочные формулы не рендерятся и правка — одна строка (`mathBlockPreview: true`), D3 включает её, только если REG-тесты, `SourcePreserverTests` и undo (`editor.js:106–107` уже обрабатывает `language-math`) зелёные. Иначе — «не работает», формулы в описании не упоминать. Решение о включении — за Стасом (это изменение поведения), D3 только готовит.

**Риски.**
- Mermaid ~3 МБ, грузится при первом блоке. На `big.md` без mermaid не влияет; REG-задержка (C6) проверяет.
- Тёмная тема mermaid: после `setTheme` блоки могут остаться светлыми. Записать, в 1.0 не чинить.
- `cacheDisplay` у `WKWebView` за экраном может дать пустую картинку (рисует web-процесс). Тогда — `WKWebView.takeSnapshot(with:)`, он работает без экрана.
