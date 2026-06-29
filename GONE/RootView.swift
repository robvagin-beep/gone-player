import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let headerDoubleClick = Notification.Name("GONEHeaderDoubleClick")
    static let windowDidMove     = Notification.Name("GONEWindowDidMove")
}

struct RootView: View {
    @EnvironmentObject var state: PlayerState
    @State private var isDropTarget = false
    private let shellInsetX: CGFloat = 6
    private let shellInsetTop: CGFloat = 6
    private let shellInsetBottom: CGFloat = 6
    private let outerShellRadius: CGFloat = G.rWindowOuter + 3

    private var playerContentSize: CGSize {
        let baseHeight = FullPlayerView.baseHeight
        let eqPanelHeight: CGFloat = !state.tracks.isEmpty && state.eqOpen ? FullPlayerView.eqPanelHeight : 0
        let playlistPanelHeight: CGFloat = !state.tracks.isEmpty && state.playlistOpen ? state.playlistPanelHeight : 0
        return CGSize(width: G.windowWidth, height: baseHeight + eqPanelHeight + playlistPanelHeight)
    }

    private var shellSize: CGSize {
        CGSize(
            width: playerContentSize.width + shellInsetX * 2,
            height: playerContentSize.height + shellInsetTop + shellInsetBottom
        )
    }

    // Shell dimensions after display scale is applied — passed to updateWindowSize
    // so the NSWindow frame matches the visually-scaled content.
    private var scaledShellSize: CGSize {
        CGSize(width: shellSize.width * state.windowScale,
               height: shellSize.height * state.windowScale)
    }

    // Resize the window to match scaledShellSize. Called on any layout-affecting change.
    private func applyDisplayScale() {
        updateWindowSize(to: scaledShellSize)
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: outerShellRadius)
                .fill(Color.white.opacity(0.028))
                .blur(radius: 0.08)

