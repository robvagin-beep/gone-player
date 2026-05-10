import AppKit
import SwiftUI

// ── BandHitTestView — transparent NSView; only captures events near the bar ────
// Used as the root content view of CrossfaderGapWindow so clicks outside the
// bar zone fall through to whatever window is below (player windows, desktop).
final class BandHitTestView: NSView {
    var segA: NSPoint = .zero
    var segB: NSPoint = .zero
    let hitRadius: CGFloat = 60

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Require endpoints to be meaningfully apart (> 4pt) before accepting hits.
        // Covers both pre-geometry state (both .zero) and coincident windows.
        let dx = segB.x - segA.x, dy = segB.y - segA.y
        guard dx*dx + dy*dy > 16 else { return nil }
        return distanceToSegment(point) <= hitRadius ? super.hitTest(point) : nil
    }

    private func distanceToSegment(_ p: NSPoint) -> CGFloat {
        let dx = segB.x - segA.x, dy = segB.y - segA.y
        let len2 = dx*dx + dy*dy
        guard len2 > 0 else { return hypot(p.x - segA.x, p.y - segA.y) }
        let t = max(0, min(1, ((p.x - segA.x)*dx + (p.y - segA.y)*dy) / len2))
        return hypot(p.x - (segA.x + t*dx), p.y - (segA.y + t*dy))
    }
}

// ── CrossfaderGapWindow — bounding-box window that spans both player centres ──
// Much smaller than the full screen; only covers the area between the windows.
// Player windows at (screenSaverWindow) level render on top → line ends hidden.
// Level = screenSaverWindow-1 so it still floats above other apps.
final class CrossfaderGapWindow: NSPanel {
    private weak var manager: SplitModeManager?
    private weak var windowA: NSWindow?
    private weak var windowB: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var hc: NSHostingController<CrossfaderBridgeView>?
    private weak var hitView: BandHitTestView?

    // Extra space around the centre-to-centre segment.
    // Coincidentally matches BandHitTestView.hitRadius (60) but serves a different purpose:
    // pad expands the bounding-box window; hitRadius defines the click-capture zone.
    private static let pad: CGFloat = 60

    init(manager: SplitModeManager, windowA: NSWindow, windowB: NSWindow) {
        self.manager = manager
        self.windowA = windowA
        self.windowB = windowB

        super.init(
            contentRect: Self.boundingRect(a: windowA, b: windowB),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor    = .clear
        hasShadow          = false
        ignoresMouseEvents = false
        let ssl            = Int(CGWindowLevelForKey(.screenSaverWindow))
        level              = NSWindow.Level(rawValue: ssl - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .fullScreenDisallowsTiling, .ignoresCycle]
        hidesOnDeactivate  = false

        // Root view: BandHitTestView passes through clicks far from the bar
        let bv = BandHitTestView(frame: contentRect(forFrameRect: frame))
        bv.autoresizingMask = [.width, .height]
        contentView = bv
        hitView = bv

        let view = CrossfaderBridgeView(manager: manager, panel: self)
        let controller = NSHostingController(rootView: view)
        controller.view.frame = bv.bounds
        controller.view.autoresizingMask = [.width, .height]
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = CGColor.clear
        bv.addSubview(controller.view)
        hc = controller

        updateGeometry()

        let refresh = { [weak self] (_: Notification) in
            guard let self,
                  let a = self.windowA, let b = self.windowB else { return }
            // Reposition + resize window to new bounding box
            self.setFrame(Self.boundingRect(a: a, b: b), display: true, animate: false)
            self.updateGeometry()
            // Increment geometryVersion instead of replacing rootView —
            // Canvas already reads panel geometry directly; this just triggers a redraw
            self.manager?.geometryVersion += 1
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(contentsOf: [
                NotificationCenter.default.addObserver(forName: name, object: windowA, queue: .main, using: refresh),
                NotificationCenter.default.addObserver(forName: name, object: windowB, queue: .main, using: refresh)
            ])
        }
        // Tear down proactively if either player window closes independently
        for win in [windowA, windowB] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: win, queue: .main
                ) { [weak self] _ in self?.close() }
            )
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    override func close() {
        if !observers.isEmpty {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
        }
        super.close()
    }

    // ── Helpers called by the SwiftUI view ────────────────────────────────────

    func frameA()      -> CGRect  { windowA?.frame ?? .zero }
    func frameB()      -> CGRect  { windowB?.frame ?? .zero }
    func panelOrigin() -> CGPoint { frame.origin }
    func panelHeight() -> CGFloat { frame.height }

