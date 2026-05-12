# GONE Player — Task Queue · Beta 0.8 → 0.9

> Документ для Claude Code. Читать целиком перед любой правкой.
> Задачи выполнять последовательно, по одной. После каждой — Build Succeeded.
> Не трогать то, что не упомянуто явно.

---

## Глобальные правила (не нарушать)

1. **Аудио граф — порядок фиксирован навсегда:**
   `playerNode → speedNode → pitchNode → hpfNode → lpfNode → eqNode → distortionNode → delayNode → reverbNode → gateNode → mainMixerNode`

2. **Два engine-инстанса:** `AudioEngineNext.shared` (primary) + `AudioEngineNext.secondary` (clone). В views и extensions — только `state.audioEngine`, никогда `.shared` напрямую.

3. **Таймеры:** `RunLoop.main.add(timer, forMode: .common)` + `MainActor.assumeIsolated` внутри callback. Никогда `Timer.scheduledTimer` без RunLoop.

4. **progressFeed / spectrumFeed** — per-player инстансы (`state.progressFeed`, `state.spectrumFeed`). `.shared` синглтоны существуют только для PeekPanel и SpectrumView default param — не удалять.

5. **WindowSnapManager state machine** — не трогать без полного прочтения файла. Последовательность: `isSnapping → slideOffScreen → prepareForSnap → snapState=.docked → lockFrame → isSnapping=false`.

6. **`windowResizability(.automatic)`** и **`isMovableByWindowBackground = false`** — не менять.

7. **`updateWindowSize`** — вызывать только из `RootView.onChange`, не дублировать.

8. **Нет внешних зависимостей** — 100% Apple frameworks.

---

## Уже закрыто — не переоткрывать

- `onSpectrum` main-hop — есть, симметричен с `onProgress`. Не трогать.
- `playbackToken` / `bumpToken()` pattern — верифицирован, не флагировать.
- `AudioEngineNext.deinit` — статические синглтоны, deinit никогда не вызывается. Весь код там — defensive dead code.
- `DispatchQueue.main.async` без `MainActor.assumeIsolated` в `SplitModeManager` callbacks — закрыто в Beta 0.8.
- `Task.detached` для cache flush в `applicationWillTerminate` — закрыто в Beta 0.8.
- Hot cues reset при смене трека — закрыто в Beta 0.8.
- Дублированные записи в `PlaybackProgressFeed.shared` / `SpectrumFeed.shared` из onProgress/onSpectrum — закрыто в Beta 0.8.

---

## П1 — Snap bolt без треков [P0 · Blocker]

**Файлы:** `GONEApp.swift`, `PlayerState.swift`

**Проблема:** `snapEnabled = true` читается из UserDefaults при старте. Snap-инфраструктура запускается даже если `state.tracks.isEmpty` — молния появляется и snap может активироваться в пустом состоянии.

**Что сделать:**
В `GONEApp.swift` в месте где читается / устанавливается `snapEnabled` добавить guard:
```swift
// Не активировать snap если нет треков
guard !state.tracks.isEmpty else { return }
```
Также в `WindowSnapManager` — если `state.tracks.isEmpty`, игнорировать активацию snap (ранний return в `dock()`).

---

## П2 — Analysis task cancellation [P0 · Blocker]

**Файлы:** `PlayerState+Analysis.swift`, `PlayerState.swift`

**Проблема:** `scheduleBPMAnalysis` и `reanalyzeBPMDeep` запускают `Task.detached` без сохранения handle. При быстром переключении треков несколько аналайзеров работают параллельно — последний записывает BPM поверх правильного.

**Что сделать:**

В `PlayerState.swift` добавить хранилище handles:
```swift
private var analysisTasksByTrack: [UUID: Task<Void, Never>] = [:]
```

