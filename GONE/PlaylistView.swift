import SwiftUI
import Combine
import UniformTypeIdentifiers

struct PlaylistView: View {
    @EnvironmentObject var state: PlayerState
    @ObservedObject private var split = SplitModeManager.shared
    @State private var isDropTarget = false
    @State private var isSecondaryDropTarget = false
    @State private var primarySelectedIds: Set<UUID> = []
    @State private var secondarySelectedIds: Set<UUID> = []
    @State private var activePaneTabId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(G.borderSubtle)
                .frame(height: 1)

            if state.splitPlaylistView, let secondaryId = state.secondaryPlaylistTabId {
                HStack(spacing: 0) {
                    PlaylistTracksPane(
                        tabId: state.activePlaylistTabId,
                        summaryAlignment: .leading,
                        selectedIds: $primarySelectedIds,
                        isDropTarget: $isDropTarget,
                        onDrop: { providers in handleDrop(providers: providers, toPlaylistTabId: state.activePlaylistTabId) },
                        onBecomeActive: {
                            secondarySelectedIds = []
                            activePaneTabId = state.activePlaylistTabId
                        },
                        activePaneBinder: $activePaneTabId
                    )

                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 1)

                    PlaylistTracksPane(
                        tabId: secondaryId,
                        summaryAlignment: .leading,
                        selectedIds: $secondarySelectedIds,
                        isDropTarget: $isSecondaryDropTarget,
                        onDrop: { providers in handleDrop(providers: providers, toPlaylistTabId: secondaryId) },
                        onBecomeActive: {
                            primarySelectedIds = []
                            activePaneTabId = secondaryId
                        },
                        activePaneBinder: $activePaneTabId
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                PlaylistTracksPane(
                    tabId: state.activePlaylistTabId,
                    summaryAlignment: .leading,
                    selectedIds: $primarySelectedIds,
                    isDropTarget: $isDropTarget,
                    onDrop: { providers in handleDrop(providers: providers, toPlaylistTabId: state.activePlaylistTabId) }
                )
                .frame(maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            SplitToggleButton()
                .padding(.trailing, 10)
                .padding(.bottom, 10)
        }
        .overlay {
            GeometryReader { geo in
                ClonePlayerButton()
                    .position(
                        x: state.splitPlaylistView
                            ? geo.size.width / 2 - 19   // 10px from divider + half button (9)
                            : geo.size.width / 2,
                        y: geo.size.height - 19         // 10px from bottom + half button (9)
                    )
            }
        }
        .background(G.bgPanelPL)
        .overlay {
            Group {
                if let urls = state.pendingDropURLs,
                   state.splitPlaylistView,
                   let secondaryId = state.secondaryPlaylistTabId {
                    SplitDropChooserOverlay(
                        urls: urls,
                        tab1Id: state.activePlaylistTabId,
                        tab2Id: secondaryId
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: state.pendingDropURLs != nil)
        }
        .animation(.easeOut(duration: 0.20), value: state.isImporting)
    }

    private func handleDrop(providers: [NSItemProvider], toPlaylistTabId tabId: UUID) -> Bool {
        // Preallocate by index so async callbacks preserve Finder drop order
        var slots: [URL?] = Array(repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()

        for (i, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                var resolved: URL?
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolved = url
                } else if let nsURL = item as? NSURL {
                    resolved = nsURL as URL
                } else if let str = item as? String {
                    resolved = URL(string: str)
                }
                guard let url = resolved else { return }
                lock.withLock { slots[i] = url }
            }
        }

        group.notify(queue: .main) {
            let urls = slots.compactMap { $0 }
            Task { @MainActor in
                if !urls.isEmpty {
                    await state.importURLs(urls, intoPlaylistTabId: tabId)
                }
            }
        }
        return true
    }
}

// ── Split-view drop chooser — appears when dropping files in split mode ────────
struct SplitDropChooserOverlay: View {
    @EnvironmentObject var state: PlayerState
    let urls: [URL]
    let tab1Id: UUID
    let tab2Id: UUID

    @State private var hoveredSide: Int? = nil
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            side(number: 1, tabId: tab1Id)
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
            side(number: 2, tabId: tab2Id)
        }
        .background(Color.black.opacity(0.62))
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { state.pendingDropURLs = nil; return nil }
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    @ViewBuilder
    private func side(number: Int, tabId: UUID) -> some View {
        let isHov = hoveredSide == number
        let name = state.playlistTabs.first(where: { $0.id == tabId })?.title ?? ""

        Button {
            let captured = urls
            state.pendingDropURLs = nil
            Task { @MainActor in
                await state.importURLs(captured, intoPlaylistTabId: tabId)
            }
        } label: {
            ZStack {
                Color.white.opacity(isHov ? 0.05 : 0)

                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        Color.white.opacity(isHov ? 0.38 : 0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .padding(10)

                VStack(spacing: 10) {
                    Text("\(number)")
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(isHov ? 0.92 : 0.48))

                    Text(name.uppercased())
                        .font(G.mono(9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isHov ? 0.65 : 0.28))
                        .tracking(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hoveredSide = h ? number : nil }
        .animation(.easeInOut(duration: 0.12), value: hoveredSide)
    }
}

struct PlaylistDropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.black.opacity(0.55))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Text("DROP TRACKS HERE")
                        .font(G.mono(11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .tracking(0.35)
                        .lineLimit(1)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .padding(12)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(12)
            }
    }
}

struct PlaylistTracksPane: View {
    @EnvironmentObject var state: PlayerState

    let tabId: UUID
    let summaryAlignment: HorizontalAlignment
    @Binding var selectedIds: Set<UUID>
    @Binding var isDropTarget: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    var onBecomeActive: (() -> Void)? = nil
    var activePaneBinder: Binding<UUID?> = .constant(nil)

    @State private var isDropHintHovered = false
    @State private var selectionAnchorId: UUID? = nil
    @State private var draggingId: UUID? = nil
    @State private var dragStartIdx: Int? = nil
    @State private var insertionIdx: Int? = nil
    @State private var lastTapId: UUID? = nil
    @State private var lastTapTime: Date = .distantPast

    private var visibleTracks: [Track] {
        let all = state.sortedTracks(forPlaylistTabId: tabId)
        return state.hideMissingTracks ? all.filter { !$0.isMissing } : all
    }

    private func handleRowTap(_ track: Track) {
        onBecomeActive?()
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift),
           let anchorId = selectionAnchorId,
           let anchorIdx = visibleTracks.firstIndex(where: { $0.id == anchorId }),
           let clickIdx  = visibleTracks.firstIndex(where: { $0.id == track.id }) {
            let lo = min(anchorIdx, clickIdx), hi = max(anchorIdx, clickIdx)
            selectedIds = Set(visibleTracks[lo...hi].map(\.id))
        } else if mods.contains(.command) {
            if selectedIds.contains(track.id) { selectedIds.remove(track.id) }
            else { selectedIds.insert(track.id) }
            selectionAnchorId = track.id
        } else {
            selectedIds = [track.id]
            selectionAnchorId = track.id
        }
    }

    private var footerLabel: String {
        let nonMissing = visibleTracks.filter { !$0.isMissing }
        let totalDuration = nonMissing.reduce(0) { $0 + $1.duration }
        let missing = visibleTracks.filter(\.isMissing).count
        let h = Int(totalDuration) / 3600
        let m = (Int(totalDuration) % 3600) / 60
        let time = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        if missing > 0 { return "\(nonMissing.count) tracks · \(time) · \(missing) missing" }
        return "\(nonMissing.count) tracks · \(time)"
    }

    private var summaryTextAlignment: Alignment {
        summaryAlignment == .trailing ? .trailing : .leading
    }

    @State private var scrollerOffset: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var keyMonitor: Any?
    @State private var scrollerObserver: NSObjectProtocol?
    @State private var focusScrollTarget: UUID? = nil

    // Reference-type box so the NSEvent monitor closure always reads live values.
    // SwiftUI struct copies freeze @State reads inside closures captured at onAppear;
    // a class reference escapes that problem entirely.
    @StateObject private var cursor: PlaylistCursorBox = PlaylistCursorBox()

    var body: some View {
        VStack(spacing: 0) {
            PlaylistHeaderRow(tabId: tabId, scrollerOffset: scrollerOffset)

            GeometryReader { geo in
                ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Scroll offset tracker — zero-height, reads position in scroll coordinate space
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PlaylistScrollOffsetKey.self,
                                value: -proxy.frame(in: .named("ps-\(tabId)")).minY
                            )
                        }
                        .frame(height: 0)

                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { idx, track in
                                let isBeingDragged = draggingId == track.id
                                let crossLineColor: Color = state.crossPaneDragIsCopy ? Color(hex: "#4caf82") : G.accentPrimary
                                let showLineAbove: Bool = {
                                    if let ins = insertionIdx, let startIdx = dragStartIdx, ins != startIdx {
                                        return ins == idx
                                    }
                                    if state.crossPaneDragTargetTabId == tabId,
                                       let ins = state.crossPaneDragInsertionIdx {
                                        return ins == idx
                                    }
                                    return false
                                }()
                                let showLineBelow: Bool = {
                                    if let ins = insertionIdx, let startIdx = dragStartIdx,
                                       ins != startIdx, ins == visibleTracks.count,
                                       idx == visibleTracks.count - 1 { return true }
                                    if state.crossPaneDragTargetTabId == tabId,
                                       let ins = state.crossPaneDragInsertionIdx,
                                       ins >= visibleTracks.count,
                                       idx == visibleTracks.count - 1 { return true }
                                    return false
                                }()
                                let lineColor: Color = (state.crossPaneDragTargetTabId == tabId && draggingId == nil) ? crossLineColor : G.accentPrimary

                                PlaylistRowView(
                                    track: track,
                                    index: idx,
                                    isCurrent: track.id == state.currentId,
                                    playlistTabId: tabId,
                                    isSelected: selectedIds.contains(track.id)
                                )
                                .contentShape(Rectangle())
                                .opacity(isBeingDragged ? 0.38 : 1.0)
                                .overlay(alignment: .top) {
                                    if showLineAbove {
                                        Rectangle()
                                            .fill(lineColor)
                                            .frame(height: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if showLineBelow {
                                        Rectangle()
                                            .fill(lineColor)
                                            .frame(height: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .onTapGesture {
                                    let now = Date()
                                    if lastTapId == track.id, now.timeIntervalSince(lastTapTime) < 0.35 {
                                        onBecomeActive?()
                                        selectedIds = [track.id]
                                        selectionAnchorId = track.id
                                        state.playTrack(id: track.id, fromTabId: tabId)
                                        lastTapId = nil
                                        lastTapTime = .distantPast
                                    } else {
                                        handleRowTap(track)
                                        lastTapId = track.id
                                        lastTapTime = now
                                    }
                                }
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 12)
                                        .onChanged { value in
                                            if draggingId == nil {
                                                draggingId = track.id
                                                dragStartIdx = idx
                                                state.isDraggingInternally = true
                                                NSCursor.closedHand.push()
                                            }
                                            guard let startIdx = dragStartIdx else { return }

                                            // Cross-pane detection in split view
                                            if state.splitPlaylistView {
                                                let globalX = value.startLocation.x + value.translation.width
                                                let otherTabId: UUID? = tabId == state.activePlaylistTabId
                                                    ? state.secondaryPlaylistTabId
                                                    : (tabId == state.secondaryPlaylistTabId ? state.activePlaylistTabId : nil)
                                                if let otherTab = otherTabId {
                                                    let isLeft = tabId == state.activePlaylistTabId
                                                    if isLeft ? globalX > geo.size.width : globalX < 0 {
                                                        let isCopy = NSEvent.modifierFlags.contains(.option)
                                                        state.crossPaneDragTargetTabId = otherTab
                                                        state.crossPaneDragIsCopy = isCopy
                                                        let absoluteY = CGFloat(idx) * 30 + value.location.y
                                                        let targetCount = state.sortedTracks(forPlaylistTabId: otherTab).count
                                                        state.crossPaneDragInsertionIdx = max(0, min(targetCount, Int(absoluteY / 30)))
                                                        if isCopy { NSCursor.dragCopy.set() }
                                                        else { NSCursor.closedHand.set() }
                                                        var t = Transaction(); t.animation = nil
                                                        withTransaction(t) { insertionIdx = nil }
                                                        return
                                                    }
                                                }
                                            }
                                            state.crossPaneDragTargetTabId = nil
                                            state.crossPaneDragIsCopy = false
                                            state.crossPaneDragInsertionIdx = nil
                                            NSCursor.closedHand.set()

                                            // Same-pane reorder
                                            let rawDelta = Int(value.translation.height / 30)
                                            let ins: Int
                                            if rawDelta > 0 {
                                                ins = startIdx + rawDelta + 1
                                            } else {
                                                ins = startIdx + rawDelta
                                            }
                                            let clamped = max(0, min(visibleTracks.count, ins))
                                            if clamped != insertionIdx {
                                                var t = Transaction()
                                                t.animation = nil
                                                withTransaction(t) { insertionIdx = clamped }
                                            }
                                        }
                                        .onEnded { value in
                                            // If onHandoff already ran, draggingId is nil and cursor was already popped.
                                            let needsCursorPop = draggingId != nil
                                            defer {
                                                var t = Transaction()
                                                t.animation = nil
                                                withTransaction(t) {
                                                    draggingId = nil
                                                    dragStartIdx = nil
                                                    insertionIdx = nil
                                                }
                                                state.isDraggingInternally = false
                                                state.crossPaneDragTargetTabId = nil
                                                state.crossPaneDragIsCopy = false
                                                state.crossPaneDragInsertionIdx = nil
                                                if needsCursorPop { NSCursor.pop() }
                                            }
                                            // Cross-pane move or copy — includes full selection when dragged track is selected
                                            if let dragId = draggingId,
                                               let targetTab = state.crossPaneDragTargetTabId {
                                                let idsToMove: [UUID] = selectedIds.contains(dragId) && selectedIds.count > 1
                                                    ? visibleTracks.filter { selectedIds.contains($0.id) }.map(\.id)
                                                    : [dragId]
                                                var insertAt = state.crossPaneDragInsertionIdx
                                                for id in idsToMove {
                                                    if state.crossPaneDragIsCopy {
                                                        state.copyTrackAt(id, to: targetTab, insertionIndex: insertAt)
                                                    } else {
                                                        state.moveTrackAt(id, from: tabId, to: targetTab, insertionIndex: insertAt)
                                                    }
                                                    if let i = insertAt { insertAt = i + 1 }
                                                }
                                                return
                                            }
                                            // Same-pane reorder
                                            guard let dragId = draggingId,
                                                  let startIdx = dragStartIdx,
                                                  let ins = insertionIdx,
                                                  ins != startIdx
                                            else { return }
                                            if ins >= visibleTracks.count {
                                                state.reorderTrackToEnd(dragId, inTabId: tabId)
                                            } else {
                                                state.reorderTrack(dragId, before: visibleTracks[ins].id, inTabId: tabId)
                                            }
                                        }
                                )
                                .overlay {
                                    if !track.isMissing {
                                        RowDragOverlay(
                                            track: track,
                                            trackIndex: idx,
                                            cueEnabled: state.cueExportEnabled,
                                            allTracks: visibleTracks,
                                            selectedIds: selectedIds,
                                            onHandoff: {
                                                var t = Transaction(); t.animation = nil
                                                withTransaction(t) {
                                                    draggingId   = nil
                                                    dragStartIdx = nil
                                                    insertionIdx = nil
                                                }
                                                state.isDraggingInternally    = false
                                                state.crossPaneDragTargetTabId = nil
                                                state.crossPaneDragIsCopy      = false
                                                NSCursor.pop()
                                            }
                                        )
                                    }
                                }
                                .id(track.id)  // anchor for ScrollViewReader
                            }
                        }

                        let trackCount = visibleTracks.count
                        let dropZoneMinH: CGFloat = trackCount == 0
                            ? max(100, geo.size.height - 48)
                            : max(44, geo.size.height - 48 - CGFloat(trackCount) * 30)
                        let isCompact = dropZoneMinH < 60

                        ZStack {
                            Color.clear

                            VStack(spacing: isCompact ? 2 : 5) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: isCompact ? 9 : 11, weight: .light))
                                    .foregroundStyle(Color.white.opacity(isDropHintHovered ? 0.30 : 0.17))
                                Text(isDropHintHovered ? "DROP TRACKS HERE, OR CLICK" : "DROP TRACKS HERE")
                                    .font(G.mono(isCompact ? 7 : 8))
                                    .foregroundStyle(Color.white.opacity(isDropHintHovered ? 0.30 : 0.17))
                                    .tracking(0.5)
                                    .id(isDropHintHovered)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, isCompact ? 6 : 10)
                            .overlay {
                                Canvas { ctx, size in
                                    let inset: CGFloat = 0.5
                                    let r: CGFloat = 8
                                    let rect = CGRect(x: inset, y: inset,
                                                      width: size.width - inset * 2,
                                                      height: size.height - inset * 2)
                                    let straight = 2 * (max(0, rect.width - 2*r) + max(0, rect.height - 2*r))
                                    let perimeter = straight + 2 * .pi * r
                                    let targetPeriod: CGFloat = 8
                                    let targetDash: CGFloat = 4
                                    let count = max(1, (perimeter / targetPeriod).rounded())
                                    let period = perimeter / count
                                    let dash = period * targetDash / targetPeriod
                                    let gap  = period - dash
                                    ctx.stroke(
                                        Path(roundedRect: rect, cornerRadius: r),
                                        with: .color(Color.white.opacity(isDropHintHovered ? 0.165 : 0)),
                                        style: StrokeStyle(lineWidth: 1, lineCap: .butt,
                                                           dash: [dash, gap], dashPhase: dash / 2)
                                    )
                                }
                            }
                            .animation(.easeInOut(duration: 0.15), value: isDropHintHovered)
                            .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, minHeight: dropZoneMinH)
                        .contentShape(Rectangle())
                        .onTapGesture { state.presentImportPanel(intoTabId: tabId) }
                        .onHover { isDropHintHovered = $0 }
                        .opacity(state.isDraggingInternally ? 0 : 1)
                        .animation(.easeInOut(duration: 0.22), value: dropZoneMinH)
                        .animation(.easeInOut(duration: 0.15), value: state.isDraggingInternally)

                        Color.clear.frame(height: 38)
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PlaylistContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                }
                .coordinateSpace(name: "ps-\(tabId)")
                .onPreferenceChange(PlaylistScrollOffsetKey.self) { scrollOffset = $0 }
                .onPreferenceChange(PlaylistContentHeightKey.self) { contentHeight = $0 }
                .overlay(alignment: .topTrailing) {
                    PlaylistScrollbar(scrollOffset: scrollOffset,
                                      contentHeight: contentHeight,
                                      viewportHeight: geo.size.height)
                }
                .overlay {
                    if isDropTarget && !state.isDraggingInternally {
                        PlaylistDropTargetOverlay()
                            .allowsHitTesting(false)
                    }
                    if state.isDraggingInternally && state.crossPaneDragTargetTabId == tabId {
                        let accentColor: Color = state.crossPaneDragIsCopy
                            ? Color(hex: "#4caf82")
                            : G.accentPrimary
                        let targetIsEmpty = state.sortedTracks(forPlaylistTabId: tabId).isEmpty
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accentColor.opacity(0.06))
                            .overlay {
                                if targetIsEmpty {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(accentColor.opacity(0.50), lineWidth: 1.5)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if state.crossPaneDragIsCopy {
                                    Text("⌥ COPY")
                                        .font(G.mono(8, weight: .semibold))
                                        .foregroundStyle(accentColor.opacity(0.85))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(accentColor.opacity(0.14))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .padding(10)
                                }
                            }
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: isDropTarget)
                .animation(.easeInOut(duration: 0.12), value: state.crossPaneDragTargetTabId == tabId)
                .onDrop(of: [UTType.audio, UTType.fileURL], isTargeted: $isDropTarget, perform: onDrop)
                // Scroll to playing track when playlist opens or current track changes
                .onChange(of: state.playlistOpen) { isOpen in
                    guard isOpen, let id = state.currentId,
                          visibleTracks.contains(where: { $0.id == id }) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeInOut(duration: 0.30)) { scrollProxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onChange(of: state.currentId) { id in
                    guard state.playlistOpen, let id,
                          visibleTracks.contains(where: { $0.id == id }) else { return }
                    withAnimation(.easeInOut(duration: 0.30)) { scrollProxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: focusScrollTarget) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.20)) {
                        scrollProxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            } // ScrollViewReader
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.clear, G.bgPage],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 32)
                    .allowsHitTesting(false)

                    HStack(alignment: .center, spacing: 0) {
                        Text(footerLabel)
                            .font(G.mono(10))
                            .foregroundStyle(Color.white.opacity(0.30))
                            .frame(maxWidth: .infinity, alignment: summaryTextAlignment)

                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .padding(.top, 3)
                    .padding(.bottom, 10)
                    .background(G.bgPage)
                }
            }
        }
        .onAppear {
            scrollerObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil, queue: .main
            ) { _ in
                scrollerOffset = 0
            }

            // Wire up the cursor box — capture stable reference types only.
            // The box object itself is heap-allocated and lives for the view's lifetime,
            // so every closure that reads from it always sees the live value.
            let box = cursor          // cursor is @StateObject — a stable class reference
            box.tabId = tabId

            // Reads that must stay fresh: pull directly from the class reference (state, binder).
            // The monitor block captures `box`, `state`, and `activePaneBinder` — all reference
            // types or Binding structs with a stable storage pointer — so they stay current.
            let binder = activePaneBinder

            // Write-closures post back onto the main actor so @State mutations are safe.
            box.writeSelection = { @MainActor newSet in selectedIds = newSet }
            box.writeAnchor    = { @MainActor newId  in selectionAnchorId = newId }
            box.writeScroll    = { @MainActor newId  in focusScrollTarget  = newId }
            box.readTracks     = { [weak state] in
                guard let state else { return [] }
                let all = state.sortedTracks(forPlaylistTabId: box.tabId)
                return state.hideMissingTracks ? all.filter { !$0.isMissing } : all
            }

            // NSEvent monitor — captures only the box (class ref) and stable bindings.
            // Never reads @State variables directly: those would be frozen struct copies.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak state] event in
                guard let state else { return event }
                guard !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
                // Strip numericPad/function — arrow keys always carry these on macOS hardware.
                let mods = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function])

                // Cmd+A: select all
                if mods == .command, event.charactersIgnoringModifiers == "a" {
                    if state.splitPlaylistView {
                        let activeId = binder.wrappedValue ?? state.activePlaylistTabId
                        guard activeId == box.tabId else { return event }
                    }
                    let tracks = box.readTracks?() ?? []
                    DispatchQueue.main.async {
                        box.writeSelection?(Set(tracks.map(\.id)))
                    }
                    return nil
                }

                // ↑ / ↓ / Enter: browse cursor — no modifier, playlist must be open
                guard mods.isEmpty, state.playlistOpen else { return event }
                if state.splitPlaylistView {
                    let activeId = binder.wrappedValue ?? state.activePlaylistTabId
                    guard activeId == box.tabId else { return event }
                }

                let tracks = box.readTracks?() ?? []
                switch event.keyCode {
                case 125: // ↓ arrow
                    guard !tracks.isEmpty else { return event }
                    let startId = box.anchorId ?? state.currentId
                    let curIdx  = startId.flatMap { id in tracks.firstIndex(where: { $0.id == id }) }
                    let nextIdx = curIdx.map { min($0 + 1, tracks.count - 1) } ?? 0
                    let next    = tracks[nextIdx]
                    box.anchorId = next.id
                    DispatchQueue.main.async {
                        box.writeSelection?([next.id])
                        box.writeAnchor?(next.id)
                        box.writeScroll?(next.id)
                    }
                    return nil
                case 126: // ↑ arrow
                    guard !tracks.isEmpty else { return event }
                    let startId = box.anchorId ?? state.currentId
                    let curIdx  = startId.flatMap { id in tracks.firstIndex(where: { $0.id == id }) }
                    let prevIdx = curIdx.map { max($0 - 1, 0) } ?? 0
                    let prev    = tracks[prevIdx]
                    box.anchorId = prev.id
                    DispatchQueue.main.async {
                        box.writeSelection?([prev.id])
                        box.writeAnchor?(prev.id)
                        box.writeScroll?(prev.id)
                    }
                    return nil
                case 36: // Return/Enter — play the single selected track
                    guard let id = box.anchorId else { return event }
                    DispatchQueue.main.async { state.playTrack(id: id, fromTabId: box.tabId) }
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = scrollerObserver { NotificationCenter.default.removeObserver(m); scrollerObserver = nil }
        }
        .onChange(of: selectedIds.isEmpty) { isEmpty in
            if isEmpty {
                selectionAnchorId = nil
                cursor.anchorId   = nil   // keep box in sync
            }
        }
        // Keep box.anchorId in sync whenever selectionAnchorId changes from tap/click.
        .onChange(of: selectionAnchorId) { newId in
            cursor.anchorId = newId
        }
    }
}