    // ── Private ───────────────────────────────────────────────────────────────

    // Bounding rect of the two window centres + padding (AppKit / screen coords)
    private static func boundingRect(a: NSWindow, b: NSWindow) -> NSRect {
        let ax = a.frame.midX, ay = a.frame.midY
        let bx = b.frame.midX, by = b.frame.midY
        let minX = min(ax, bx) - pad
        let minY = min(ay, by) - pad
        let maxX = max(ax, bx) + pad
        let maxY = max(ay, by) + pad
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // Sync hit-test segment to current window positions (AppKit coords, y-up)
    private func updateGeometry() {
        guard let hv = hitView,
              let a = windowA, let b = windowB else { return }
        let origin = frame.origin
        hv.segA = NSPoint(x: a.frame.midX - origin.x, y: a.frame.midY - origin.y)
        hv.segB = NSPoint(x: b.frame.midX - origin.x, y: b.frame.midY - origin.y)
    }
}

// ── Scroll wheel capture — transparent NSView forwarding deltas to a closure ──
private final class ScrollWheelNSView: NSView {
    var onScroll: (CGFloat) -> Void = { _ in }
    override func scrollWheel(with event: NSEvent) {
        // Ignore trackpad momentum phase — prevents crossfader drifting after finger lift
        guard event.momentumPhase == .stationary else { return }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let delta = abs(dx) >= abs(dy) ? dx : -dy   // right/up = positive (toward B)
        // Trackpad gives continuous pixel-scale deltas (large); mouse wheel gives ~1.0 per detent.
        // Boost mouse detents so a reasonable number of notches (~30) spans the full crossfader range.
        let mouseDetentScale: CGFloat = 10.0
        let adjusted = event.hasPreciseScrollingDeltas ? delta : delta * mouseDetentScale
        onScroll(adjusted)
    }
}

private struct ScrollWheelHandler: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> ScrollWheelNSView {
        let v = ScrollWheelNSView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

// ── CrossfaderBridgeView — draws tilted flat plaque at any angle ──────────────
struct CrossfaderBridgeView: View {
    @ObservedObject var manager: SplitModeManager
    weak var panel: CrossfaderGapWindow?

    @State private var isDragging = false

    private let scrollSensitivity: Double = 0.003  // crossfade units per scroll delta point

