import SwiftUI
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
                PeekPanelView(isDropTarget: $isDropTarget, onFileDrop: handleDrop)
                    .offset(x: 6)
            }
        }
        .onAppear {
            DispatchQueue.main.async { updateWindowSize(to: shellSize) }
            WindowSnapManager.shared.playerState = state
        }
        .onChange(of: state.eqOpen) { _ in updateWindowSize(to: shellSize) }
        .onChange(of: state.playlistOpen) { _ in updateWindowSize(to: shellSize) }
        .onChange(of: state.playlistPanelHeight) { _ in
            guard !state.isSnapping else { return }
            let appDelegate = NSApp.delegate as? AppDelegate
            let win = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow
            if let maxY = win?.frame.maxY { appDelegate?.windowAnchorMaxY = maxY }
        }
        // XY pad → audio engine wiring (always active regardless of EQ panel visibility)
        .onChange(of: state.xyPoint) { pt in
            guard state.xyActive else { return }
            applyXYEffect(pt)
        }
        .onChange(of: state.xyActive) { active in
            if active {
                state.cancelXYSpring()
                if state.xyEffectAxis == .lfo     { state.startLFO() }
                if state.xyEffectAxis == .bpmChop { state.startBPMChop() }
                applyXYEffect(state.xyPoint)
            } else {
                state.stopLFO()
                state.stopBPMChop()
                state.cancelXYSpring()
                state.hpfCutoff    = 0
                state.lpfCutoff    = 0
                state.reverbAmount = 0
                state.xyResonance  = 1.0
                AudioEngineNext.shared.setHPF(cutoff: 0)
                AudioEngineNext.shared.setLPF(cutoff: 0)
                AudioEngineNext.shared.setLPFResonance(1.0)
                AudioEngineNext.shared.setReverb(amount: 0)
                state.startXYSpring()
            }
        }
        .onChange(of: state.xyEffectAxis) { _ in
            state.stopLFO()
            state.stopBPMChop()
            AudioEngineNext.shared.setLPF(cutoff: 0)
            state.lpfCutoff = 0
            guard state.xyActive else { return }
            if state.xyEffectAxis == .lfo     { state.startLFO() }
            if state.xyEffectAxis == .bpmChop { state.startBPMChop() }
            applyXYEffect(state.xyPoint)
        }
        .onChange(of: state.xyHoldMode) { holdMode in
            guard !holdMode, state.xyActive else { return }
            // Spring back to center, then deactivate XY (center = zero effect)
            state.startXYSpring {
                state.xyActive = false
            }
        }
        .onDrop(of: [UTType.audio, UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        .onReceive(NotificationCenter.default.publisher(for: .headerDoubleClick)) { _ in
            guard !state.tracks.isEmpty else { return }
            state.toggleAccordionPanels()
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

    private func updateWindowSize(to newSize: CGSize, animated: Bool = false) {
        guard !state.isSnapping else { return }
        let appDelegate = NSApp.delegate as? AppDelegate
        guard let window = appDelegate?.resolvedMainWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        let currentFrame = window.frame

        let targetContentRect = NSRect(origin: .zero, size: NSSize(width: newSize.width, height: newSize.height))
        var targetFrame = window.frameRect(forContentRect: targetContentRect)

        switch state.snapState {
        case .docked, .peeking:
            targetFrame.origin.x = currentFrame.maxX - targetFrame.width
            targetFrame.origin.y = currentFrame.minY
        case .off, .waiting, .expanded:
            targetFrame.origin.x = currentFrame.minX
            targetFrame.origin.y = currentFrame.maxY - targetFrame.height  // top (maxY) fixed, grows downward
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

    private func applyXYEffect(_ point: CGPoint) {
        let x = Float(point.x)
        let y = Float(point.y)
        // Audio engine updates at full rate. No @Published writes here —
        // avoids secondary SwiftUI update cascade on every 60fps XY tick.
        // EQCurveView derives filter values from xyPoint directly.
        // EQKnobStack labels remain at pre-XY values during XY (acceptable).
        switch state.xyEffectAxis {
        case .filter:
            AudioEngineNext.shared.setHPF(cutoff: x * 0.55)
            AudioEngineNext.shared.setLPF(cutoff: (1 - y) * 0.55)
            AudioEngineNext.shared.setLPFResonance(1.0)
        case .reverb:
            AudioEngineNext.shared.setReverb(amount: x)
        case .reso:
            let cutoff    = x * 0.75
            let bandwidth = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            AudioEngineNext.shared.setHPF(cutoff: 0)
            AudioEngineNext.shared.setLPF(cutoff: cutoff)
            AudioEngineNext.shared.setLPFResonance(bandwidth)
        case .filtVerb:
            AudioEngineNext.shared.setHPF(cutoff: 0)
            AudioEngineNext.shared.setLPF(cutoff: x * 0.7)
            AudioEngineNext.shared.setLPFResonance(1.0)
            AudioEngineNext.shared.setReverb(amount: y)
        case .lfo:
            AudioEngineNext.shared.setHPF(cutoff: 0)
            AudioEngineNext.shared.setLPFResonance(1.0)
            state.startLFO()
        case .bpmChop:
            AudioEngineNext.shared.setHPF(cutoff: 0)
            AudioEngineNext.shared.setLPFResonance(1.0)
            state.startBPMChop()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let snap = WindowSnapManager.shared
        if snap.snapState == .docked || snap.snapState == .peeking {
            snap.expandCurrentWindow()
        }
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

                // Left side strip — always present
                WindowDragHandle()
                    .frame(width: 14, height: geo.size.height)
                    .position(x: 7, y: geo.size.height / 2)

                // Right side strip — stays in shell border area, avoids pitch rail
                WindowDragHandle()
                    .frame(width: 10, height: geo.size.height)
                    .position(x: geo.size.width - 5, y: geo.size.height / 2)
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
