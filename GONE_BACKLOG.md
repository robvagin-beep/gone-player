# GONE Player — Backlog

> Живой документ. Пополняется вручную + из ChatGPT curator output.
> Задачи отсюда отправляются на GitHub через `claude-review` workflow (Anthropic API).
> Не трогать архитектурные инварианты — список в CLAUDE.md и GONE_CURATOR.md.

---

## Статусы

- `[ ]` — не начато
- `[~]` — в работе
- `[x]` — готово
- `[!]` — блокер / регрессия

---

## P0 — Блокеры / регрессии

_Сюда — только то что ломает существующее поведение._

- `[ ]` **Snap bolt активируется без треков** — молния включается при старте даже без загруженного плейлиста (`snapEnabled=true` из UserDefaults). Нужно: не запускать snap инфраструктуру пока `state.tracks.isEmpty`. Файлы: `GONEApp.swift`, `PlayerState.swift`.

---

## P1 — Продуктовые фичи (core use case)

### Маркировка треков
- `[ ]` Цветовые флаги в строке плейлиста — три цвета (зелёный / жёлтый / красный), клик по флагу в `PlaylistRowView`. Фильтр по цвету в шапке плейлиста. Session-only или сохранять в UserDefaults по URL трека. Файлы: `Track.swift`, `PlaylistView.swift`, `PlayerState+Playlists.swift`.

### Персистентная сессия
- `[ ]` При закрытии — сохранить список URL треков активной вкладки в UserDefaults. При следующем запуске — восстановить без диалога, тихо. Не база данных, просто `[URL]` в UserDefaults. Файлы: `PlayerState+Playlists.swift`, `GONEApp.swift`.

### Delta BPM в Split Mode
- `[ ]` В CrossfaderBandPanel или над кроссфейдером — показывать разницу темпа между A и B: `+2.3 BPM` или `= BPM`. Берётся из `primaryState.bpm` и `secondaryState?.bpm`. Файлы: `CrossfaderBandPanel.swift`, `SplitModeManager.swift`.

### A-B Loop
- `[ ]` Два маркера на waveform (точка A и точка B). Горячие клавиши для установки A/B. Пока оба выставлены — воспроизведение зацикливается между ними. Сброс при смене трека. Session-only, не персистировать. Файлы: `PlayerState.swift`, `WaveformView.swift`, `GONEApp.swift` (key monitor).

---

## P2 — Улучшения UX

- `[ ]` **History треков в сессии** — список последних N прослушанных треков (порядок воспроизведения). Быстрый возврат. Отдельная вкладка в плейлисте или dropdown.

- `[ ]` **Pinned folders** — запомнить 3-5 папок которые открываются часто. Показывать в пустом состоянии как быстрый старт. Файлы: `PlaylistView.swift`, `RootView.swift` (empty state).

- `[ ]` **Auto-gain / loudness match** — кнопка в TransportView которая выравнивает воспринимаемую громкость трека к -14 LUFS (или к текущему треку в primary). Через `AVAudioMixerNode` outputVolume, не нормализация файла.

- `[ ]` **FX selector — left/right click zones** `→ GITHUB` — визуально одна кнопка, левая половина = предыдущий FX, правая = следующий. Центральный текст по центру. Едва заметные шевроны как hint. `OFF` и `HOLD` не трогать. Файл: `EQPanelView.swift`.

- `[ ]` **Clone Mode exit button — active state** `→ GITHUB` — когда Clone Mode активен, кнопка выхода слишком бледная. Сделать ярче: strong white fill, высокий контраст. Поведение не менять. Файлы: `FullPlayerView.swift`, `TransportView.swift`.

- `[ ]` **Keyboard shortcuts overlay** — `?` или долгий тап на settings открывает список всех горячих клавиш. Текущее поколение: 1–8 hot cues, пробел, стрелки, hold-seek. Просто SwiftUI Sheet поверх.

- `[ ]` **BPM badge — tap to copy** — клик по BPM в хедере копирует значение в буфер. DJ часто пишет BPM в сетлист.

---

## P3 — Технический долг

- `[ ]` **Task cancellation handles** — `Task.detached` для BPM/waveform анализа не имеют stored handles. При быстром скролле анализ накапливается в фоне. Добавить `var analysisTask: Task<Void, Never>?` в `PlayerState`, отменять при `load()` / `deleteFromLibrary()`. Файлы: `PlayerState+Analysis.swift`.

- `[ ]` **`Task.sleep(nanoseconds:)` → `Task.sleep(for: .milliseconds(N))`** — deprecated API во всём проекте. Пройтись grep'ом и заменить. Файлы: множество.

- `[ ]` **Dual SnapState enums** — `WindowSnapManager.SnapState` и `PlayerState.SnapMode` функционально идентичны. Консолидировать при следующем касании snap системы.

- `[ ]` **`presentImportPanel` использует `NSApp.keyWindow`** — должен использовать `AppDelegate.resolvedMainWindow()`. Низкий риск но не правильно. Файл: `PlayerState+Playlists.swift`.

- `[ ]` **`splitPlaylistView` / `secondaryPlaylistTabId` в PlayerState** — orphan state, UI нет. Убрать или задокументировать будущее использование.

---

## P4 — Идеи / исследовать

_Не задачи, а направления. Обсудить перед реализацией._

