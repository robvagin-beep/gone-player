import SwiftUI

struct TransportView: View {
    @EnvironmentObject var state: PlayerState
    @State private var preMuteVolume: Double? = nil
    @State private var speakerHovered = false

    private var canPlayCurrentTrack: Bool {
        guard let current = state.current else { return false }
        return !current.isMissing
    }

    private var isMuted: Bool { state.volume == 0 }

    var body: some View {
        HStack(spacing: 4) {
            // Left: panel toggles
            HStack(spacing: 4) {
                SnapTimerBtn(
                    snapEnabled: state.snapEnabled,
                    snapState: state.snapState,
                    timerFeed: state.snapTimerFeed,
                    action: { toggleSnapMode() },
                    snapNow: {
                        if SplitModeManager.shared.isActive {
                            TooltipPanel.shared.show(text: "Exit Clone Mode first", near: NSEvent.mouseLocation)
                        } else {
                            WindowSnapManager.shared.snapNow()
                        }
                    }
                )
                .goneTooltip("Snap to edge — slides off, reappears on hover")
                IconBtn(icon: "list.bullet", active: state.playlistOpen) {
                    state.playlistOpen.toggle()
                }
                .goneTooltip("Show or hide the track list")
                IconBtn(icon: "slider.vertical.3", active: state.eqOpen) {
                    state.eqOpen.toggle()
                }
                .goneTooltip("Open EQ and effect controls")
                if state.audioEngine !== AudioEngineNext.secondary {
                    GearBtn { openSettings() }
                        .goneTooltip("Settings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: transport
            HStack(spacing: 6) {
                IconBtn(icon: "shuffle", active: state.shuffle, inactiveOpacity: 0.28) { state.shuffle.toggle() }
                HoldSeekBtn(icon: "backward.fill", forward: false, engine: state.audioEngine) {
                    state.selectPreviousTrack()
                }
                .goneTooltip("Previous track · Hold + drag to scrub backward")
                // Primary play/pause
                Button {
                    guard canPlayCurrentTrack else { return }
                    state.togglePlayback()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(G.textOnLight)
                        .frame(width: 28, height: 28)
                        .background(Color(white: 0.91))
                        .clipShape(RoundedRectangle(cornerRadius: G.rButtonPrimary))
                        .opacity(canPlayCurrentTrack ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!canPlayCurrentTrack)

                HoldSeekBtn(icon: "forward.fill", forward: true, engine: state.audioEngine) {
                    state.selectNextTrack()
                }
                .goneTooltip("Next track · Hold + drag to scrub forward")
                RepeatBtn(mode: state.repeatMode) { state.cycleRepeatMode() }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Right: volume
            HStack(spacing: 3) {
                Button {
                    if isMuted {
                        let restore = preMuteVolume ?? 72
                        state.volume = restore
                        state.audioEngine.setVolume(restore)
                        preMuteVolume = nil
                    } else {
                        preMuteVolume = state.volume
                        state.volume = 0
                        state.audioEngine.setVolume(0)
                    }
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isMuted ? G.textPrimary : G.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: G.rButton)
                                .fill(speakerHovered ? Color.white.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { speakerHovered = $0 }

                VolumeSlider(value: Binding(
                    get: { state.volume },
                    set: { v in
                        if v > 0 { preMuteVolume = nil }
                        state.volume = v
                        state.audioEngine.setVolume(v)
                    }
                ))
                .frame(width: 74)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(minHeight: 26)
    }

    @MainActor
    private func openSettings() {
        let window = AppDelegate.shared?.resolvedMainWindow()
            ?? WindowSnapManager.shared.currentWindow
        guard let window else { return }
        SettingsPanel.shared.toggle(near: window, state: state)
    }

    @MainActor
    private func toggleSnapMode() {
        if SplitModeManager.shared.isActive {
            TooltipPanel.shared.show(text: "Exit Clone Mode first", near: NSEvent.mouseLocation)
            return
        }
        let newValue = !state.snapEnabled
        if let appDelegate = AppDelegate.shared {
            appDelegate.setSnapEnabled(newValue)
        } else if let window = WindowSnapManager.shared.currentWindow {
            if newValue {
                WindowSnapManager.shared.enable(window: window)
            } else {
                WindowSnapManager.shared.disable(window: window)
            }
        }
    }

}

// ── Repeat button — 3-state: off / all / one ─────────────────────────────────
struct RepeatBtn: View {
    let mode: PlayerState.RepeatMode
    let action: () -> Void

    @State private var hovered = false

    private var active: Bool { mode != .off }

    private var backgroundColor: Color {
        if active { return Color.white.opacity(0.13) }
        if hovered { return Color.white.opacity(0.08) }
        return .clear
    }

    var body: some View {
        Button {
            hovered = false
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "repeat")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(active ? .white : Color.white.opacity(0.50))
                    .frame(width: 24, height: 24)

                if mode == .one {
                    Text("1")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: G.rButton)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// ── Icon button ───────────────────────────────────────────────────────────────
struct IconBtn: View {
    let icon: String
    var active: Bool = false
    var size: CGFloat = 24
    var inactiveOpacity: Double = 0.50
    let action: () -> Void

    @State private var hovered = false

    private var backgroundColor: Color {
        if active { return Color.white.opacity(0.13) }
        if hovered { return Color.white.opacity(0.08) }
        return .clear
    }

    private var foregroundColor: Color {
        active ? .white : Color.white.opacity(inactiveOpacity)
    }

    var body: some View {
        Button {
            hovered = false
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: G.rButton)
                        .fill(backgroundColor)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// ── Snap timer button — bolt with left→right countdown fill ──────────────────
private struct SnapTimerBtn: View {
    let snapEnabled: Bool
    let snapState: PlayerState.SnapMode
    @ObservedObject var timerFeed: SnapTimerFeed
    let action: () -> Void
    let snapNow: () -> Void

    @State private var hovered = false
    private var delay: Double { WindowSnapManager.shared.inactivityDelay }
    private let size: CGFloat = 24

    private var showFill: Bool {
        (snapState == .waiting || snapState == .expanded) && timerFeed.start != nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Sweep fill — grows left→right over inactivityDelay seconds
            if showFill, let start = timerFeed.start {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(start)
                    let p = CGFloat(min(1.0, max(0.0, elapsed / delay)))
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: size * p, height: size)
                }
            }

            Image(systemName: snapEnabled ? "bolt.fill" : "bolt")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(snapEnabled ? .white : Color.white.opacity(0.50))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: G.rButton)
                .fill(snapEnabled ? Color.white.opacity(0.13) : (hovered ? Color.white.opacity(0.08) : .clear))
        )
        .clipShape(RoundedRectangle(cornerRadius: G.rButton))
        .contentShape(Rectangle())
        .overlay(
            ClickDetector(onSingleClick: action, onDoubleClick: {
                if snapState == .waiting || snapState == .expanded { snapNow() } else { action() }
            })
        )
        .onHover { hovered = $0 }
    }
}

// ── Click detector: fires single/double without the 500ms system disambiguation ──
// SwiftUI's onTapGesture(count:1)+onTapGesture(count:2) waits the full macOS
// double-click interval (~500ms) before confirming a single click. This NSView
// replaces that with a 200ms window, cutting the single-click lag by ~60%.
private struct ClickDetector: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickNSView {
        let v = ClickNSView()
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ v: ClickNSView, context: Context) {
        v.onSingleClick = onSingleClick
        v.onDoubleClick = onDoubleClick
    }
}

final class ClickNSView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingTimer: Timer?
    private var pendingCount = 0
    private let threshold: TimeInterval = 0.20

    override func mouseDown(with event: NSEvent) {
        pendingCount += 1
        pendingTimer?.invalidate()
        let captured = pendingCount
        let timer = Timer(timeInterval: threshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingCount == captured else { return }
                if captured >= 2 { self.onDoubleClick?() } else { self.onSingleClick?() }
                self.pendingCount = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTimer = timer
    }
}

// ── Hold-seek transport button ────────────────────────────────────────────────
// Short press (< 300 ms) → tap action (prev/next track).
// Hold (≥ 300 ms) → scrub at 2× speed. Drag horizontally to adjust multiplier (1×–8×).
// DragValuePanel shows "→ 2.0×" / "← 2.0×" while held, matching the pitch fader indicator.
private struct HoldSeekBtn: View {
    let icon: String
    let forward: Bool
    let engine: AudioEngineNext
    let tapAction: () -> Void

    @State private var hovered = false
    @State private var holding = false
    @State private var dragAccum: CGFloat = 0
    @State private var fillRatio: CGFloat = 0

    // Starts at 2.5% on press, reaches 30% at 200px drag.
    // Power 0.75 curve: quick initial ramp, progressive resistance near max.
    private static let maxAccum: CGFloat = 200
    private static let minPct: Double = 2.5
    private static let maxPct: Double = 30.0

    private func percentFromAccum(_ accum: CGFloat) -> Double {
        let t = Double(max(0, accum)) / Double(Self.maxAccum)
        return Self.minPct + (Self.maxPct - Self.minPct) * pow(t, 0.75)
    }

    private func panelLabel(percent: Double) -> String {
        let s = percent < 10
            ? String(format: "%.1f%%", percent)
            : String(format: "%d%%", Int(percent.rounded()))
        return forward ? "+\(s)" : "-\(s)"
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(holding ? .white : Color.white.opacity(0.50))
            .frame(width: 24, height: 24)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: G.rButton)
                        .fill(holding
                              ? Color.white.opacity(0.15)
                              : (hovered ? Color.white.opacity(0.08) : .clear))
                    if holding {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Color.white.opacity(0.32))
                                .frame(width: max(0, geo.size.width * fillRatio))
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: forward ? .leading : .trailing)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: G.rButton))
                    }
                }
            )
            .overlay(
                PressDetector(
                    onTap: tapAction,
                    onHoldBegan: {
                        holding = true
                        dragAccum = 0
                        fillRatio = 0
                        engine.startHoldSeek(forward: forward)
                        DragValuePanel.shared.show(text: panelLabel(percent: Self.minPct))
                    },
                    onHoldEnded: {
                        holding = false
                        dragAccum = 0
                        fillRatio = 0
                        engine.stopHoldSeek()
                        DragValuePanel.shared.hide()
                    },
                    onPressStart: {
                        engine.stopHoldSeek()
                    },
                    onHoldDrag: { delta in
                        let sign: CGFloat = forward ? 1 : -1
                        dragAccum = max(0, min(Self.maxAccum, dragAccum + delta * sign))
                        fillRatio = dragAccum / Self.maxAccum
                        let pct = percentFromAccum(dragAccum)
                        engine.setHoldSeekPercent(pct)
                        DragValuePanel.shared.show(text: panelLabel(percent: pct))
                    }
                )
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.10), value: holding)
    }
}