// ── Column headers ────────────────────────────────────────────────────────────
struct PlaylistHeaderRow: View {
    @EnvironmentObject var state: PlayerState
    let tabId: UUID
    var scrollerOffset: CGFloat = 0
    static let rowBackground = Color.clear

    @State private var hashHovered = false
    @State private var cueHovered  = false

    private var tab: PlaylistTabModel? {
        state.playlistTabs.first(where: { $0.id == tabId })
    }

    var body: some View {
        HStack(spacing: 0) {
            hashCell
            hashInfoZone
            headerCell("Title",  key: .title,    width: nil)
            headerCell("BPM",    key: .bpm,      width: 44, align: .trailing)
            headerCell("Time",   key: .duration, width: 50, align: .trailing)
        }
        .padding(.trailing, scrollerOffset)
        .background(Self.rowBackground)
    }

    // 20px: # + sort arrow — clicking toggles sort direction (number sort).
    private var hashCell: some View {
        let active    = tab?.sortKey == .number
        let dir       = tab?.sortDir ?? .asc
        let showArrow = active || hashHovered

        return Button { state.toggleSort(.number, forTabId: tabId) } label: {
            HStack(spacing: 2) {
                Text("#")
                    .font(G.mono(11))
                    .foregroundStyle(active ? Color.white.opacity(0.78) : G.textMuted)
                    .tracking(0.2)
                if showArrow {
                    Text(dir == .asc ? "▲" : "▼")
                        .font(.system(size: 5.5, weight: .semibold))
                        .foregroundStyle(G.textMuted)
                        .baselineOffset(1)
                }
            }
            .frame(width: 20, alignment: .center)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(width: 20)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hashHovered = $0 }
        .animation(.easeOut(duration: 0.10), value: hashHovered)
    }

