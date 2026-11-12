# LilaMD 1.0, этап 1 «Продукт»: задачи

Источники: `docs/plans/1.0-appstore-PLAN.md` (раздел 1), `ARCH.md`, `ACCEPTANCE.md`, `FOREGROUND.md` (все в `docs/plans/1.0/`).
`E` = `/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0`.

## Базовая линия

11.11, коммит `4ed08c5`, до изменений, `scripts/test.sh` (фон): 146 тестов, 136 прошли, 10 пропущены (`requireForeground`), 0 падений, 125 с. Лог: `E/baseline/test-bg.log`.

## Правила для всех задач

- Работать только в worktree `/Users/stanislav/dev/md-editor/.claude/worktrees/plan-appstore-1.0`. Не делать `git push`.
- Стас работает на этом Mac. Экран, фокус, клавиатуру, мышь и источник ввода не забирать:
  - тесты — только `scripts/test.sh` (фон). Точечно: `scripts/test.sh -only-testing:MDEditorTests/<Class>/<test>`. Никогда `--foreground`;
  - не запускать приложение через `open`, не посылать CGEvent, не использовать AppleScript / System Events / cliclick, не переключать источник ввода, не активировать приложения;
  - не запускать `scripts/smoke.sh`, `scripts/set-default.sh`, `install.sh`; не трогать `/Applications/LilaMD.app`.
- Один прогон тестов за раз.
- Новый тест, который шлёт key equivalent меню или зависит от ключевого окна, первой строкой вызывает `try requireForeground()`. Проверки — положительные (вкладка закрылась, текст появился), чтобы потерянное нажатие не дало ложный PASS.
- Всё, что требует экрана, — шаг в `FOREGROUND.md` и скрипт `scripts/fg/<NN>-<имя>.sh` по правилам этого файла. Скрипт пишется и проверяется на синтаксис (`bash -n`, `swiftc -parse`), но не запускается.
- Сначала красный тест, потом фикс. Красный лог — в `E/<task-id>/red.log`.
- Перед сдачей: полный фоновый прогон `scripts/test.sh` → `E/<task-id>/test.log`, 0 падений.
- Коммиты на английском, в конце:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01CnVd9Jtg2ZTpTDDTGgSHMC
  ```
- Документы — на русском, короткими фразами. Не выдумывать результаты: непроверенное помечать «не проверено».
- Разработчики идут по очереди: D2 начинает после коммита D1, D3 — после коммита D2.

---

## D1. Подсветка активной вкладки (1.1) и строка в README (1.5)

Task-id доказательств: `TAB`, `DOC`. Критерии: TAB-1…TAB-7, DOC-1, DOC-2.

1. `Sources/TabBarView.swift`: структура `TabAppearance(isActive:isKeyWindow:)` и цвет `EditorPalette.pageBackground` (`#ffffff` / `#1d2125`, ARCH 1.1). Комментарий в `Resources/web/editor.css:2–3` со ссылкой на константу. → XCT TAB-1 (новый класс `TabAppearanceTests`).
2. `TabItem`: фон из `TabAppearance`, полоса 2 pt сверху (`overlay(alignment: .top)`), цвет по `@Environment(\.controlActiveState)`, `.semibold` для активной, скрытый semibold-текст для постоянной ширины. → XCT TAB-6.
3. AX: `accessibilityAddTraits(.isSelected)` у активной, `accessibilityIdentifier("tab:<displayName>")` у всех. → XCT TAB-3.
4. Рендер полосы без экрана: 3 вкладки, 4 состояния через `.environment(\.colorScheme)` и `.environment(\.controlActiveState)`. Пиксельные проверки и PNG в `E/TAB/render-*.png`. → XCT TAB-2. Если `Color(nsColor:)` не следует `.colorScheme` в рендере — ставить `NSAppearance.current` на время рендера (ARCH 1.1, риски).
5. `ScrollViewReader` + `scrollTo(activeID)` (S). → FG TAB-7.
6. FG-шаг `scripts/fg/10-tab-screenshots.sh` и раздел в `FOREGROUND.md`: Debug-сборка с 3 файлами, `-MDEditorAppearance light|dark`, активное окно (приложение спереди) и неактивное (спереди Finder), снимок `screencapture -o -l <windowid>` (готовый `scripts/windowid.swift`). Плюс 2 и 10 вкладок, плюс узкое окно для TAB-7. В конце: выйти из Debug-приложения, вернуть исходное переднее приложение. → TAB-4, TAB-5, TAB-7.
7. `README.md`, раздел «Usage»: строка `alias lilamd='open -a LilaMD'` и фраза про `~/.zshrc`. `grep` в `E/DOC/grep.txt`. → DOC-1. Строку «Version 0.5» не трогать, записать замечание (DOC-2).
8. Полный фоновый прогон → `E/TAB/test.log`. Коммит.