В `PlayerState+Analysis.swift`:
- В `scheduleBPMAnalysis(for track:)` перед запуском Task: `analysisTasksByTrack[track.id]?.cancel()`
- Сохранять новый handle: `analysisTasksByTrack[track.id] = Task.detached { ... }`
- Внутри Task в AVAssetReader read loop: `guard !Task.isCancelled else { return }`
- В `reanalyzeBPMDeep(for:)` — то же самое
- В `load()` и `deleteFromLibrary()` — отменять handle при уходе трека:
  ```swift
  analysisTasksByTrack[id]?.cancel()
  analysisTasksByTrack.removeValue(forKey: id)
  ```

---

## П3 — PlaybackProgressFeed: один broadcast на фрейм [P2 · Performance]

**Файлы:** `PlaybackProgressFeed.swift`, `GONEApp.swift`, `SplitModeManager.swift`

**Проблема:** `progress` и `currentTime` — оба `@Published`, пишутся back-to-back в `onProgress` (24Hz). Это 2 `objectWillChange` на каждый фрейм — все подписанные views рендерятся дважды.

**Что сделать:**

В `PlaybackProgressFeed.swift`:
```swift
// Заменить два @Published на один метод
private(set) var progress: Double = 0
private(set) var currentTime: Double = 0

func update(progress p: Double, currentTime t: Double) {
    progress = p
    currentTime = t
    objectWillChange.send()
}
```

В `GONEApp.swift` и `SplitModeManager.swift` — заменить двойную запись на один вызов `feed.update(progress:currentTime:)`.

---

## П4 — O(N) `current` в 60Hz таймерах [P2 · Performance]

**Файлы:** `PlayerState.swift`

**Проблема:** `var current: Track? { tracks.first { $0.id == currentId } }` — O(N) по всему массиву. Вызывается из LFO-таймера, bpmChop-таймера, slicer-таймера — то есть до 60 раз в секунду. На библиотеке из 1000 треков = 60K итераций/сек.

**Что сделать:**

Добавить в `PlayerState.swift` приватный индекс:
```swift
private var trackIndex: [UUID: Int] = [:]
```

Поддерживать его синхронно с `tracks` — при любом изменении массива:
```swift
private func rebuildIndex() {
    trackIndex = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
}
```

`current` переписать:
```swift
var current: Track? {
    guard let id = currentId, let i = trackIndex[id] else { return nil }
    return tracks[i]
}
```

Вызывать `rebuildIndex()` в конце каждого места где меняется `tracks`.

---

## П5 — AnalysisCache: eviction + purge [P2 · Tech debt]

**Файлы:** `AnalysisCache.swift`

**Проблема:** `[String: AnalysisCacheEntry]` растёт бесконечно. Удалённые треки остаются. При большой библиотеке — многомегабайтный JSON на каждый flush.

**Что сделать:**
1. В `load()` после декодирования — прогнать по ключам и удалить те, где файл больше не существует:
   ```swift
   cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
   ```
2. Добавить мягкий LRU cap: если `cache.count > 20_000` — удалить самые старые по `lastAccessed` (нужно добавить поле `lastAccessed: Date` в `AnalysisCacheEntry`).

---

## П6 — Цветовые флаги треков [P1 · Feature]

**Файлы:** `Track.swift`, `PlaylistView.swift`, `PlayerState+Playlists.swift`

**Что делает:** Три флага (зелёный / жёлтый / красный) в строке плейлиста. Клик по флагу — переключить. Session-only (UserDefaults по URL трека если хочется персистентность, иначе в памяти). Фильтр по цвету в шапке плейлиста — опционально в первой итерации.

**Что сделать:**

В `Track.swift`:
```swift
enum TrackFlag: String, Codable { case none, green, yellow, red }
var flag: TrackFlag = .none
```

В `PlaylistRowView` (внутри `PlaylistView.swift`) — маленький цветной кружок справа от BPM. Tap меняет `flag` по кругу: none → green → yellow → red → none. Размер 8pt, цвет из `G.*` токенов.

---

## П7 — Персистентная сессия [P1 · Feature]

**Файлы:** `PlayerState+Playlists.swift`, `GONEApp.swift`

**Что делает:** При закрытии приложения — сохранить `[URL]` активной вкладки в `UserDefaults`. При следующем запуске — тихо восстановить без диалога.

**Что сделать:**

