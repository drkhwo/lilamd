# LilaMD 0.6–0.7: задачи по релизам

Источники: `docs/plans/0.6-0.7-PLAN.md`, `ACCEPTANCE.md`, `ARCH.md` (все в `docs/plans/`).
Базовая линия: 48 тестов, 0 падений, 74,5 с. Лог: `~/dev/QA/2026-11-04-lilamd-0.6-0.7/baseline/test.log`.

Правила для всех задач:
- Работать только в этом worktree. Не делать `git push`.
- Не запускать `scripts/smoke.sh` и `scripts/set-default.sh`. Не копировать ничего в `/Applications`.
- Один прогон XCTest за раз (тесты открывают настоящие окна).
- Команда тестов: `xcodegen generate && xcodebuild -project MDEditor.xcodeproj -scheme MDEditor -derivedDataPath build/dd test 2>&1 | tail -80`.
- Доказательства (логи, скриншоты): `~/dev/QA/2026-11-04-lilamd-0.6-0.7/<R1|R2|R3>/`.
- Номер версии не менять, пока Стас не назовёт его (см. противоречие C-11).

## Противоречия между ACCEPTANCE и ARCH

Правило: техника — по ARCH, поведение — по ACCEPTANCE. Исключения указаны.

| # | Где | Суть | Решение |
|---|---|---|---|
| C-1 | Z-2 и ARCH 1.2 | ACCEPTANCE: `next(1.5) == 1.5`, `previous(0.8) == 0.8`. ARCH: на краю `nil`. | Техника. Берём ARCH: `nil` на краю. Тест Z-2 пишется под `nil`. Поведение (края не двигаются, пункт меню неактивен) то же. |
| C-2 | TB-11, TB-30, TB-39 против TB-0, TB-32 и ARCH 2.1 | TB-11/30/39 ждут вопроса «Сохранить?» для таба с правками. TB-0 и план велят сохранить автосохранение. С автосохранением файл с путём пишется молча. | Берём автосохранение (это требование плана и TB-0). Вопрос «Сохранить?» (Save / Don't Save / Cancel) задаётся для Untitled с текстом и при неудачной записи. Для файла с путём ⌘W и ⌘Q сначала пишут файл, потом закрывают. TB-11/30/39 надо переписать. **Решено Стасом 05.11:** автосохранение без вопроса, как в Notes (ROUND2.md, решение 1). ⌘W, Close Others / to the Right, красная кнопка и ⌘Q сначала пишут файл, потом закрывают. Вопрос — только Untitled с текстом и неудачная запись. TB-11, TB-13, TB-30, TB-39 переписаны. |
| C-3 | TB-13 | Close Others и Close Tabs to the Right спрашивают «Сохранить?» по каждому dirty-табу. | Следует из C-2: те же правила, что для ⌘W. После решения 05.11 вопрос только по Untitled с текстом. |
| C-4 | TB-19 и ARCH 2.3 | TB-19: меню не ищет контроллер по иерархии окна. ARCH: `forKeyWindow()` сначала берёт `MainWindowController.store.active`, иначе ищет по иерархии, пропуская скрытые. | Техника. Берём ARCH. Без запасного поиска `EditorHarness` (REG-7, `testB7_undoRedo`) не найдёт контроллер. Отступление записать в `DEVELOPMENT.ru.md`. |
| C-5 | PLAN и ARCH 1.6 | План: шим в `speedUp`. ARCH: на верхнем уровне IIFE в `editor.js`. | Техника. Берём ARCH: `speedUp` вызывается на каждый экземпляр Vditor, слушатель размножился бы. |
| C-6 | PLAN и ARCH 1.6 | План: синтетическое событие с `metaKey: true`. ARCH: то же без `altKey`, по `e.code`. | Берём ARCH. |
| C-7 | PLAN и ARCH 2.2 | План: `Window` + `NSApplicationDelegateAdaptor`. ARCH: окно держит `AppDelegate` (`MainWindowController`), в сцене только `Settings`. | Техника. Берём ARCH (Finder при закрытом окне, `windowShouldClose`, тесты). |
| C-8 | Z-8 и ARCH, раздел 3 | Z-8 — «два окна». Меню в `EditorHarness` не SwiftUI, цепочка `@AppStorage` → `pageZoom` в XCTest не видна. | XCT проверяет `UserDefaults` и `setZoom`. Z-8 остаётся ручной проверкой (R2) и `TabWindowTests` (R3, TB-26). |
| C-9 | ARCH 1.4 и 1.1 | `setZoom` имеет `guard newZoom != zoom`. После падения веб-процесса или перезагрузки страницы `pageZoom` может сброситься, а guard не даст применить его снова. | Техника, уточнение. В обработчике `ready` и в `webViewWebContentProcessDidTerminate` ставить `webView.pageZoom = zoom` напрямую, мимо guard. Добавить тест. |
| C-10 | TB-0 и ARCH 2.1 | ARCH ссылается на зонды P1–P6 из отдельного AppKit-приложения. TB-0 требует наблюдение на текущей сборке. | Логи зондов (`.../arch/`) — достаточное наблюдение для строк «автосохранение, Versions, Untitled, меню File». Строки «переименование из заголовка» и «закрытие последнего окна» ARCH сам помечает как не проверенные. Их надо проверить вручную и приложить скриншот. |
| C-11 | PLAN | И R1, и R2 названы «0.6». Каждая часть — отдельный релиз. | Версии не назначены. Не менять `MARKETING_VERSION`, пока Стас не скажет. |
| C-12 | ACCEPTANCE (samples) | ACCEPTANCE требует файлы с BOM и без финального перевода строки. В `samples/` их нет (есть `big, crlf, cyrillic, empty, sample, pic.png`). | Тесты создают эти файлы во временной папке. В `samples/` ничего не писать, кроме `wide-table.md` (R1). |
| C-13 | ARCH 1.5 | ⇧⌘= (колонка) может не работать уже в 0.5.1, если настоящая клавиатура даёт `"+"`. | Не регрессия R2. Проверить вручную на 0.5.1 до R2, результат записать в «Известные ограничения». |

Открытые вопросы, которые держат работу:
1. Подтвердить C-2 (автосохранение и вопрос «Сохранить?»). Держит R3, шаг 3. **Решено 05.11:** автосохранение без вопроса.
2. Подтвердить порог Z-16 (медиана ≤ 31 мс на 150 %). Держит R2, ручной замер.
3. Подтвердить, что потеря Versions / Rename / Duplicate / Revert принята (ARCH 2.1). Держит R3, шаг 0.
4. Назвать версии для R1 и R2 (C-11).

---

## R1 «tables»: перенос текста в ячейках

Владелец: Codex dev. Оценка: 0,5 дня. Зависимости: нет.

| # | Задача | Файлы | Критерии | Проверка |
|---|---|---|---|---|
| R1-1 | Создать `samples/wide-table.md`: (a) 3 колонки, в одной ячейке абзац ~400 символов; (b) ячейка с URL без пробелов ~120 символов; (c) 12 колонок с короткими значениями. Добавить колонку с выравниванием `:---:` и `---:` хотя бы в одной таблице. | `samples/wide-table.md` | T-7, T-8, T-11 | Файл открывается в приложении. Строки таблиц однострочные. |
| R1-2 | Скриншоты «до» (светлая и тёмная тема, 1100×800) на старом CSS. Снять до правки CSS. | доказательства R1 | T-10 | 2 файла в папке R1. |
| R1-3 | Тесты (красные до правки CSS): `Round4Tests` — T-1 (`whiteSpace`, `overflowWrap`, `minWidth` у `td` и `th`), T-2, T-3, T-4, T-5, T-6, T-7, T-8, T-9 (вариант с длинным текстом в первой ячейке). | `Tests/Round4Tests.swift` (новый) | T-1…T-9 | Прогон: T-1…T-4 красные, остальные зелёные или красные по причине. Лог в R1. |
| R1-4 | Правка CSS: одно правило `td/th` из плана. | `Resources/web/editor.css` | T-1…T-5 | `Round4Tests` зелёный. |
| R1-5 | Полный прогон тестов. Скриншоты «после» (4 шт.), 12-колоночная таблица, выравнивание. | доказательства R1 | REG-1…REG-12, T-10, T-11 | Число тестов ≥ 49. 0 падений. Лог в R1. |

Что не трогать: `Resources/vditor/*`, `Sources/*`, `SourcePreserver`, `Round2Tests`, `Round3Tests`.

---

## R2 «zoom»: масштаб текста

Владелец: Codex dev. Оценка: 1 день. Зависимости: R1 смержен или независим (файлы не пересекаются, кроме `Round4Tests.swift`).

| # | Задача | Файлы | Критерии | Проверка |
|---|---|---|---|---|
| R2-0 | До кода: `grep "⌥⌘" Resources/vditor/dist/index.js` и проверка, что `matchHotKey` принимает синтетическое событие. Записать команду и результат в `DEVELOPMENT.ru.md`. Проверить вручную на 0.5.1 поведение ⇧⌘= (C-13). | `docs/DEVELOPMENT.ru.md` | Z-14 | Строка с командой и результатом в документе. |
| R2-1 | `Sources/Zoom.swift`: `ZoomPreference` по ARCH 1.2 (`next/previous` возвращают `nil` на краю). | `Sources/Zoom.swift` (новый) | Z-1, Z-2 | `testZoomLadder` зелёный. |
| R2-2 | `EditorController.setZoom` + повторная установка в `ready` и после падения веб-процесса (C-9). | `Sources/EditorController.swift` | Z-3, Z-10 | `testSetZoomScalesPage`, `testZoomSurvivesModeSwitch`. |
| R2-3 | Передача `zoom` в `EditorView`/`DocumentWindow` (`makeNSView` и `updateNSView`). | `Sources/EditorView.swift` | Z-8, Z-9 | Ручная проверка Z-8, Z-9. |
| R2-4 | Меню View: Zoom In, Zoom Out, Actual Size, подменю Zoom (ARCH 1.3). | `Sources/MDEditorApp.swift` | Z-4…Z-7 | `testZoomMenuItems`. Скриншоты меню. |
| R2-5 | Шим ⌥⌘= / ⌥⌘− в `editor.js` (ARCH 1.6). | `Resources/web/editor.js` | Z-12 | `testOptCmdMinusDeletesRow`, `testOptCmdEqualsRaisesHeading`. |
| R2-6 | `Support.swift`: параметр `ignoringModifiers` у `key`. Перевести `Round3Tests.testCmdEqualsAddsOnlyTheRow` на ⌥⌘=. | `Tests/Support.swift`, `Tests/Round3Tests.swift` | REG-9 | Тест зелёный. |
| R2-7 | Тесты клавиш: `testMenuDoesNotTakeShiftOrOptionCmdEquals`, `testCmdEqualsZoomsAndDoesNotAddRow`, `testCmdMinusInHeadingZoomsOnly`, `testCmdEqualsAtMaxZoomDoesNothing`, `testShiftCmdEqualsObservation`. `setUp`/`tearDown` возвращают `editorZoom`. | `Tests/Round4Tests.swift` | Z-6, Z-11, Z-13 | Зелёные. Если `testCmdEqualsAtMaxZoomDoesNothing` падает — запасная ветка шима (ARCH 1.6, последний пункт). |
| R2-8 | Ручные проверки: Z-15 (подсказки на 80/100/150 %), Z-16 (C6 на 150 %, 5 прогонов, без `smoke.sh` — ручной замер из тестового хоста или `testC6` с `setZoom(1.5)`), Z-17, раскладки U.S. и RussianWin для ⌘=, ⇧⌘=, ⌥⌘=. | доказательства R2 | Z-15, Z-16, Z-17 | Скриншоты и значения в папке R2. |
| R2-9 | README и `DEVELOPMENT.ru.md`: новые клавиши, перенос табличных на ⌥⌘=, раздел «Решения». | `README.md`, `docs/DEVELOPMENT.ru.md` | Z-18 | Ревью. |
| R2-10 | Полный прогон тестов. | — | REG-1…REG-12 | 0 падений, число тестов ≥ 48. |

Что не трогать: `Resources/vditor/*`, `SourcePreserver`, `FileWatcher`, `MarkdownDocument`, CSS таблиц (R1).

---

## R3 «tabs»: своя панель табов

Владелец: Claude dev. Оценка: 1–2 недели. Зависимости: R1 и R2 смержены. Вопросы 1 и 3 решены.

| # | Шаг | Задача | Файлы | Критерии | Проверка |
|---|---|---|---|---|---|
| R3-0 | 0 | Таблица «было / будет» в `DEVELOPMENT.ru.md` по ARCH 2.1. Проверить вручную строки без наблюдения (C-10). Скриншот меню File на 0.5.1. | `docs/DEVELOPMENT.ru.md`, доказательства R3 | TB-0 | Ревью. |
| R3-1 | 1 | `SavePrompting` + фейк в `Tests/Support.swift`. | `Sources/SavePrompter.swift`, `Tests/Support.swift` | TB-11 (модель) | Компилируется. |
| R3-2 | 1 | `OpenDocument`: чтение/запись через `MarkdownDocument`, `isDirty`, `savedText`, `diskData`, запись по ARCH 2.4. | `Sources/OpenDocument.swift` | TB-4, TB-20, TB-21, TB-25, TB-28 | `TabStoreTests`. |
| R3-3 | 1 | `TabStore`: `open` (дедуп по ARCH 2.3), `newUntitled`, `activate`, `activateNext/Previous`, `close`, `closeOthers`, `closeToTheRight`, `move`, `saveAll`, `prepareToQuit`. | `Sources/TabStore.swift` | TB-3, TB-22, TB-8 (модель), TB-13 (модель) | `TabStoreTests`. |
| R3-4 | 1 | `TabStoreTests`: все пункты из ARCH 3 для файла `Tests/TabStoreTests.swift`. Файлы — копии во временной папке. | `Tests/TabStoreTests.swift` | TB-3, 4, 20, 21, 22, 28 | Зелёные. Старые 48 тестов зелёные. |
| R3-5 | 2 | `AppDelegate`, `MainWindowController`, `TabbedWindow`, `TabBarView` (без перетаскивания), новый `EditorView` (контейнер, `isActive`), `MDEditorApp` без `DocumentGroup` (`Settings`-сцена с `.commands`). Убрать `FileDocument` из `MarkdownDocument`. | `Sources/AppDelegate.swift`, `MainWindowController.swift`, `TabBarView.swift`, `EditorView.swift`, `MDEditorApp.swift`, `MarkdownDocument.swift` | TB-1, 2, 6, 15, 16, 17, 18, 19, 26, 33 | `TabWindowTests` + все старые тесты. Вручную: `open -a` сборкой из `build/dd` на 3 файла → одно окно. |
| R3-6 | 2 | `EditorController.forKeyWindow()` по ARCH 2.3 (C-4). Подкласс `EditorWebView` для drop файлов. | `Sources/EditorController.swift` | TB-5 (drop), TB-18, TB-19 | `testB7_undoRedo` зелёный. |
| R3-7 | 2 | Проверить риск `.commands` на `Settings` и тулбар через `sceneBridgingOptions`. Запасные варианты — по ARCH 2.2 и 2.3. | `Sources/MDEditorApp.swift` | TB-27 | Тест: File → Close Tab ровно один раз, нет Close All, Duplicate, Rename…. |
| R3-8 | 3 | Запись, автосохранение (2 с), закрытие, выход, Save As, ⌘W, красная кнопка (`windowShouldClose`), `applicationShouldTerminate`. | `OpenDocument.swift`, `TabStore.swift`, `MainWindowController.swift`, `AppDelegate.swift` | TB-10, 11, 12, 28, 29, 30, 31 | `TabStoreTests`, `TabWindowTests` (⌘W, ⌘S через `NSApp.sendEvent`). Ручной прогон с SHA-256. Требует ответа на вопрос 1. |
| R3-9 | 4 | `FileWatcher` на колбэках (`knownData`, `isDirty`, `reload`, `conflict`). Отложенный конфликт для скрытого таба. | `Sources/FileWatcher.swift`, `OpenDocument.swift` | TB-23, 24, 25, REG-5, REG-6 | `FileWatcherTests`, `Round2Tests`. |
| R3-10 | 5 | Меню File (New, Open, Open Recent, Save, Save As, Close Tab), Show Next/Previous Tab (⌃Tab, ⇧⌘], ⌃⇧Tab, ⇧⌘[), контекстное меню, перетаскивание табов и файлов. | `MDEditorApp.swift`, `TabBarView.swift`, `MainWindowController.swift` | TB-5, 7, 8, 9, 13, 14, 27 | `TabWindowTests` (клавиши, ⌃Tab в ячейке не двигает каретку). Остальное — ручной чек-лист со скриншотами. |
| R3-11 | 6 | Правка `scripts/smoke.sh` и `windowid.swift` под одно окно. **Без запуска.** | `scripts/smoke.sh`, `scripts/windowid.swift` | TB-37 (правка) | Ревью диффа. Запуск делает Стас. |
| R3-12 | — | Замер памяти: 10 табов с `big.md`, `ps -o rss= -p <pid>` после активации каждого. При > 1,5 ГБ — выгрузка WebView. Замер TB-38. | `docs/DEVELOPMENT.ru.md`, доказательства R3 | TB-36, TB-38 | Команда и значение в документе. |
| R3-13 | — | README: потеря Versions, Rename, Duplicate, Revert; не проверено: iCloud Drive и сетевые диски. | `README.md`, `docs/DEVELOPMENT.ru.md` | TB-32 | Ревью. |
| R3-14 | — | Итоговый прогон: 48+ тестов зелёные, ручной чек-лист R3, единый прогон TB-39 с SHA-256. | доказательства R3 | TB-1…TB-39, REG-1…REG-12 | Лог, скриншоты, хеши. |

Что не трогать в R3: `Resources/vditor/*`, `SourcePreserver.swift`, `SchemeHandler.swift`, `EditorMode.swift`, `Zoom.swift` (кроме чтения), CSS таблиц. `Tests/Support.swift` менять только добавлением (`EditorHarness` работает с `EditorController` напрямую).
