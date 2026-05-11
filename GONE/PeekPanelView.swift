import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PeekPanelView: View {
    @Binding var isDropTarget: Bool
    var onFileDrop: ([NSItemProvider]) -> Bool = { _ in false }
    @EnvironmentObject var state: PlayerState
    @ObservedObject private var progressFeed = PlaybackProgressFeed.shared
    @State private var dragStartWindowOrigin: NSPoint?
    @State private var dragStartMouseY: CGFloat = 0
    @State private var hasDraggedBeyondThreshold = false
    @State private var prevHovered = false
    @State private var nextHovered = false
    private let peekingVerticalInset: CGFloat = 6

    private var panelWidth: CGFloat {
        state.snapState == .docked ? 84 : 96
    }

    var body: some View {
        ZStack {
            // Tap-to-expand base layer — catches taps through elements with allowsHitTesting(false)
            // (artwork, marquee text, BPM bar) and fires when no button above consumes the event
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { WindowSnapManager.shared.expandCurrentWindow() }

            // Keep content in tree always so it can fade — only hide via opacity
            peekContent
                .opacity(state.snapState == .peeking ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: state.snapState)
                .allowsHitTesting(state.snapState == .peeking)

            // Drop zone indicator — shows while files are dragged over docked or peeking panel
            if isDropTarget && (state.snapState == .docked || state.snapState == .peeking) {
                peekDropOverlay
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(panelDragGesture)
        .background(panelBackground)
        .mask(panelMask)
        .allowsHitTesting(state.snapState == .docked || state.snapState == .peeking)
        .onDrop(of: [UTType.audio, UTType.fileURL], isTargeted: $isDropTarget, perform: onFileDrop)
    }

    private var peekContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 4) {
                artworkArea
                    .contentShape(Rectangle())
                    .onTapGesture { WindowSnapManager.shared.expandCurrentWindow() }

                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { WindowSnapManager.shared.expandCurrentWindow() }
                    MarqueeText(text: peekTitleLine, fontSize: 8.5, colorOpacity: 0.92)
                }
                .frame(height: 11)
                .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)

                HStack(spacing: 0) {
                    Button { state.selectPreviousTrack() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(prevHovered ? 0.09 : 0))
                                .frame(width: 12, height: 24)
                                .animation(.easeInOut(duration: 0.12), value: prevHovered)
                            Image(systemName: "backward.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(G.textSecondary)
                        }
                        .frame(width: 20, height: 22)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))
                    .onHover { prevHovered = $0 }

                    Button {
                        guard let t = state.current, !t.isMissing else { return }
                        state.togglePlayback()
                    } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(G.textOnLight)
                            .frame(width: 24, height: 24)
                            .background(G.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.88))

                    Button { state.selectNextTrack() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(nextHovered ? 0.09 : 0))
                                .frame(width: 12, height: 24)
                                .animation(.easeInOut(duration: 0.12), value: nextHovered)
                            Image(systemName: "forward.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(G.textSecondary)
                        }
                        .frame(width: 20, height: 22)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))
                    .onHover { nextHovered = $0 }
                }
                .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)

                if let bpm = currentBPM {
                    PeekBPMBar(label: bpm, progress: progressFeed.progress)
                        .frame(width: 54, height: 12)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { WindowSnapManager.shared.expandCurrentWindow() }
                        .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
                }
            }
            .frame(width: 78)
            .offset(x: -5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if state.snapState == .docked {
            RoundedRectangle(cornerRadius: 16)
                .fill(G.bgWindow)
                .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.vertical, peekingVerticalInset)
        } else {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .fill(G.bgWindow)
                .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
                .overlay(
                    RoundedRectangle(cornerRadius: G.rWindowInner)
                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: G.rWindowInner)
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                        .blur(radius: 0.2)
                )
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var panelMask: some View {
        if state.snapState == .docked {
            RoundedRectangle(cornerRadius: 16)
                .padding(.vertical, peekingVerticalInset)
        } else {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .padding(.vertical, 6)
        }
    }

    // Artwork — if present show it; otherwise pixel-grid spectrum
    @ViewBuilder
    private var artworkArea: some View {
        if state.current?.hasArtwork == true {
            ArtSwatchView(
                index: trackIndex,
                size: 40,
                cornerRadius: 7,
                hasArtwork: true,
                trackId: state.current?.id,
                showsBrandPlaceholder: false
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                PixelSpectrumView(isPlaying: state.isPlaying)
                    .padding(5)
            }
            .frame(width: 40, height: 40)
            .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
        }
    }

    // MARK: – Gesture: drag → reposition Y (tap-to-expand is handled by the base Color.clear layer)

    private var panelDragGesture: some Gesture {
        // Uses NSEvent.mouseLocation (screen-space) to avoid the SwiftUI .local coordinate space
        // feedback loop: when we move the window, the view moves with it, causing translation to
        // partially cancel the movement → stuttering "прыг-прыг" effect.
        // minimumDistance: 8 so that simple button taps don't trigger dragging.
        // simultaneousGesture on the ZStack means this fires even over peekContent's buttons.
        DragGesture(minimumDistance: 8)
            .onChanged { _ in
                guard let window = WindowSnapManager.shared.currentWindow else { return }
                if dragStartWindowOrigin == nil {
                    WindowSnapManager.shared.isDragging = true
                    WindowSnapManager.shared.cancelSlide()
                    dragStartWindowOrigin = window.frame.origin
                    dragStartMouseY = NSEvent.mouseLocation.y
                }
                let deltaY = NSEvent.mouseLocation.y - dragStartMouseY
                guard abs(deltaY) > 6,
                      let start = dragStartWindowOrigin,
                      let screen = window.screen ?? NSScreen.main else { return }
                hasDraggedBeyondThreshold = true
                let newY = start.y + deltaY
                let clamped = max(screen.frame.minY, min(screen.frame.maxY - window.frame.height, newY))
                window.setFrameOrigin(NSPoint(x: start.x, y: clamped))
            }
            .onEnded { _ in
                let moved = hasDraggedBeyondThreshold
                dragStartWindowOrigin = nil
                dragStartMouseY = 0
                hasDraggedBeyondThreshold = false
                WindowSnapManager.shared.isDragging = false
                if moved {
                    WindowSnapManager.shared.constrainCurrentWindow()
                }
            }
    }

    // MARK: – Helpers

    private var trackIndex: Int {
        state.tracks.firstIndex(where: { $0.id == state.currentId }) ?? 0
    }

    private var currentBPM: String? {
        guard let t = state.current, t.bpm > 0 else { return nil }
        let bpm = state.pitch == 0 ? t.bpm : t.bpm * (1 + state.pitch / 100)
        return "\(Int(bpm.rounded())) BPM"
    }

    private var peekTitleLine: String {
        guard let track = state.current else { return "—" }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return track.title }
        return "\(track.title) / \(artist)"
    }


    private var peekDropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.black.opacity(0.58))
            .overlay {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                    Text("DROP\nHERE")
                        .font(G.mono(7, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .tracking(0.35)
                }
            }
            .padding(8)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(8)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.12), value: isDropTarget)
    }
}