private struct PressDetector: NSViewRepresentable {
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void
    let onPressStart: () -> Void
    var onHoldDrag: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> PressDetectNSView {
        let v = PressDetectNSView()
        v.onTap        = onTap
        v.onHoldBegan  = onHoldBegan
        v.onHoldEnded  = onHoldEnded
        v.onPressStart = onPressStart
        v.onHoldDrag   = onHoldDrag
        return v
    }

    func updateNSView(_ v: PressDetectNSView, context: Context) {
        v.onTap        = onTap
        v.onHoldBegan  = onHoldBegan
        v.onHoldEnded  = onHoldEnded
        v.onPressStart = onPressStart
        v.onHoldDrag   = onHoldDrag
    }
}

final class PressDetectNSView: NSView {
    var onTap:        (() -> Void)?
    var onHoldBegan:  (() -> Void)?
    var onHoldEnded:  (() -> Void)?
    var onPressStart: (() -> Void)?
    var onHoldDrag:   ((CGFloat) -> Void)?

    private var holdTimer: Timer?
    private var isHolding  = false
    private var hadHolding = false  // stays true once hold begins; prevents tap on mouseUp after mouseExited
    private let holdThreshold: TimeInterval = 0.30

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseDown(with event: NSEvent) {
        onPressStart?()
        isHolding  = false
        hadHolding = false
        holdTimer?.invalidate()
        let t = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isHolding  = true
            self.hadHolding = true
            self.onHoldBegan?()
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    override func mouseDragged(with event: NSEvent) {
        guard isHolding else { return }
        onHoldDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        if isHolding {
            isHolding = false
            onHoldEnded?()
        } else if !hadHolding {
            // Only fire tap if hold never started during this press.
            // If hadHolding is true but isHolding is false, mouseExited already
            // ended the hold — firing onTap here would spuriously switch tracks.
            onTap?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Cancel pending hold timer — it must not fire after cursor leaves.
        holdTimer?.invalidate()
        holdTimer = nil
        guard isHolding else { return }
        // If the mouse button is still held, the user is drag-holding beyond the button bounds.
        // Keep isHolding true so mouseDragged (which AppKit delivers globally while button is down)
        // continues adjusting seek speed. mouseUp will end the hold correctly.
        if NSEvent.pressedMouseButtons & 1 != 0 { return }
        isHolding = false
        onHoldEnded?()
        // hadHolding stays true → blocks the spurious onTap in the subsequent mouseUp.
    }
}

// ── Gear button — secondary, intentionally paler than all other icons ─────────
private struct GearBtn: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(Color.white.opacity(hovered ? 0.42 : 0.22))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: G.rButton)
                        .fill(hovered ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// ── Volume slider ─────────────────────────────────────────────────────────────
struct VolumeSlider: View {
    @Binding var value: Double
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(0, geo.size.width * value / 100)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: G.rButton)
                    .fill(isHovering ? Color.white.opacity(0.09) : Color.white.opacity(0.05))
                Rectangle()
                    .fill(Color.white.opacity(isHovering ? 0.24 : 0.14))
                    .frame(width: fillWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: G.rButton))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        value = max(0, min(100, v.location.x / geo.size.width * 100))
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: isHovering ? 22 : 18)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovering)
        .cursor(.pointingHand)
    }
}