Новые FG-тесты D1 (пропуск в фоне): перечислить в отчёте D1 для REG-3.

---

## D2. Close Tab (1.4) и правила macOS (1.3)

Task-id: `CLOSE`, `MAC`. Критерии: CLOSE-1…CLOSE-6, MAC-1…MAC-10.

### CLOSE

1. `AppDelegate.shared` (слабая ссылка, ставится в `applicationWillFinishLaunching`): тесту нужен экземпляр, его прячет `@NSApplicationDelegateAdaptor`.
2. Красный тест CLOSE-1 (фон): файл-вкладка в окне `AppDelegate`, вызов «File ▸ Close Tab» через `NSMenu.performActionForItem(at:)`, ждать `store.tabs` без этой вкладки (положительная проверка). До фикса — красный, лог в `E/CLOSE/red.log`. Тест в начале проверяет `NSApp.keyWindow == nil` (`XCTSkipUnless`), иначе он не проверяет нужную ветку. После теста закрыть все вкладки окна `AppDelegate` и спрятать окно.
3. Логи (ARCH 1.4, п. 1): вход `closeTab` (класс ключевого окна, `NSApp.isActive`), `closeActiveTab`, вход/выход `TabStore.close` с длительностью `flushEditor`.
4. Фикс `AppDelegate.closeTab`: выбор цели — чистая функция (3 случая, ARCH 1.4). → XCT CLOSE-1, CLOSE-2.
5. (S) `closing: Set<ID>` в `TabStore`: второй вызов ждёт первый. → XCT CLOSE-6.
6. Фоновая проба 100 запусков (XCT, отдельный тест, можно `-only-testing`): правка `execCommand('insertText')` → 0,3 / 2,0 с через раз → пункт меню → вкладка закрыта, файл содержит правку, `FakePrompter.calls` пуст. Лог счётчиков в `E/CLOSE/bg-100.log`. Длительность ~3–4 мин: в обычный прогон не включать (переменная окружения или отдельный класс, исключённый из схемы по умолчанию — решает D2, записывает в DEVELOPMENT.ru.md). → CLOSE-3.
7. FG-шаг `scripts/fg/20-close-100.sh`: Debug-сборка, 100 файлов, `log stream` в `E/CLOSE/fg/stream.log`, в каждом запуске правка, ⌘W (CGEvent) или клик меню через AX — через раз; проверка через AX (`tab:<имя>` нет) и SHA файла; незасчитанные запуски отдельно с причиной; итог `RESULT … pass=N fail=M skipped=K`. Цикл до 100 засчитанных. → CLOSE-4, CLOSE-5.

### MAC

8. `enum AppLinks` (repo, issues). `AboutPanel.options(info:)` и `CommandGroup(replacing: .appInfo)`. → XCT MAC-1.
9. `CommandGroup(replacing: .help)`: «LilaMD on GitHub», «Report an Issue». → XCT MAC-9.
10. Settings: XCT на меню приложения (MAC-8). Код только если тест красный.
11. Open Recent: тест на несуществующий путь (алерт строится, `runModal` не вызывается); `RecentDocuments.refresh()` после неудачного открытия. Отделить показ алерта от построения, чтобы тест не блокировался. → XCT MAC-6, MAC-7.
12. `WindowDragArea` в пустой части полосы (ARCH 1.3). Без `isMovableByWindowBackground`.
13. FG-шаг `scripts/fg/21-mac.sh`: снимок About (MAC-2); перетаскивание окна за заголовок и за пустую часть полосы, `frame` до/после (MAC-3, MAC-4); перетаскивание вкладки — порядок меняется, окно на месте; сброс `.md` на полосу; двойной клик (MAC-5); Open Recent с удалённым и перемещённым файлом — снимки алертов (MAC-6, MAC-7); клик по Help — URL вкладки браузера, вкладку закрыть (MAC-10). Open Recent требует записи в список: шаг запускает Debug-сборку с `-MDEditorRecordsRecents YES` и в конце чистит добавленные пути из Open Recent (`NSDocumentController` того же bundle id — это список установленного приложения).
14. Полный фоновый прогон → `E/CLOSE/test.log` (и копия в `E/MAC/test.log`). Коммит.