    // 24px: CUE — always visible. Click toggles numbered export mode.
    // Active = files will be renamed 001_, 002_… on drag-to-Finder.
    private var hashInfoZone: some View {
        let cueOn = state.cueExportEnabled

        // Four visual states: off/on × hovered/resting
        let textOpacity: Double = cueOn ? (cueHovered ? 1.0 : 0.88) : (cueHovered ? 0.65 : 0.26)
        let bgOpacity:   Double = cueOn ? (cueHovered ? 0.20 : 0.14) : (cueHovered ? 0.09 : 0.04)
        let strokeOp:    Double = cueOn ? (cueHovered ? 0.40 : 0.28) : (cueHovered ? 0.20 : 0.08)

        return Button { state.cueExportEnabled.toggle() } label: {
            Text("CUE")
                .font(G.mono(7, weight: .semibold))
                .foregroundStyle(Color.white.opacity(textOpacity))
                .tracking(0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(bgOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(strokeOp), lineWidth: 0.5)
                        )
                )
                .fixedSize()
        }
        .buttonStyle(.plain)
        .frame(width: 24)
        .onHover { cueHovered = $0 }
        .animation(.easeOut(duration: 0.10), value: cueHovered)
        .animation(.easeOut(duration: 0.12), value: cueOn)
        .goneTooltip("Numbered export. Drag tracks to Finder and they rename to 001_Name, 002_Name — locks set order for any gear that reads filenames")
    }

    @ViewBuilder
    func headerCell(_ label: String, key: PlayerState.SortKey,
                    width: CGFloat?, align: HorizontalAlignment = .leading) -> some View {
        let active = tab?.sortKey == key
        let dir    = tab?.sortDir ?? .asc
        let frameAlign: Alignment = align == .trailing ? .trailing : align == .center ? .center : .leading
        Button {
            state.toggleSort(key, forTabId: tabId)
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(G.mono(9))
                    .foregroundStyle(G.textMuted)
                    .tracking(0.4)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if active {
                    Text(dir == .asc ? "▲" : "▼")
                        .font(.system(size: 7))
                        .foregroundStyle(G.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlign)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .fixedSize(horizontal: width != nil, vertical: false)
    }
}

// ── Playlist row ──────────────────────────────────────────────────────────────
struct PlaylistRowView: View {
    let track: Track
    let index: Int
    let isCurrent: Bool
    let playlistTabId: UUID
    var isSelected: Bool = false

    @EnvironmentObject var state: PlayerState
    @State private var hovered = false
    @State private var showCompletion: Bool = false
    @State private var showDeleteConfirm = false

    private var scanFrac: Double {
        if showCompletion { return 1.0 }
        guard track.bpmAnalysisState == .analyzing else { return 0 }
        return state.analysisProgress[track.id] ?? 0
    }

    private var contentOpacity: Double {
        guard !track.isMissing, !isCurrent else { return 1.0 }
        switch track.bpmAnalysisState {
        case .pending:   return 0.46
        case .analyzing: return 0.72
        default:         return 1.0
        }
    }

    var body: some View {
        ZStack {
            // BPM scan fill — real progress, grows left to right behind content
            if track.bpmAnalysisState == .analyzing || showCompletion {
                GeometryReader { geo in
                    Rectangle()
                        .fill(isCurrent ? Color.black.opacity(0.07) : Color.white.opacity(0.08))
                        .frame(width: max(0, geo.size.width * CGFloat(scanFrac)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.4), value: scanFrac)
            }

            HStack(spacing: 0) {
                // #
                Text("\(index + 1)")
                    .font(G.mono(index < 99 ? 10 : 8))
                    .foregroundStyle(isCurrent ? Color.white : G.textMuted.opacity(0.82))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: 20, alignment: .center)

                // Art — drag to Finder via AppKit NSDraggingSession (reliable, bypasses SwiftUI gesture competition)
                ZStack {
                    if track.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: "#d4a017"))
                    } else {
                        ArtSwatchView(
                            index: state.tracks.firstIndex(of: track) ?? 0,
                            size: 20,
                            cornerRadius: 3,
                            artworkData: track.artworkData,
                            trackId: track.id,
                            isCurrent: isCurrent
                        )
                    }
                }
                .frame(width: 24)

                // Title + artist, BPM, duration
                Group {
                    MarqueeTextRow(
                        title: track.title,
                        artist: track.isMissing ? "" : track.artist,
                        isCurrent: isCurrent,
                        hovered: hovered
                    )
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    // Reveal in Finder (hover only)
                    if hovered && !track.isMissing {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([track.url])
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(G.textTertiary)
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: G.rRow))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 2)
                        .transition(.opacity)
                        .goneTooltip("Show in Finder")
                    }

                    // BPM — .id forces view recreation when state changes (Track.== compares only id)
                    BPMCell(track: track, isCurrent: isCurrent)
                        .id(track.bpmAnalysisState)
                        .padding(.horizontal, 4)

                    // Duration
                    Text(fmtTime(track.duration))
                        .font(G.mono(10.5))
                        .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.5))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .padding(.leading, 3)
                        .padding(.trailing, 7)
                }
            }
            .opacity(contentOpacity)
            .animation(.easeInOut(duration: 0.25), value: contentOpacity)

        }
        .frame(height: 30)
        .background(
            isCurrent   ? G.currentBg
            : isSelected ? G.accentPrimary.opacity(0.14)
            : hovered   ? G.hoverBg
            : (index % 2 == 0 ? Color.white.opacity(0.012) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 2)
            }
        }
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .contextMenu {
            if !track.isMissing {
                Button("Play") {
                    state.playTrack(id: track.id, fromTabId: playlistTabId)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                }

            }

            Divider()

            Button("Remove from Playlist") {
                state.removeFromPlaylist(id: track.id, tabId: playlistTabId)
            }

            Button("Delete from Library", role: .destructive) {
                if state.confirmBeforeDelete { showDeleteConfirm = true }
                else { state.deleteFromLibrary(id: track.id) }
            }
        }
        .onChange(of: track.bpmAnalysisState) { new in
            guard new == .analyzed else { return }
            showCompletion = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.easeOut(duration: 0.35)) { showCompletion = false }
            }
        }
        .alert("Delete \"\(track.title)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { state.deleteFromLibrary(id: track.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the track from the library and all playlists.")
        }
    }
}