            RoundedRectangle(cornerRadius: outerShellRadius)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.22), location: 0),
                            .init(color: .white.opacity(0.10), location: 0.18),
                            .init(color: .white.opacity(0.06), location: 0.5),
                            .init(color: .white.opacity(0.04), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: outerShellRadius)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: outerShellRadius)
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                        .mask(
                            LinearGradient(
                                colors: [.white, .white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .shadow(color: .black.opacity(0.36), radius: 10, x: 0, y: 1)
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 0)

            FullPlayerView()
                .frame(width: G.windowWidth)
            .padding(.horizontal, shellInsetX)
            .padding(.top, shellInsetTop)
            .padding(.bottom, shellInsetBottom)
            .frame(width: shellSize.width, height: shellSize.height, alignment: .top)

            // Single gradient map — clipped to rounded shell so corners stay clean.
            if state.gradientMapSaturation > 0.5 {
                Color(hue: state.gradientMapHue / 360,
                      saturation: state.gradientMapSaturation / 100,
                      brightness: 0.5)
                    .blendMode(.color)
                    .clipShape(RoundedRectangle(cornerRadius: outerShellRadius))
                    .allowsHitTesting(false)
            }

            // Currently playing artwork — real colors floated above gradient map.
            // Top offset = shellInsetTop(6) + VStack.padding.top(4) + TrackHeaderView.padding.top(8) = 18
            if state.gradientMapSaturation > 0.5,
               let currentId = state.currentId,
               state.current?.hasArtwork == true {
                ArtSwatchView(
                    index: state.tracks.firstIndex(where: { $0.id == currentId }) ?? 0,
                    size: 48,
                    cornerRadius: 7,
                    hasArtwork: true,
                    trackId: currentId
                )
                .allowsHitTesting(false)
                .padding(.top, shellInsetTop + 4 + 8)
                .padding(.leading, shellInsetX + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // Drag handles inside scaleEffect — hit areas match the visual scale.
            WindowBorderDragOverlay(hasContent: !state.tracks.isEmpty)

            // Resize handle at bottom — inside scaleEffect so it's at the right visual position.
            if !state.tracks.isEmpty && state.playlistOpen {
                BottomResizeHandle(eqOpen: state.eqOpen, windowScale: state.windowScale) { newH in
                    state.playlistPanelHeight = max(160, min(700, newH))
                }
                .frame(height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: shellSize.width, height: shellSize.height, alignment: .top)
        // Clip all content (including blur/shadow spread and drag-handle layers) to the
        // rounded shell shape so no rectangular corners bleed outside the rounded border.
        .clipShape(RoundedRectangle(cornerRadius: outerShellRadius))
        // Scale the ENTIRE shell — glass border + content scale together.
        // Math: SwiftUI centers shellSize in scaledShellSize window; scaleEffect
        // from view center equals window center → visual fills window exactly.
        .scaleEffect(state.windowScale)
        // scaleEffect is render-only — it does NOT change the SwiftUI layout size. The content
        // frame above stays at the UNSCALED shellSize, so NSHostingView kept reporting 472pt as
        // its ideal size and pinned the panel to it; updateWindowSize's scaled target lost the
        // fight and the window never shrank below 100%. Pinning the layout footprint to the
        // scaled size makes the hosting ideal == updateWindowSize target. At 100% this is a
        // no-op (scaledShellSize == shellSize), so existing behaviour is unchanged.
        .frame(width: scaledShellSize.width, height: scaledShellSize.height, alignment: .top)
        .background(Color.clear)
        // Drop zone highlight
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: G.rWindowOuter)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isDropTarget)
        // Peek panel — visible when snapped to an edge. The snapped window keeps
        // full width with its body past the screen edge; the panel overlay sits on
        // the visible side: leading for right dock, trailing for left dock.
        .overlay(alignment: state.snapDockLeft ? .trailing : .leading) {
            if state.snapState == .docked || state.snapState == .peeking {
                PeekPanelView(isDropTarget: $isDropTarget, onFileDrop: handleDrop)
                    .offset(x: state.snapDockLeft ? -6 : 6)
            }
        }
        .onAppear {
            DispatchQueue.main.async { applyDisplayScale() }
            WindowSnapManager.shared.playerState = state
            state.bindXYPadSideEffectsIfNeeded()
        }
        .onChange(of: state.eqOpen)        { _ in applyDisplayScale() }
        .onChange(of: state.playlistOpen)  { _ in applyDisplayScale() }
        .onChange(of: state.windowScale)   { _ in applyDisplayScale() }
        .onChange(of: state.playlistPanelHeight) { _ in
            guard !state.isSnapping else { return }
            let appDelegate = AppDelegate.shared
            let win = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
            if let maxY = win?.frame.maxY { appDelegate?.windowAnchorMaxY = maxY }
        }
        // Only fileURL — listing UTType.audio made SwiftUI match a lone audio file on its
        // audio UTI and hand back an audio-content provider with no usable file URL, so a
        // single drop silently failed while multiples (delivered as file-url providers)
        // worked. fileURL alone yields file-url providers for files AND folders.
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        .onReceive(NotificationCenter.default.publisher(for: .headerDoubleClick)) { _ in
            guard !state.tracks.isEmpty else { return }
            state.toggleAccordionPanels()
        }
    }

    private func updateWindowSize(to newSize: CGSize, animated: Bool = false) {
        guard !state.isSnapping else { return }
        let appDelegate = AppDelegate.shared
        guard let window = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        let currentFrame = window.frame

        let targetContentRect = NSRect(origin: .zero, size: NSSize(width: newSize.width, height: newSize.height))
        var targetFrame = window.frameRect(forContentRect: targetContentRect)

        switch state.snapState {
        case .docked, .peeking:
            // Full-width snapped window: the visible sliver sits at the screen edge.
            // Right dock → body extends right, keep the LEFT window edge (minX).
            // Left dock → body extends left, keep the RIGHT window edge (maxX).
            if WindowSnapManager.shared.dockEdge == .left {
                targetFrame.origin.x = currentFrame.maxX - targetFrame.width
            } else {
                targetFrame.origin.x = currentFrame.minX
            }
            targetFrame.origin.y = currentFrame.minY
        case .off, .waiting, .expanded:
            if let center = appDelegate?.magnifyAnchorCenter {
                // Hover-zoom: grow/shrink around the captured center, not the top-left corner.
                targetFrame.origin.x = center.x - targetFrame.width / 2
                targetFrame.origin.y = center.y - targetFrame.height / 2
            } else {
                targetFrame.origin.x = currentFrame.minX
                targetFrame.origin.y = currentFrame.maxY - targetFrame.height  // top (maxY) fixed, grows downward
            }
        }

        guard abs(currentFrame.minX   - targetFrame.minX)   > 0.5 ||
              abs(currentFrame.minY   - targetFrame.minY)   > 0.5 ||
              abs(currentFrame.width  - targetFrame.width)  > 0.5 ||
              abs(currentFrame.height - targetFrame.height) > 0.5
        else {
            switch state.snapState {
            case .off, .waiting, .expanded: appDelegate?.windowAnchorMaxY = currentFrame.maxY
            default: break
            }
            return
        }

        // Whole-point frame — fractional origins smear all 1px hairlines.
        targetFrame.origin.x = targetFrame.origin.x.rounded()
        targetFrame.origin.y = targetFrame.origin.y.rounded()

        // Set anchor BEFORE setFrame — the synchronous observer in AppDelegate must not
        // fight our own intentional resize.
        switch state.snapState {
        case .off, .waiting, .expanded: appDelegate?.windowAnchorMaxY = targetFrame.maxY
        default: break
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        } else {
            window.setFrame(targetFrame, display: true)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let snap = WindowSnapManager.shared
        if snap.snapState == .docked || snap.snapState == .peeking {
            snap.expandCurrentWindow()
        }
        var slots: [URL?] = Array(repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()

        for (i, provider) in providers.enumerated() {
            group.enter()
            provider.resolveFileURL { url in
                defer { group.leave() }
                guard let url = url else { return }
                lock.withLock { slots[i] = url }
            }
        }

        group.notify(queue: .main) {
            let urls = slots.compactMap { $0 }
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                if state.splitPlaylistView, state.secondaryPlaylistTabId != nil {
                    if !state.playlistOpen { state.playlistOpen = true }
                    state.pendingDropURLs = urls
                } else {
                    await state.importURLs(urls)
                }
            }
        }
        return true
    }
}

struct WindowBorderDragOverlay: View {
    let hasContent: Bool

    var body: some View {
        GeometryReader { geo in
            // Header drag zone: active only when tracks are loaded.
            // When empty, the entire player area must receive clicks/drops for the file picker.
            if hasContent {
                let headerWidth = geo.size.width - G.pitchRailWidth - 6
                WindowDragHandle()
                    .frame(width: headerWidth, height: 40)
                    .position(x: headerWidth / 2, y: 20)

                // Artwork column drag zone — covers the art swatch below the 40px header strip.
                // Width (76pt) = shellInsetX(6) + headerPad(12) + artwork(48) + hStackSpacing(10).
                // Stops just before the center column where the BPM badge button lives.
                WindowDragHandle()
                    .frame(width: 76, height: 66)
                    .position(x: 38, y: 33)

                // Left side strip — always present
                WindowDragHandle()
                    .frame(width: 14, height: geo.size.height)
                    .position(x: 7, y: geo.size.height / 2)

                // Right side strip — 4pt wide, stays within shell border, avoids pitch rail buttons
                WindowDragHandle()
                    .frame(width: 4, height: geo.size.height)
                    .position(x: geo.size.width - 2, y: geo.size.height / 2)
            } else {
                // Empty state: wide perimeter strips — center stays interactive for drops
                WindowDragHandle()
                    .frame(width: geo.size.width, height: 40)
                    .position(x: geo.size.width / 2, y: 20)
                WindowDragHandle()
                    .frame(width: geo.size.width, height: 22)
                    .position(x: geo.size.width / 2, y: geo.size.height - 11)
                WindowDragHandle()
                    .frame(width: 22, height: geo.size.height)
                    .position(x: 11, y: geo.size.height / 2)
                WindowDragHandle()
                    .frame(width: 22, height: geo.size.height)
                    .position(x: geo.size.width - 11, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(true)
    }
}

// ── Thin border drag strip ──────────────────────────────────────────────────────
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

final class DragHandleNSView: NSView {
    private var dragStartWindowOrigin: NSPoint = .zero
    private var dragStartMouseScreen: NSPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Process clicks even when the window is not yet key — otherwise the first
    // click activates the window, resets clickCount, and double-click never fires.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NotificationCenter.default.post(name: .headerDoubleClick, object: nil)
            return
        }
        NSCursor.closedHand.set()
        WindowSnapManager.shared.isDragging = true
        dragStartWindowOrigin = window?.frame.origin ?? .zero
        dragStartMouseScreen = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let snapState = WindowSnapManager.shared.snapState
        if snapState == .docked || snapState == .peeking {
            WindowSnapManager.shared.dragSnappedWindowVertically(
                window: window,
                startOrigin: dragStartWindowOrigin,
                startMouse: dragStartMouseScreen,
                currentMouse: mouse
            )
            return
        }
        window?.setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + mouse.x - dragStartMouseScreen.x,
            y: dragStartWindowOrigin.y + mouse.y - dragStartMouseScreen.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        WindowSnapManager.shared.isDragging = false
        let snapState = WindowSnapManager.shared.snapState
        if snapState == .peeking || snapState == .docked {
            WindowSnapManager.shared.constrainSnapPosition(window: window)
        } else {
            // Land on whole points: a mouse drag leaves the window on a fractional
            // origin and every 1px hairline inside smears across two device pixels.
            if let w = window {
                w.setFrameOrigin(NSPoint(x: w.frame.origin.x.rounded(),
                                         y: w.frame.origin.y.rounded()))
            }
            NotificationCenter.default.post(name: .windowDidMove, object: nil)
        }
        NSCursor.openHand.set()
    }
}

// ── Bottom resize handle — outer shell border ─────────────────────────────────
struct BottomResizeHandle: NSViewRepresentable {
    let eqOpen: Bool
    let windowScale: CGFloat
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> BottomResizeHandleNSView {
        let v = BottomResizeHandleNSView()
        v.eqOpen = eqOpen
        v.windowScale = windowScale
        v.onResize = onResize
        return v
    }

    func updateNSView(_ nsView: BottomResizeHandleNSView, context: Context) {
        nsView.eqOpen = eqOpen
        nsView.windowScale = windowScale
        nsView.onResize = onResize
    }
}

final class BottomResizeHandleNSView: NSView {
    var eqOpen = false
    var windowScale: CGFloat = 1.0
    var onResize: (CGFloat) -> Void = { _ in }

    private var startScreenY: CGFloat = 0
    private var startWindowFrame: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        startScreenY = NSEvent.mouseLocation.y
        startWindowFrame = window?.frame ?? .zero
        NSCursor.resizeUpDown.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        // Screen Y decreases when dragging down; delta positive = expanding window
        let delta = startScreenY - NSEvent.mouseLocation.y
        let shellInsets: CGFloat = 12
        let baseH = FullPlayerView.baseHeight
        let eqH: CGFloat = eqOpen ? FullPlayerView.eqPanelHeight : 0
        // Bounds in actual window pixels (scaled); unscaled constants × scale = real pixel size
        let minH = (baseH + eqH + 160 + shellInsets) * windowScale
        let maxH = (baseH + eqH + 700 + shellInsets) * windowScale
        var newFrame = startWindowFrame
        newFrame.size.height = max(minH, min(maxH, startWindowFrame.height + delta))
        newFrame.origin.y = startWindowFrame.maxY - newFrame.size.height
        window.setFrame(newFrame, display: true)
        // Divide by scale to get back to unscaled SwiftUI units that playlistPanelHeight expects
        onResize(newFrame.height / windowScale - baseH - eqH - shellInsets)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}