В `PlayerState+Playlists.swift`:
```swift
func saveSession() {
    let urls = currentTabTracks().compactMap { $0.url?.absoluteString }
    UserDefaults.standard.set(urls, forKey: "lastSession")
}

func restoreSession() {
    guard let strings = UserDefaults.standard.stringArray(forKey: "lastSession") else { return }
    let urls = strings.compactMap { URL(string: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !urls.isEmpty else { return }
    importURLs(urls)
}
```

В `GONEApp.swift`:
- `applicationWillTerminate` → вызвать `state.saveSession()`
- `applicationDidFinishLaunching` → вызвать `state.restoreSession()`

---

## П8 — Delta BPM в Split Mode [P1 · Feature]

**Файлы:** `CrossfaderBandPanel.swift`, `SplitModeManager.swift`

**Что делает:** Над линией кроссфейдера — текстовая метка `+2.3 BPM` или `= BPM` показывает разницу между primary и secondary. Обновляется при изменении BPM любого из плееров.

**Что сделать:**

В `SplitModeManager.swift` добавить computed property:
```swift
var bpmDelta: Double? {
    guard let a = primaryState?.bpm, let b = secondaryState?.bpm,
          a > 0, b > 0 else { return nil }
    return b - a
}
```

В `CrossfaderBridgeView` Canvas — нарисовать текст над центральной точкой кроссфейдера. Шрифт `G.mono(11)`, цвет `G.textSecondary`. Формат: `"= BPM"` если `abs(delta) < 0.1`, иначе `"+2.3"` / `"-2.3"`.

---

## П9 — A-B Loop [P1 · Feature]

**Файлы:** `PlayerState.swift`, `WaveformView.swift`, `GONEApp.swift`

**Что делает:** Два маркера на waveform. Горячие клавиши. Пока оба выставлены — воспроизведение зацикливается. Сброс при смене трека. Session-only.

**Что сделать:**

В `PlayerState.swift`:
```swift
var loopA: Double? = nil  // позиция в секундах
var loopB: Double? = nil

func setLoopPoint(at time: Double) {
    if loopA == nil { loopA = time }
    else if loopB == nil { loopB = time; if loopB! < loopA! { swap(&loopA, &loopB) } }
    else { loopA = time; loopB = nil }
}
func clearLoop() { loopA = nil; loopB = nil }
```

В `PlayerState+Playback.swift` — в `load()` добавить `clearLoop()`.

