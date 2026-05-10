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
               let artData = state.current?.artworkData {
                ArtSwatchView(
                    index: state.tracks.firstIndex(where: { $0.id == currentId }) ?? 0,
                    size: 48,
                    cornerRadius: 7,
                    artworkData: artData,
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
        // Scale the ENTIRE shell — glass border + content scale together.
        // Math: SwiftUI centers shellSize in scaledShellSize window; scaleEffect
        // from view center equals window center → visual fills window exactly.
        .scaleEffect(state.windowScale)
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
        // Peek panel — visible when snapped to right edge
        .overlay(alignment: .leading) {
            if state.snapState == .docked || state.snapState == .peeking {
                PeekPanelView(isDropTarget: $isDropTarget, onFileDrop: handleDrop)
                    .offset(x: 6)
            }
        }
        .onAppear {
            DispatchQueue.main.async { applyDisplayScale() }
            WindowSnapManager.shared.playerState = state
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
                if state.xyEffectAxis == .slicer  { state.startSlicer() }
                applyXYEffect(state.xyPoint)
            } else {
                state.stopLFO()
                state.stopBPMChop()
                state.stopSlicer()
                state.cancelXYSpring()
                state.hpfCutoff    = 0
                state.lpfCutoff    = 0
                state.reverbAmount = 0
                state.xyResonance  = 1.0
                state.audioEngine.setHPF(cutoff: 0)
                state.audioEngine.setLPF(cutoff: 0)
                state.audioEngine.setLPFResonance(1.0)
                state.audioEngine.setReverb(amount: 0)
                state.audioEngine.resetFXNodes()
                state.startXYSpring()
            }
        }
        .onChange(of: state.xyEffectAxis) { _ in
            state.stopLFO()
            state.stopBPMChop()
            state.stopSlicer()
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPF(cutoff: 0)
            state.audioEngine.resetFXNodes()
            state.lpfCutoff = 0
            guard state.xyActive else { return }
            if state.xyEffectAxis == .lfo     { state.startLFO() }
            if state.xyEffectAxis == .bpmChop { state.startBPMChop() }
            if state.xyEffectAxis == .slicer  { state.startSlicer() }
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
        // Audio engine updates at full rate.
        // @Published state vars (hpfCutoff, lpfCutoff, xyResonance) are updated
        // so EQKnobStack labels and EQCurveView reflect the XY position.
        switch state.xyEffectAxis {
        case .filter:
            let hpf = x * 0.55
            let lpf = (1 - y) * 0.55
            state.audioEngine.setHPF(cutoff: hpf)
            state.audioEngine.setLPF(cutoff: lpf)
            state.audioEngine.setLPFResonance(1.0)
            state.hpfCutoff  = hpf
            state.lpfCutoff  = lpf
            state.xyResonance = 1.0
        case .lowpass:
            let bw = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPF(cutoff: x * 0.85)
            state.audioEngine.setLPFResonance(bw)
            state.hpfCutoff  = 0
            state.lpfCutoff  = x * 0.85
            state.xyResonance = bw
        case .highpass:
            let bw = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            state.audioEngine.setLPF(cutoff: 0)
            state.audioEngine.setHPF(cutoff: x * 0.85)
            state.audioEngine.setHPFResonance(bw)
            state.lpfCutoff  = 0
            state.hpfCutoff  = x * 0.85
            state.xyResonance = bw
        case .bandpass:
            let centerHz = 100.0 * pow(80.0, Double(x))
            let widthOct = 0.5 + (1.0 - Double(y)) * 3.0
            let hpfHz    = centerHz / pow(2.0, widthOct * 0.5)
            let lpfHz    = centerHz * pow(2.0, widthOct * 0.5)
            let hpfCut   = Float(max(0, min(1, log(max(20, hpfHz) / 20.0) / log(100.0))))
            let lpfCut   = Float(max(0, min(1, log(20000.0 / max(200, lpfHz)) / log(100.0))))
            state.audioEngine.setHPF(cutoff: hpfCut)
            state.audioEngine.setLPF(cutoff: lpfCut)
            state.audioEngine.setLPFResonance(1.0)
            state.hpfCutoff  = hpfCut
            state.lpfCutoff  = lpfCut
            state.xyResonance = 1.0
        case .reso:
            let cutoff    = x * 0.75
            let bandwidth = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPF(cutoff: cutoff)
            state.audioEngine.setLPFResonance(bandwidth)
            state.hpfCutoff  = 0
            state.lpfCutoff  = cutoff
            state.xyResonance = bandwidth
        case .lfo:
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPFResonance(1.0)
            state.hpfCutoff = 0
            state.startLFO()
        case .bpmChop:
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPFResonance(1.0)
            state.hpfCutoff = 0
            state.startBPMChop()
        case .slicer:
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPF(cutoff: 0)
            state.hpfCutoff = 0
            state.lpfCutoff = 0
            state.startSlicer()
        case .reverb:
            state.audioEngine.setReverb(amount: x)
            state.reverbAmount = x
        case .filtVerb:
            let lpf = x * 0.7
            state.audioEngine.setHPF(cutoff: 0)
            state.audioEngine.setLPF(cutoff: lpf)
            state.audioEngine.setLPFResonance(1.0)
            state.audioEngine.setReverb(amount: y)
            state.hpfCutoff   = 0
            state.lpfCutoff   = lpf
            state.reverbAmount = y
        case .simpleDelay:
            let time     = Double(x) * 1.0
            let feedback = y * 0.75
            let wet      = min(1.0, y * 1.5)
            state.audioEngine.setDelay(time: time, feedback: feedback, wet: wet)
        case .dubDelay:
            let time      = Double(x) * 0.75
            let feedback  = y * 0.65
            let wet       = min(1.0, y * 1.2)
            let darkness  = Float(max(200, 22050.0 * pow(0.005, Double(y))))
            state.audioEngine.setDelay(time: time, feedback: feedback, wet: wet, lowPassCutoff: darkness)
        case .lofi:
            state.audioEngine.setLoFi(wet: x * y)
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