// ── Finder drag — transparent NSView overlay per row ─────────────────────────
// hitTest returns nil → completely transparent to SwiftUI taps/selections.
// NSEvent monitors detect when mouse exits the window while pressed over this row
// and start an AppKit NSDraggingSession at that point — so internal reorder
// (SwiftUI DragGesture) works for drags within the window, and Finder export
// works for drags that leave the window. Any part of the row, any selection size.
struct RowDragOverlay: NSViewRepresentable {
    let track:       Track
    let trackIndex:  Int
    let cueEnabled:  Bool
    let allTracks:   [Track]
    let selectedIds: Set<UUID>
    var onHandoff:   () -> Void

    func makeNSView(context: Context) -> RowDragNSView { RowDragNSView() }
    func updateNSView(_ v: RowDragNSView, context: Context) {
        v.track      = track
        v.trackIndex = trackIndex
        v.cueEnabled = cueEnabled
        v.allTracks  = allTracks
        v.selectedIds = selectedIds
        v.onHandoff  = onHandoff
    }
}

final class RowDragNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var track:       Track?
    var trackIndex:  Int       = 0
    var cueEnabled:  Bool      = false
    var allTracks:   [Track]   = []
    var selectedIds: Set<UUID> = []
    var onHandoff:   (() -> Void)?

    private struct PromiseInfo { let url: URL; let name: String }
    private var promises:    [UUID: PromiseInfo] = [:]
    private var draggedURLs: [URL] = []   // ordered source URLs for NSFilenamesPboardType
    private var downEvent:   NSEvent?
    private var didHandOff   = false
    private var downMonitor: Any?
    private var upMonitor:   Any?
    private var dragMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    // Transparent to all SwiftUI hit-testing — clicks, selections, taps all pass through
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startMonitors() } else { stopMonitors() }
    }

    private func startMonitors() {
        stopMonitors()
        downMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            guard let self else { return ev }
            // Ignore events from any window other than the player (settings panel, etc.)
            guard ev.window == self.window else { return ev }
            // Convert the row's bounds TO window space (not the inverse) — avoids
            // the flipped-coordinate ambiguity in the SwiftUI-AppKit NSHostingView bridge.
            let rowInWindow = self.convert(self.bounds, to: nil)
            if rowInWindow.contains(ev.locationInWindow) {
                // Skip clicks on window resize edges — bottom/left/right ~8 px.
                // Dragging those edges makes the mouse briefly exit win.frame,
                // which the dragMonitor reads as "mouse left window → start file drag."
                if let win = self.window {
                    let loc = ev.locationInWindow
                    let r: CGFloat = 8
                    let w = win.frame.width
                    let h = win.frame.height
                    guard loc.y >= r, loc.y <= h - r,
                          loc.x >= r, loc.x <= w - r else { return ev }
                }
                self.downEvent  = ev
                self.didHandOff = false
            }
            return ev   // never consume — SwiftUI must see every mouseDown
        }

        upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] ev in
            guard let self, ev.window == self.window else { return ev }
            self.downEvent  = nil   // gesture over, reset for next press
            self.didHandOff = false
            return ev
        }

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] ev in
            guard let self,
                  ev.window == self.window,
                  !self.didHandOff,
                  self.downEvent != nil,
                  let win = self.window else { return ev }
            guard !win.frame.contains(NSEvent.mouseLocation) else { return ev }

            // Mouse left the window — take over with AppKit drag
            let captured = self.downEvent!
            self.didHandOff = true
            self.downEvent  = nil
            self.onHandoff?()
            self.startDragging(triggerEvent: captured)
            return nil  // suppress so SwiftUI DragGesture doesn't see this exit event
        }
    }

    private func stopMonitors() {
        [downMonitor, upMonitor, dragMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        downMonitor = nil; upMonitor = nil; dragMonitor = nil
        downEvent = nil; didHandOff = false
    }

    deinit { stopMonitors() }

    private func startDragging(triggerEvent: NSEvent) {
        guard let cur = track else { return }

        let isSelected = selectedIds.contains(cur.id)
        let export: [(Int, Track)] = isSelected && !selectedIds.isEmpty
            ? allTracks.enumerated()
                  .filter { selectedIds.contains($0.element.id) }
                  .map    { ($0.offset, $0.element) }
            : [(trackIndex, cur)]

        promises.removeAll()
        draggedURLs = export.map { $0.1.url }
        let items: [NSDraggingItem] = export.enumerated().compactMap { i, pair in
            let (idx, t) = pair
            let ext  = t.url.pathExtension
            let base = t.url.deletingPathExtension().lastPathComponent
            let name = cueEnabled
                ? String(format: "%03d_", idx + 1) + base + (ext.isEmpty ? "" : "." + ext)
                : t.url.lastPathComponent
            promises[t.id] = PromiseInfo(url: t.url, name: name)

            let fType   = UTType(filenameExtension: ext)?.identifier ?? UTType.audio.identifier
            let promise = NSFilePromiseProvider(fileType: fType, delegate: self)
            promise.userInfo = t.id.uuidString

            let img  = Self.makeDragImage()
            let di   = NSDraggingItem(pasteboardWriter: promise)
            let off  = CGFloat(i) * 3
            di.setDraggingFrame(NSRect(x: off, y: -off, width: 48, height: 56), contents: img)
            return di
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: triggerEvent, source: self)
    }

    // MARK: NSDraggingSource
    func draggingSession(_ s: NSDraggingSession,
                         sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
        ctx == .outsideApplication ? .copy : []
    }

    // Adds NSFilenamesPboardType so apps that don't support file promises (Telegram,
    // Rekordbox, web browsers, etc.) can still receive files via the standard macOS drag.
    // Does NOT clear the existing file-promise items — Finder still gets cue-renamed files.
    func draggingSession(_ s: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        let paths = draggedURLs.map { $0.path }
        guard !paths.isEmpty else { return }
        let pb = s.draggingPasteboard
        pb.addTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")], owner: nil)
        pb.setPropertyList(paths, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }

    // MARK: NSFilePromiseProviderDelegate
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType _: String) -> String {
        guard let idStr = p.userInfo as? String, let id = UUID(uuidString: idStr) else { return "" }
        return promises[id]?.name ?? ""
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider,
                             writePromiseTo destURL: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let idStr = p.userInfo as? String, let id = UUID(uuidString: idStr),
              let src   = promises[id]?.url else {
            completionHandler(NSError(domain: "GONE", code: -1, userInfo: nil)); return
        }
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: src, to: destURL)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }

    private static func makeDragImage() -> NSImage {
        let w: CGFloat = 48, h: CGFloat = 56
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let rect = NSRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.88).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        if let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                         .withSymbolConfiguration(cfg) {
            sym.draw(
                in: NSRect(x: (w - sym.size.width) / 2, y: (h - sym.size.height) / 2,
                           width: sym.size.width, height: sym.size.height),
                from: .zero, operation: .sourceOver, fraction: 0.40
            )
        }
        img.unlockFocus()
        return img
    }
}