// MARK: – BPM progress bar

private struct PeekBPMBar: View {
    let label: String
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: G.rBadge)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: G.rBadge)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: max(0, geo.size.width * CGFloat(progress)))
                Text(label)
                    .font(G.mono(8, weight: .semibold))
                    .foregroundStyle(G.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: – Pixel-grid spectrum (for artwork placeholder) — mirrors main SpectrumView logic

private struct PixelSpectrumView: View {
    @ObservedObject private var feed = SpectrumFeed.shared
    let isPlaying: Bool

    private let cols = 8
    private let rows = 8
    private let gap: CGFloat = 1


    private let ceil: Float      = 0.40
    private let peakHold: Double = 0.40
    private let gravity: Float   = 4.5
    private let blendDuration: Float = 0.75
    private let specScale: Float = 0.4

    @State private var peaks:      [Float] = Array(repeating: 0, count: 8)
    @State private var peakAt:     [Date]  = Array(repeating: .distantPast, count: 8)
    @State private var blendFrom:  Float   = 0
    @State private var blendTarget: Float  = 0
    @State private var blendStart:  Date   = .distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in draw(ctx: ctx, size: size, now: tl.date) }
        }
        .onAppear {
            // Sync blend to current playing state on first appearance
            blendFrom   = isPlaying ? 1 : 0
            blendTarget = isPlaying ? 1 : 0
        }
        .onChange(of: isPlaying) { playing in
            blendFrom   = blend(at: Date())
            blendStart  = Date()
            blendTarget = playing ? 1 : 0
        }
        .onChange(of: feed.data) { newData in
            guard !newData.isEmpty else { return }
            let now = Date()
            for i in 0..<cols {
                let idx = min(i * (newData.count - 1) / max(cols - 1, 1), newData.count - 1)
                let v = newData[idx] * specScale
                let vSq = v * v
                if vSq > decayedPeak(i, now: now) { peaks[i] = vSq; peakAt[i] = now }
            }
        }
    }

    private func blend(at now: Date) -> Float {
        let elapsed = Float(now.timeIntervalSince(blendStart))
        let t = min(1, elapsed / blendDuration)
        let e = t * t * (3 - 2 * t)
        return blendFrom + (blendTarget - blendFrom) * e
    }

    private func decayedPeak(_ i: Int, now: Date) -> Float {
        let h = peaks[i]; guard h > 0 else { return 0 }
        let elapsed = Float(now.timeIntervalSince(peakAt[i]))
        guard elapsed > Float(peakHold) else { return h }
        return max(0, h - gravity * pow(elapsed - Float(peakHold), 2))
    }

    private func idleBars(now: Date) -> [Float] {
        let t = now.timeIntervalSinceReferenceDate
        return (0..<cols).map { i in
            let pos = Double(i) / Double(cols - 1)
            let pm1 = sin(t * 0.31 + pos * 1.70) * 1.40
            let pm2 = sin(t * 0.19 - pos * 2.30) * 1.10
            let a = (sin(t * 0.55 + pos * .pi * 2.8 + pm1)        + 1) * 0.5
            let b = (sin(t * 1.73 - pos * .pi * 1.6 + pm2)        + 1) * 0.5
            let c = (sin(t * 0.22 + pos * 0.80)                    + 1) * 0.5
            let d = (sin(t * 3.14 + pos * .pi * 5.2 + pm1 * 0.50) + 1) * 0.5
            let e = (sin(t * 0.97 + pos * .pi * 0.9 - pm2 * 0.30) + 1) * 0.5
            let f = (sin(t * 2.41 - pos * 3.10 + sin(t * 0.43 + pos) * 0.90) + 1) * 0.5
            return Float((a * 0.20 + b * 0.18 + c * 0.15 + d * 0.15 + e * 0.17 + f * 0.15) * 0.22)
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: Date) {
        let bl       = blend(at: now)
        let idle: [Float] = bl < 0.99 ? idleBars(now: now) : []
        let t        = now.timeIntervalSinceReferenceDate
        let colW     = (size.width  - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let rowH     = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let d        = feed.data

        for col in 0..<cols {
            let x    = CGFloat(col) * (colW + gap)
            let idx  = d.isEmpty ? 0 : min(col * max(d.count - 1, 1) / max(cols - 1, 1), d.count - 1)
            let vP: Float = (d.isEmpty ? 0 : d[idx]) * specScale
            let vD: Float = col < idle.count ? idle[col] : 0

            let ncAgc = CGFloat(min(1, max(0, vP / 0.10)))
            let ncFix = CGFloat(min(1, max(0, vD / 0.22)))
            let nc    = ncAgc * CGFloat(bl) + ncFix * CGFloat(1 - bl)
            let norm  = nc * nc
            let litRows = Int((norm * CGFloat(rows)).rounded(.up))

            var peakRow = -1
            if bl > 0.02 {
                let pvSq = decayedPeak(col, now: now)
                if pvSq > 0.001 {
                    let pvNc  = CGFloat(min(1, max(0, sqrt(pvSq) / 0.10)))
                    peakRow   = min(rows - 1, Int((pvNc * pvNc * CGFloat(rows)).rounded(.up)))
                }
            }

            let shimmer = max(0.0, sin(t * 2.6 + Double(col) * 0.55)) * Double(bl)

            for row in 0..<rows {
                let y      = size.height - CGFloat(row + 1) * rowH - CGFloat(row) * gap
                let isLit  = row < litRows
                let isTip  = isLit && row == litRows - 1
                let isPeak = row == peakRow && peakRow >= litRows

                let opacity: Double
                if isTip {
                    let twinkle = sin(t * 9.5 + Double(col) * 1.8) * 0.5 + 0.5
                    opacity = 0.58 + twinkle * 0.22
                } else if isLit {
                    let pos = litRows > 1 ? Double(row) / Double(litRows - 1) : 0
                    if pos > 0.85      { opacity = 0.50 + shimmer * 0.14 }
                    else if pos > 0.55 { opacity = 0.30 + shimmer * 0.08 }
                    else               { opacity = 0.16 + shimmer * 0.04 }
                } else if isPeak {
                    opacity = Double(bl) * 0.42
                } else {
                    opacity = 0.045
                }

                ctx.fill(
                    Path(CGRect(x: x, y: y, width: colW, height: rowH)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }
}

// MARK: – Marquee text

private struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 9
    var colorOpacity: Double = 1.0
    @State private var measured: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let containerW: CGFloat = 68
    private let speed: CGFloat = 28

    var body: some View {
        Text(text)
            .font(G.sans(fontSize))
            .foregroundStyle(G.textPrimary.opacity(colorOpacity))
            .lineLimit(1)
            .fixedSize()
            .offset(x: offset)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { measured = geo.size.width }
                        .task(id: text) { measured = geo.size.width }
                }
            )
            .frame(width: containerW, alignment: .leading)
            .clipped()
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: G.bgWindow, location: 0.0),
                        .init(color: .clear,     location: 0.15),
                        .init(color: .clear,     location: 0.85),
                        .init(color: G.bgWindow, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .allowsHitTesting(false)
            )
            .task(id: measured) {
                offset = 0
                // Guard against the initial measured=0 pass — would animate invisible air
                guard !text.isEmpty, measured > 4 else { return }
                let overflow = measured - containerW + 4
                if overflow > 0 {
                    // Long text: scroll overflow → instant reset → tiny pause → repeat
                    let duration = Double(overflow) / Double(speed)
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: duration)) { offset = -overflow }
                        try? await Task.sleep(for: .seconds(duration))
                        guard !Task.isCancelled else { break }
                        withAnimation(.none) { offset = 0 }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                } else {
                    // Short text fits in container: show briefly, scroll off edge (measured + small
                    // invisible gap), pause while blank, reset, repeat.
                    let exitDist    = measured + 12   // 12px past left edge — reset is invisible
                    let exitDuration = Double(exitDist) / Double(speed)
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(800))    // 0.8s readable window
                        guard !Task.isCancelled else { break }
                        withAnimation(.linear(duration: exitDuration)) { offset = -exitDist }
                        try? await Task.sleep(for: .seconds(exitDuration))
                        guard !Task.isCancelled else { break }
                        try? await Task.sleep(for: .milliseconds(300))    // 0.3s blank gap
                        guard !Task.isCancelled else { break }
                        withAnimation(.none) { offset = 0 }
                    }
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: – Spring press button style

private struct PeekSpringButton: ButtonStyle {
    var scale: CGFloat = 0.82

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