---

## D3. Ввод на других языках (1.2) и Mermaid / формулы (1.6)

Task-id: `IME`, `MER`. Критерии: IME-1…IME-10, MER-1…MER-5.

### IME

1. `Tests/IMETests.swift` на `EditorHarness`. Первый тест — IME-1: доказать путь композиции в фоне. Путь A: `webView.setMarkedText` / `insertText` (`NSTextInputClient`), счётчики `compositionstart` / `compositionend` в странице (слушатели ставит тест через `h.js`). Если счётчики 0 — путь B: JS-симуляция (ARCH 1.2). Записать в отчёт, какой путь работает.
2. Тесты IME-2…IME-5: 3 языка × 6 мест. Документ с абзацем, заголовком, таблицей, списком; отдельный документ, начинающийся с таблицы; пустой документ для «первой строки». Проверки — ARCH 1.2.
3. IME-6: `OpenDocument.autosaveDelay = 0.2 с` (вернуть в `tearDown`), композиция 1 с, затем коммит; текст один раз, файл = текст. Файл — временная копия, `samples/` не писать.
4. Если тест красный — фикс в `Resources/web/editor.js` (кандидат: `e.keyCode === 229` в фильтре строки 143), красный лог в `E/IME/red.log`. → IME-10.
5. FG-шаг `scripts/fg/30-ime-live.swift` (+ обёртка `.sh`):
   - записать включённые источники и текущий (`E/IME/fg/sources-before.txt`);
   - включить Pinyin – Simplified (`com.apple.inputmethod.SCIM.ITABC`) и Japanese Kana (`com.apple.inputmethod.Kotoeri.KanaTyping.Japanese`) через `TISEnableInputSource`, если их нет. ID сверить по `TISCreateInputSourceList` на этой macOS до написания шага;
   - Debug-сборка, `--args -MDEditorRecordsRecents NO`. Один временный файл на место: целевой блок — последний в файле (абзац, `# заголовок`, таблица, `- элемент`), для «первой строки» — пустой файл. Каретка — ⌘↓ (конец документа), без кликов по координатам;
   - для каждого источника (RussianWin, Pinyin, Kana) и 5 мест: выбрать источник (`TISSelectInputSource`), набрать CGEvent-ами (Pinyin: `nihao` + пробел; Kana: клавиши кана + Return), дождаться автосохранения, сверить файл, снять скриншот окна;
   - press-and-hold (IME-9, S);
   - `trap`: выйти из Debug-приложения, выключить включённые шагом источники, выбрать исходный, записать `sources-after.txt`, сравнить.
   → IME-7, IME-8, IME-9.

### MER

6. `samples/mermaid-math.md`: блок `mermaid`, блок `$$…$$`, строчная `$…$`.
7. `Tests/MermaidMathTests.swift` (фон): MER-1 (результат да/нет по каждому виду в `E/MER/result.txt`), MER-2, MER-3. Тест MER-1 проверяет факт и пишет его; он не падает, если формулы не рендерятся, — падает, только если проверка не смогла получить ответ (страница не готова, превью не найдено ни в каком виде).
8. Скриншоты MER-4: `WKWebView.takeSnapshot` в фоне; если картинка пустая — FG-шаг `scripts/fg/31-mermaid-shots.sh`.
9. `mathBlockPreview: true` — не включать без согласия Стаса. Подготовить ветку изменения и результат REG, записать в отчёт (MER-5).
10. Полный фоновый прогон → `E/IME/test.log`. Коммит.

---

## Сдача этапа

1. Оркестратор запускает пакет `FOREGROUND.md` (шаг 1 + шаги D1–D3), когда Стас отошёл.
2. Итоговый фоновый прогон → `E/final/test-bg.log` (REG-2, REG-3).
3. REPORT.md: таблица критериев со статусом и ссылкой на доказательство; непроверенное помечено.
