# GONE Player — Tasks for Codex

> **Перед стартом:** прочитай `CLAUDE.md` в этой же папке — там контекст продукта, архитектурные правила и список файлов.
>
> SourceKit errors "Cannot find type X in scope" — **ложные**. Проект компилируется нормально в Xcode. Игнорировать.
>
> Не добавляй новые функции. Не трогай `WindowSnapManager.swift`, `AudioEngine.next.swift`, `updateWindowSize` в `RootView.swift`, `configureWindow` в `GONEApp.swift`.

---

## Task 1 — Playlist Tab Bar (подключить существующие компоненты)

**Файл:** `~/Desktop/GONE/GONE/PlaylistView.swift`

Компоненты уже написаны: `PlaylistFolderTab`, `NewPlaylistFolderTab`. Нужно добавить их в `PlaylistView.body`.

**Текущий `PlaylistView.body`:**
```swift
var body: some View {
    VStack(spacing: 0) {
        Divider().background(G.borderSubtle)
        PlaylistTracksPane(...)
        .frame(maxHeight: .infinity)
    }
    .background(G.bgPanelPL)
}
```

**Нужно добавить tab bar между Divider и PlaylistTracksPane:**
```swift
var body: some View {
    VStack(spacing: 0) {
        Divider().background(G.borderSubtle)

        // Tab bar
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(state.playlistTabs) { tab in
                    PlaylistFolderTab(
                        id: tab.id,
                        title: tab.title,
                        active: tab.id == state.activePlaylistTabId,
                        canClose: state.playlistTabs.count > 1,
                        onSelect: { state.selectPlaylistTab(id: tab.id) },
                        onClose: { state.closePlaylistTab(id: tab.id) }
                    )
                }
                NewPlaylistFolderTab { state.createPlaylistTab() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
        .frame(height: 36)
        .background(G.bgPanelPL)

        // Bottom separator
        Rectangle()
            .fill(G.borderSubtle)
            .frame(height: 0.5)

        PlaylistTracksPane(...)
        .frame(maxHeight: .infinity)
    }
    .background(G.bgPanelPL)
}
```

**Проверь:** при создании первого нового таба — он становится активным. При закрытии — переход на соседний. Это уже реализовано в `PlayerState+Playlists.swift`.

---

## Task 2 — Drop Overlay внутрь PlaylistTracksPane

**Файл:** `~/Desktop/GONE/GONE/PlaylistView.swift`

**Проблема:** `PlaylistDropTargetOverlay` определён, но не используется — drag-over не даёт визуальный фидбек.

**Фикс:** В `PlaylistTracksPane.body`, в `GeometryReader`, добавить overlay на `ScrollView`:

```swift
GeometryReader { geo in
    ScrollView(.vertical, showsIndicators: true) {
        // ... существующий контент без изменений ...
    }
    .overlay {
        if isDropTarget {
            PlaylistDropTargetOverlay()
                .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                .allowsHitTesting(false)
        }
    }
    .onDrop(...)
}
```

**Убедись:** `isDropTarget: Binding<Bool>` уже передаётся в `PlaylistTracksPane`. `PlaylistDropTargetOverlay` уже определён в том же файле.

---

## Правила для Codex

- Читай `CLAUDE.md` перед любой работой
- Не трогай `WindowSnapManager.swift` — никогда
- Не добавляй внешние зависимости — только Apple frameworks
- Не создавай новые ObservableObject классы
- SourceKit ошибки "Cannot find X" — ложные, не исправлять перестройкой файлов
- Проверяй через `xcodebuild -project ~/Desktop/GONE/GONE.xcodeproj -scheme GONE build`