    var body: some View {
        GeometryReader { _ in
            Canvas { ctx, _ in
                guard let panel else { return }
                let _ = manager.geometryVersion   // forces Canvas redraw on window move
                let fA     = panel.frameA()
                let fB     = panel.frameB()
                let origin = panel.panelOrigin()
                let pH     = panel.panelHeight()
                guard fA != .zero, fB != .zero else { return }

                // Window centres in SwiftUI coords (y flipped: screen-y up → SwiftUI-y down)
                let cA = CGPoint(x: fA.midX - origin.x, y: pH - (fA.midY - origin.y))
                let cB = CGPoint(x: fB.midX - origin.x, y: pH - (fB.midY - origin.y))

                let dx  = cB.x - cA.x
                let dy  = cB.y - cA.y
                let len = hypot(dx, dy)
                guard len > 4 else { return }

                let ux = dx / len   // unit vector along bar
                let uy = dy / len
                let nx = -uy        // perpendicular unit (rotated 90°)
                let ny =  ux

                // Extend bar past the centres so ends disappear under player windows
                let ext: CGFloat = 30
                let eA = CGPoint(x: cA.x - ux * ext, y: cA.y - uy * ext)
                let eB = CGPoint(x: cB.x + ux * ext, y: cB.y + uy * ext)

                let barHW: CGFloat = 20    // half-width of the plaque (wider track)

                // ── Edge-to-edge active zone ──────────────────────────────────
                let absDX = abs(fB.midX - fA.midX)
                let absDY = abs(fB.midY - fA.midY)
                let t_edgeA: CGFloat
                let t_edgeB: CGFloat
                if absDX >= absDY && absDX > 10 {
                    t_edgeA = (fA.width  / 2) / absDX
                    t_edgeB = 1.0 - (fB.width  / 2) / absDX
                } else if absDY > 10 {
                    t_edgeA = (fA.height / 2) / absDY
                    t_edgeB = 1.0 - (fB.height / 2) / absDY
                } else {
                    t_edgeA = 0.1; t_edgeB = 0.9
                }
                let activeRange = max(0.01, t_edgeB - t_edgeA)

                // ── 1. Plaque — contour only, minimal fill ────────────────────
                let midX = (cA.x + cB.x) / 2
                let midY = (cA.y + cB.y) / 2
                let halfLen = len / 2 + ext
                let barXform = CGAffineTransform(a: ux, b: uy, c: nx, d: ny, tx: midX, ty: midY)
                let barRect  = CGRect(x: -halfLen, y: -barHW, width: 2*halfLen, height: 2*barHW)
                let bar = Path(roundedRect: barRect, cornerRadius: barHW).applying(barXform)

                ctx.fill(bar, with: .color(Color(white: 0.12).opacity(0.55)))
                ctx.stroke(bar, with: .color(Color(white: 0.50).opacity(0.40)),
                           style: StrokeStyle(lineWidth: 1.0))

                // ── 2. Centre spine line ──────────────────────────────────────
                var spine = Path()
                spine.move(to: eA)
                spine.addLine(to: eB)
                ctx.stroke(spine, with: .color(Color(white: 0.65).opacity(0.80)),
                           style: StrokeStyle(lineWidth: 1.5))

                // ── 3. Handle (thumb) — tall rounded knob ─────────────────────
                let barT  = CGFloat(t_edgeA) + CGFloat(manager.crossfade) * CGFloat(activeRange)
                let hx    = cA.x + dx * barT
                let hy    = cA.y + dy * barT

                let tHL: CGFloat = isDragging ? 14 : 11   // half-length along bar
                let tHW: CGFloat = barHW + 14              // half-width: extends past plaque edges
                let cornerR: CGFloat = 7

                let xform = CGAffineTransform(a: ux, b: uy, c: nx, d: ny, tx: hx, ty: hy)
                let localRect = CGRect(x: -tHL, y: -tHW, width: 2*tHL, height: 2*tHW)
                let thumb = Path(roundedRect: localRect, cornerRadius: cornerR).applying(xform)

                ctx.fill(thumb,  with: .color(Color(white: isDragging ? 0.72 : 0.58).opacity(isDragging ? 0.98 : 0.92)))
                ctx.stroke(thumb, with: .color(Color(white: 0.18).opacity(0.90)),
                           style: StrokeStyle(lineWidth: 1.0))

                // Centre divider tick
                var div = Path()
                div.move(to:    CGPoint(x: 0, y: -tHW + 6))
                div.addLine(to: CGPoint(x: 0, y:  tHW - 6))
                ctx.stroke(div.applying(xform), with: .color(Color(white: 0.18).opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.0))

                // A / B labels
                let lbl = Font.system(size: 8, weight: .bold, design: .monospaced)
                let lo: CGFloat = barHW + 8
                ctx.draw(Text("A").font(lbl).foregroundColor(Color(white: 0.60).opacity(0.75)),
                         at: CGPoint(x: cA.x + nx*lo, y: cA.y + ny*lo))
                ctx.draw(Text("B").font(lbl).foregroundColor(Color(white: 0.60).opacity(0.75)),
                         at: CGPoint(x: cB.x + nx*lo, y: cB.y + ny*lo))
            }
            .contentShape(Rectangle())
            .background(
                ScrollWheelHandler { delta in
                    manager.setCrossfade(manager.crossfade + Double(delta) * scrollSensitivity)
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { val in
                        guard let panel else { return }
                        isDragging = true
                        let fA     = panel.frameA()
                        let fB     = panel.frameB()
                        let origin = panel.panelOrigin()
                        let pH     = panel.panelHeight()
                        let cA = CGPoint(x: fA.midX - origin.x, y: pH - (fA.midY - origin.y))
                        let cB = CGPoint(x: fB.midX - origin.x, y: pH - (fB.midY - origin.y))
                        let dx = cB.x - cA.x, dy = cB.y - cA.y
                        let len2 = dx*dx + dy*dy
                        guard len2 > 1 else { return }
                        let aDX = abs(fB.midX - fA.midX), aDY = abs(fB.midY - fA.midY)
                        let tA: CGFloat
                        let tB: CGFloat
                        if aDX >= aDY && aDX > 10 {
                            tA = (fA.width  / 2) / aDX;  tB = 1.0 - (fB.width  / 2) / aDX
                        } else if aDY > 10 {
                            tA = (fA.height / 2) / aDY;  tB = 1.0 - (fB.height / 2) / aDY
                        } else { tA = 0.1; tB = 0.9 }
                        let range = max(0.01, tB - tA)
                        let pt   = val.location
                        let proj = ((pt.x - cA.x)*dx + (pt.y - cA.y)*dy) / len2
                        let norm = (proj - tA) / range
                        manager.setCrossfade(Double(norm))
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .ignoresSafeArea()
    }
}