// ── Split toggle button ───────────────────────────────────────────────────────
struct SplitToggleButton: View {
    @EnvironmentObject var state: PlayerState
    @State private var hovered = false

    var body: some View {
        Button {
            state.toggleSplitPlaylistView()
        } label: {
            HStack(spacing: 4) {
                if hovered {
                    Text(state.splitPlaylistView ? "MERGE" : "SPLIT")
                        .font(G.mono(8))
                        .foregroundStyle(Color.white.opacity(0.40))
                        .tracking(0.4)
                        .transition(.opacity)
                }
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9, weight: state.splitPlaylistView ? .semibold : .regular))
                    .foregroundStyle(Color.white.opacity(state.splitPlaylistView ? 0.65 : 0.28))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(state.splitPlaylistView ? 0.08 : (hovered ? 0.05 : 0)))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .animation(.easeInOut(duration: 0.12), value: state.splitPlaylistView)
    }
}

// ── Clone player button — bottom-center "+" that opens a second player window ──
struct ClonePlayerButton: View {
    @EnvironmentObject var state: PlayerState
    @ObservedObject private var split = SplitModeManager.shared
    @State private var hovered = false

    var body: some View {
        Button {
            Task { @MainActor in
                if split.isActive {
                    split.deactivate()
                } else {
                    let delegate = NSApp.delegate as? AppDelegate
                    let win = delegate?.resolvedMainWindow()
                        ?? WindowSnapManager.shared.currentWindow
                    guard let win else { return }
                    split.activate(primaryWindow: win, primaryState: state)
                }
            }
        } label: {
            Image(systemName: split.isActive ? "square.slash" : "square.on.square")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(Color.white.opacity(hovered ? 0.50 : 0.20))
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(hovered ? 0.18 : 0), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// ── Marquee title + artist ────────────────────────────────────────────────────
private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MarqueeTextRow: View {
    let title: String
    let artist: String
    let isCurrent: Bool
    let hovered: Bool

    @State private var textW: CGFloat = 0
    @State private var offset: CGFloat = 0

    private func buildText() -> Text {
        guard !artist.isEmpty else {
            return Text(title)
                .font(G.sans(11, weight: isCurrent ? .semibold : .medium))
                .foregroundColor(isCurrent ? Color.white : G.textSecondary)
        }
        var titleStr = AttributedString(title)
        titleStr.font = G.sans(11, weight: isCurrent ? .semibold : .medium)
        titleStr.foregroundColor = isCurrent ? Color.white : G.textSecondary

        var artistStr = AttributedString("   \(artist)")
        artistStr.font = G.sans(11)
        artistStr.foregroundColor = isCurrent ? Color.white.opacity(0.70) : Color.white.opacity(0.45)

        return Text(titleStr + artistStr)
    }

    var body: some View {
        GeometryReader { proxy in
            buildText()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { inner in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: inner.size.width)
                    }
                }
                .onPreferenceChange(MarqueeWidthKey.self) { textW = $0 }
                .offset(x: offset)
                .onChange(of: hovered) { isHovered in
                    let overflow = textW - proxy.size.width
                    if isHovered && overflow > 4 {
                        withAnimation(.linear(duration: Double(overflow) / 40.0).delay(0.5)) {
                            offset = -overflow
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            offset = 0
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .clipped()
    }
}

struct BPMCell: View {
    let track: Track
    var isCurrent: Bool = false

    var body: some View {
        Group {
            if track.isMissing {
                cellText("—", color: isCurrent ? Color.white.opacity(0.35) : Color.white.opacity(0.25))
            } else {
                switch track.bpmAnalysisState {
                case .analyzed:
                    cellText("\(Int(track.bpm.rounded()))", color: isCurrent ? Color.white : Color.white.opacity(0.85))
                case .analyzing:
                    AnalyzingDots(phase: abs(track.id.hashValue) % 3)
                        .frame(width: 36, alignment: .center)
                case .pending:
                    cellText("–", color: isCurrent ? Color.white.opacity(0.28) : Color.white.opacity(0.2))
                case .failed:
                    cellText("ERR", color: isCurrent ? Color.white.opacity(0.55) : Color.white.opacity(0.35), size: 9.5)
                }
            }
        }
    }

    @ViewBuilder
    private func cellText(_ text: String, color: Color, size: CGFloat = 10.5) -> some View {
        Text(text)
            .font(G.mono(size))
            .foregroundStyle(color)
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
    }
}

private struct AnalyzingDots: View {
    let phase: Int
    @State private var active: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(active == i ? 0.65 : 0.16))
                    .frame(width: 3, height: 3)
                    .animation(.easeInOut(duration: 0.22), value: active)
            }
        }
        .onAppear { active = phase }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 380_000_000)
                active = (active + 1) % 3
            }
        }
    }
}