В `GONEApp.swift` key monitor — клавиша `[` ставит A, `]` ставит B, `\` сбрасывает.

В `WaveformView.swift` — рисовать два маркера: тонкая вертикальная линия + заливка между ними (полупрозрачный accent). Только если оба выставлены.

В прогресс-колбэке — если оба маркера выставлены и `currentTime >= loopB`, делать `seek(to: loopA!)`.

---

## П10 — Vertical drag while snapped [P1 · Bug]

**Файлы:** `WindowSnapManager.swift`, `RootView.swift`

**Проблема:** Когда окно приклеено к правому краю (`.docked`), вертикальное перетаскивание по Y не работает — окно не двигается вдоль края.

**Что сделать:**

В `WindowSnapManager.swift` в обработчике drag gesture (или в `RootView.swift` где обрабатывается drag): если `snapState == .docked`, разрешить движение по оси Y, обновляя `window.setFrameOrigin()` с фиксированным X (прижатым к краю экрана) и изменяемым Y. Не трогать `lockFrame` по X.

---

## П11 — Waveform drag glow только на активном тике [P1 · Bug]

**Файлы:** `WaveformView.swift`

**Проблема:** Флаг `isDragging` в Canvas включает glow / подсветку на всех тиках, а не только на том, по которому идёт drag.

**Что сделать:**

Заменить `isDragging: Bool` на `dragPosition: Double?` (нормализованная позиция 0..1 или `nil` если не dragging). В Canvas — подсвечивать только тик, ближайший к `dragPosition`. Все остальные тики рисуются без glow.

---

## П12 — FX selector: left/right click zones [P2 · UX]

**Файлы:** `EQPanelView.swift`

**Что делает:** Визуально одна кнопка. Клик по левой половине = предыдущий FX, по правой = следующий. Едва заметные шевроны `‹` и `›` как hint по бокам. Центральный текст по центру.

**Что сделать:**

В `EQPanelView.swift` найти кнопку переключения FX. Разбить tap gesture на два через `DragGesture(minimumDistance: 0)` + проверка `location.x < buttonWidth/2` → prev, иначе → next. Добавить Text `‹` слева и `›` справа с opacity 0.3.

---

## П13 — Clone Mode exit button: активный стейт [P2 · UX]

**Файлы:** `FullPlayerView.swift` или `TransportView.swift`

**Проблема:** Кнопка выхода из Clone Mode слишком бледная когда Split Mode активен.

**Что сделать:**

Найти кнопку деактивации Split Mode. Когда `SplitModeManager.shared.isActive == true` — использовать `foregroundColor(.white)` с opacity 1.0 вместо текущего приглушённого цвета. Добавить тонкое white fill или border чтобы кнопка читалась.

---

## П14 — BPM badge: tap to copy [P2 · UX]

**Файлы:** `TrackHeaderView.swift`

**Что делает:** Клик по BPM-метке в хедере копирует значение в буфер обмена.

**Что сделать:**
```swift
.onTapGesture {
    if let bpm = state.current?.bpm, bpm > 0 {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(format: "%.1f", bpm), forType: .string)
    }
}
```

---

## П15 — `Task.sleep(nanoseconds:)` → современный API [P3 · Tech debt]

**Файлы:** все, где встречается

**Что сделать:**
```bash
grep -rn "Task.sleep(nanoseconds:" GONE/
```
Заменить каждый на `try? await Task.sleep(for: .milliseconds(N))` где N = nanoseconds / 1_000_000.

---

## П16 — `presentImportPanel` через `resolvedMainWindow` [P3 · Tech debt]

**Файлы:** `PlayerState+Playlists.swift`

**Проблема:** `presentImportPanel` использует `NSApp.keyWindow` напрямую вместо `AppDelegate.resolvedMainWindow()`.

**Что сделать:** Заменить `NSApp.keyWindow` на `AppDelegate.shared?.resolvedMainWindow()` (или через `WindowSnapManager.shared.currentWindow`).

---

## П17 — Dual SnapState enums [P3 · Tech debt]

**Файлы:** `WindowSnapManager.swift`, `PlayerState.swift`

**Проблема:** `WindowSnapManager.SnapState` и `PlayerState.SnapMode` функционально идентичны. Дублирование.

**Что сделать:** Убрать `PlayerState.SnapMode`, везде где он используется — перейти на `WindowSnapManager.SnapState`. Делать только если никакая другая задача не трогает snap в этой же сессии.

---

## П18 — Orphan state: splitPlaylistView [P3 · Tech debt]

**Файлы:** `PlayerState.swift`

**Проблема:** `splitPlaylistView` и `secondaryPlaylistTabId` — объявлены, нигде не используются в UI.

**Что сделать:** Удалить оба свойства если нет планов по их использованию. Или добавить `// TODO: secondary player playlist tab` комментарий если будут нужны.

---

## Порядок выполнения

Строго последовательно. Каждый пункт — отдельный Build + ручная проверка:

```
П1 → Build → П2 → Build → П3 → Build → П4 → Build → П5 → Build
→ П6 → Build → П7 → Build → П8 → Build → П9 → Build → П10 → Build
→ П11 → Build → П12 → Build → П13 → Build → П14 → Build
→ П15 → Build → П16 → Build → П17 → Build → П18 → Build
```

**Ручная проверка обязательна после:**
- П1 (проверить что snap не активируется при пустом плейлисте)
- П2 (загрузить 5 треков, быстро переключать, BPM должен быть правильным)
- П9 (проверить loop в обоих плеерах Split Mode)
- П10 (snap + вертикальный drag)

---

*Текущая ветка: `dev`. Целевая упаковка: Beta 0.9 DMG.*
