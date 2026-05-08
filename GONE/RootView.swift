import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let headerDoubleClick = Notification.Name("GONEHeaderDoubleClick")
    static let windowDidMove     = Notification.Name("GONEWindowDidMove")
}

struct RootView: View {
    @EnvironmentObject var state: PlayerState
    @State private var isDropTarget = false
    @State private var windowTopAnchor: CGFloat = 0
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
        }
        .frame(width: shellSize.width, height: shellSize.height, alignment: .top)
        .background(Color.clear)
        .overlay {
            WindowBorderDragOverlay(hasContent: !state.tracks.isEmpty)
        }
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
        // Peek panel — visible when snapped to right edge
        .overlay(alignment: .leading) {
            if state.snapState == .docked || state.snapState == .peeking {
                PeekPanelView()
                    .offset(x: 6)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                // Seed anchor before updateWindowSize — it may be a no-op if window is already
                // the right size, and we must never have windowTopAnchor == 0 at panel-toggle time.
                let w = (NSApp.delegate as? AppDelegate)?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
                if let topY = w?.frame.maxY, topY > 0 { windowTopAnchor = topY }
                updateWindowSize(to: shellSize)
            }
            WindowSnapManager.shared.playerState = state
        }
        .onChange(of: state.eqOpen) { _, _ in
            let appDelegate = NSApp.delegate as? AppDelegate
            let win = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
            let winTop: CGFloat = win?.frame.maxY ?? 0
            let anchor: CGFloat? = winTop > 0 ? winTop : (windowTopAnchor > 0 ? windowTopAnchor : nil)
            updateWindowSize(to: shellSize, anchorTopY: anchor)
            DispatchQueue.main.async {
                updateWindowSize(to: shellSize, anchorTopY: anchor)
            }
        }
        .onChange(of: state.playlistOpen) { _, _ in
            let appDelegate = NSApp.delegate as? AppDelegate
            let win = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
            let winTop: CGFloat = win?.frame.maxY ?? 0
            let anchor: CGFloat? = winTop > 0 ? winTop : (windowTopAnchor > 0 ? windowTopAnchor : nil)
            updateWindowSize(to: shellSize, anchorTopY: anchor)
            DispatchQueue.main.async {
                updateWindowSize(to: shellSize, anchorTopY: anchor)
            }
        }
        .onDrop(of: [UTType.audio, UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        .onReceive(NotificationCenter.default.publisher(for: .headerDoubleClick)) { _ in
            guard !state.tracks.isEmpty else { return }
            state.toggleAccordionPanels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowDidMove)) { _ in
            guard !state.isSnapping else { return }
            guard state.snapState == .off || state.snapState == .waiting || state.snapState == .expanded else { return }
            let w = (NSApp.delegate as? AppDelegate)?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
            if let maxY = w?.frame.maxY { windowTopAnchor = maxY }
        }
        .overlay(alignment: .bottom) {
            if !state.tracks.isEmpty && state.playlistOpen {
                BottomResizeHandle(eqOpen: state.eqOpen) { newH in
                    state.playlistPanelHeight = max(160, min(700, newH))
                }
                .frame(height: 10)
            }
        }
    }

    private func updateWindowSize(to newSize: CGSize, animated: Bool = false, anchorTopY: CGFloat? = nil) {
        guard !state.isSnapping else { return }
        let appDelegate = NSApp.delegate as? AppDelegate
        guard let window = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        let currentFrame = window.frame

        let targetContentRect = NSRect(origin: .zero, size: NSSize(width: newSize.width, height: newSize.height))
        var targetFrame = window.frameRect(forContentRect: targetContentRect)

        // anchorTopY is captured before SwiftUI's automatic resize fires —
        // the deferred async call uses it to undo any bottom-anchored reposition.
        let topY = anchorTopY ?? currentFrame.maxY
        switch state.snapState {
        case .docked, .peeking:
            targetFrame.origin.x = currentFrame.maxX - targetFrame.width
            targetFrame.origin.y = currentFrame.minY
        case .off, .waiting, .expanded:
            targetFrame.origin.x = currentFrame.minX
            targetFrame.origin.y = topY - targetFrame.height
        }

        // Check full frame (size + position) — size-only guard misses SwiftUI's
        // bottom-anchored reposition that leaves correct size but wrong origin.
        guard abs(currentFrame.minX   - targetFrame.minX)   > 0.5 ||
              abs(currentFrame.minY   - targetFrame.minY)   > 0.5 ||
              abs(currentFrame.width  - targetFrame.width)  > 0.5 ||
              abs(currentFrame.height - targetFrame.height) > 0.5
        else {
            // Frame already correct — still sync anchor so it's never stale
            switch state.snapState {
            case .off, .waiting, .expanded: windowTopAnchor = currentFrame.maxY
            default: break
            }
            return
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

        // Keep anchor current so panel-open/close always has the right top-Y.
        // Only applies to non-snapped states — docked/peeking anchor to the right edge, not top.
        switch state.snapState {
        case .off, .waiting, .expanded:
            windowTopAnchor = targetFrame.maxY
        default:
            break
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
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
                lock.withLock { urls.append(url) }
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                await state.importURLs(urls)
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
                    .frame(width: headerWidth, height: 64)
                    .position(x: headerWidth / 2, y: 32)
            } else {
                // Empty state: only a thin top strip so the rest stays interactive
                WindowDragHandle()
                    .frame(width: geo.size.width, height: 18)
                    .position(x: geo.size.width / 2, y: 9)
            }

            // Left side strip — always present
            WindowDragHandle()
                .frame(width: 14, height: geo.size.height)
                .position(x: 7, y: geo.size.height / 2)

            // Right side strip — stays in shell border area, avoids pitch rail
            WindowDragHandle()
                .frame(width: 10, height: geo.size.height)
                .position(x: geo.size.width - 5, y: geo.size.height / 2)
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
        dragStartWindowOrigin = window?.frame.origin ?? .zero
        dragStartMouseScreen = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + mouse.x - dragStartMouseScreen.x,
            y: dragStartWindowOrigin.y + mouse.y - dragStartMouseScreen.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        let snapState = WindowSnapManager.shared.snapState
        if snapState == .peeking || snapState == .docked {
            WindowSnapManager.shared.constrainSnapPosition(window: window)
        } else {
            NotificationCenter.default.post(name: .windowDidMove, object: nil)
        }
        NSCursor.openHand.set()
    }
}

// ── Bottom resize handle — outer shell border ─────────────────────────────────
struct BottomResizeHandle: NSViewRepresentable {
    let eqOpen: Bool
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> BottomResizeHandleNSView {
        let v = BottomResizeHandleNSView()
        v.eqOpen = eqOpen
        v.onResize = onResize
        return v
    }

    func updateNSView(_ nsView: BottomResizeHandleNSView, context: Context) {
        nsView.eqOpen = eqOpen
        nsView.onResize = onResize
    }
}

final class BottomResizeHandleNSView: NSView {
    var eqOpen = false
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
        let minH = baseH + eqH + 160 + shellInsets
        let maxH = baseH + eqH + 700 + shellInsets
        var newFrame = startWindowFrame
        newFrame.size.height = max(minH, min(maxH, startWindowFrame.height + delta))
        newFrame.origin.y = startWindowFrame.maxY - newFrame.size.height
        window.setFrame(newFrame, display: true)
        onResize(newFrame.height - baseH - eqH - shellInsets)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}