- **Tempo-match helper** — при A/B сравнении в Split Mode одна кнопка выставляет pitch secondary плеера так чтобы BPM совпали. Не sync (нет beat grid), просто математика: `targetPitch = (primaryBPM / secondaryBPM - 1) * 100`.

- **Waveform overview mini-map** — над основным waveform тонкая полоска на всю длину трека с позицией. Для длинных треков (60+ мин) полезно.

- **Section detection** — автоматически найти intro / drop / outro по энергии. Показать как цветные зоны на waveform. Сложно, но ценно для prep.

---

## GITHUB Issues Queue

_Задачи готовы к отправке. Полный текст каждой — в `~/Desktop/GONE_FULL_AUDIT_TASKS.md`._
_Отправляются через `gh issue create` → label `claude-task` → Anthropic API обрабатывает в Actions._

| # | Задача | Приоритет | Статус |
|---|---|---|---|
| 18 | Deep audit: mini side player, waveform, BPM/BPA analysis, adaptive divisions | P1 | `[ ]` не отправлено |
| 19 | Fix raw waveform rendering + beat-anchored adaptive division grid | P1 | `[ ]` не отправлено |
| 20 | **Critical stability:** startup freeze, bulk import 10/50/100+ треков, Clone Mode exit crash, Refresh BPM | P0 | `[ ]` не отправлено |
| 21 | Side-collapse Y-anchor bug, Settings audit, Playstyle/EQ audit, DJ waveform ruler | P1 | `[ ]` не отправлено |
| 22 | Full architecture audit, legacy Mac performance, playlist scroll (Finder-like), docs/handoff | P2 | `[ ]` не отправлено |
| 23 | Restore vertical drag repositioning while snapped to right edge | P1 | `[ ]` не отправлено |
| 24 | Stabilize waveform grid drag glow — `isDragging` не должен светить все тики | P1 | `[ ]` не отправлено |
| 25 | Consolidate BPM + waveform + beat-grid scheduling — единый owner, cancellation handles | P0 | `[ ]` не отправлено |
| 26 | Clarify beat grid vs bar/downbeat semantics — beat phase ≠ downbeat | P1 | `[ ]` не отправлено |
| 27 | Audit window presence policy — `alwaysOnTop` vs fixed `GWindowLevel.player` | P2 | `[ ]` не отправлено |
| 28 | Replace audio singleton identity checks in views with explicit `PlayerRole` | P2 | `[ ]` не отправлено |
| 29 | Fix Timer rule violation — `Timer.scheduledTimer` в `ClickNSView` → `.common` | P1 | `[ ]` не отправлено |
| 30 | Make spectrum tap handoff thread-safe — double buffer, no render-thread race | P1 | `[ ]` не отправлено |
| 31 | FX selector left/right click zones — визуально одна кнопка, half-hit zones | P2 | `[ ]` не отправлено |
| 32 | Clone Mode exit button active state — ярче, насыщеннее, высокий контраст | P2 | `[ ]` не отправлено |

> **Порядок отправки (по приоритету):**
> **P0:** 20 → 25
> **P1:** 29 → 30 → 24 → 26 → 23 → 18 → 19
> **P2:** 28 → 27 → 21 → 31 → 32
> **P3:** 22

**Маппинг на существующие workflows:**

| Issue # | Workflow |
|---|---|
| 18 | `ui-audit.yml` + `bpm-analysis-audit.yml` |
| 19 | `beat-grid-audit.yml` + `beat-phase-audit.yml` |
| 20 | `hang-audit.yml` + `launch-perf-audit.yml` + `splitmode-audit.yml` + `playlist-audit.yml` |
| 21 | `snap-audit.yml` + `settings-audit.yml` + `ui-audit.yml` |
| 22 | `deep-codebase-audit.yml` + `memory-audit.yml` + `performance-audit.yml` |
| 23 | `snap-audit.yml` |
| 24 | `beat-grid-audit.yml` |
| 25 | `bpm-analysis-audit.yml` |
| 26 | `beat-phase-audit.yml` |
| 27 | `settings-audit.yml` |
| 28 | `deep-codebase-audit.yml` |
| 29 | `ui-audit.yml` |
| 30 | `audio-engine-audit.yml` |
| 31 | `ui-audit.yml` |
| 32 | `ui-audit.yml` |

---

## Из ChatGPT curator

_Сюда вставлять задачи из следующего curator output._

<!-- PASTE HERE -->

---

## Отправлено на GitHub

_Сюда переносить задачи после создания Issue._

| Issue # | GitHub Issue | Задача | Дата |
|---|---|---|---|
| — | — | — | — |

## Waveform v2 (queued 2026-06-11, Robert)
Research + redesign: текущая волна «не очень красивая, не хватает разделителей и долей,
секции-дольки». Industry-стандарт (Rekordbox/Serato/Traktor): 3-полосная цветная волна
(низ/середина/верх отдельными цветами или яркостью), beat-тики из beat grid (есть),
bar/phrase-разделители каждые 4/16 тактов, секции по энергии (intro/drop/outro зоны).
У нас уже есть: beatGridOffset+confidence, 84-bar RMS waveform, computeWaveformFromSamples
с HPF-деэмфазом. План: research-сессия как с BPM (Mixxx waveform renderer, Serato
3-band approach), затем: (1) многополосная волна из того же decode-прохода,
(2) bar-разделители от beat grid, (3) phrase-секции по энергетическим переходам.
