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
                    timerStart: state.snapTimerStart,
                    action: { toggleSnapMode() },
                    snapNow: { WindowSnapManager.shared.snapNow() }
                )
                .goneTooltip("Snap to edge — slides off, reappears on hover. Double-click to hide immediately")
                IconBtn(icon: "list.bullet", active: state.playlistOpen) {
                    state.playlistOpen.toggle()
                }
                .goneTooltip("Show or hide the track list")
                IconBtn(icon: "slider.vertical.3", active: state.eqOpen) {
                    state.eqOpen.toggle()
                }
                .goneTooltip("Open EQ and effect controls")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Center: transport
            HStack(spacing: 6) {
                IconBtn(icon: "shuffle", active: state.shuffle) { state.shuffle.toggle() }
                IconBtn(icon: "backward.fill") {
                    state.selectPreviousTrack()
                }
                // Primary play/pause
                Button {
                    guard canPlayCurrentTrack else { return }
                    state.togglePlayback()
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(G.textOnLight)
                        .frame(width: 28, height: 28)
                        .background(G.accentPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: G.rButtonPrimary))
                        .opacity(canPlayCurrentTrack ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!canPlayCurrentTrack)

                IconBtn(icon: "forward.fill") {
                    state.selectNextTrack()
                }
                RepeatBtn(mode: state.repeatMode) { state.cycleRepeatMode() }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Right: volume
            HStack(spacing: 3) {
                Button {
                    if isMuted {
                        let restore = preMuteVolume ?? 72
                        state.volume = restore
                        AudioEngineNext.shared.setVolume(restore)
                        preMuteVolume = nil
                    } else {
                        preMuteVolume = state.volume
                        state.volume = 0
                        AudioEngineNext.shared.setVolume(0)
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
                        AudioEngineNext.shared.setVolume(v)
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
    private func toggleSnapMode() {
        let newValue = !state.snapEnabled
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.setSnapEnabled(newValue)
        } else if let window = WindowSnapManager.shared.currentWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
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
    let action: () -> Void

    @State private var hovered = false

    private var backgroundColor: Color {
        if active { return Color.white.opacity(0.13) }
        if hovered { return Color.white.opacity(0.08) }
        return .clear
    }

    private var foregroundColor: Color {
        active ? .white : Color.white.opacity(0.50)
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
    let timerStart: Date?
    let action: () -> Void
    let snapNow: () -> Void

    @State private var hovered = false
    private var delay: Double { WindowSnapManager.shared.inactivityDelay }
    private let size: CGFloat = 24

    private var showFill: Bool {
        (snapState == .waiting || snapState == .expanded) && timerStart != nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Sweep fill — grows left→right over inactivityDelay seconds
            if showFill, let start = timerStart {
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
        .onTapGesture(count: 2) {
            if snapState == .waiting || snapState == .expanded {
                snapNow()
            } else {
                action()
            }
        }
        .onTapGesture(count: 1) {
            action()
        }
        .onHover { hovered = $0 }
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