// MARK: – Custom thin scrollbar

private struct PlaylistScrollbar: View {
    let scrollOffset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat

    private let thumbW: CGFloat = 3
    private let padding: CGFloat = 2

    var body: some View {
        if contentHeight > viewportHeight + 1 {
            GeometryReader { geo in
                let trackH  = geo.size.height - padding * 2
                let ratio   = CGFloat(viewportHeight / max(1, contentHeight))
                let thumbH  = max(18, trackH * ratio)
                let range   = contentHeight - viewportHeight
                let progress = range > 0 ? min(1, max(0, scrollOffset / range)) : 0
                let thumbY  = padding + (trackH - thumbH) * CGFloat(progress)

                RoundedRectangle(cornerRadius: thumbW / 2)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: thumbW, height: thumbH)
                    .offset(x: -(padding), y: thumbY)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: thumbW + padding * 2)
        }
    }
}


// ── Cursor box — reference type so NSEvent monitor closure sees live values ────
// @StateObject keeps one instance alive for the whole lifetime of PlaylistTracksPane.
// The closure captures the box object (heap-allocated), not a struct snapshot,
// so anchorId and the write-closures always reflect current state.
final class PlaylistCursorBox: ObservableObject {
    @Published var anchorId: UUID?
    var writeSelection: ((Set<UUID>) -> Void)?
    var writeAnchor: ((UUID?) -> Void)?
    var writeScroll: ((UUID?) -> Void)?
    var readTracks: (() -> [Track])?
    var readPlaylistOpen: (() -> Bool)?
    var readSplitView: (() -> Bool)?
    var readActiveTabId: (() -> UUID?)?
    var tabId: UUID = UUID()
}

private enum PlaylistScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum PlaylistContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// ── Analyzing overlay — shown during import ──────────────────────────────────

