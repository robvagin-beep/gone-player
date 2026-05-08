import SwiftUI
import AppKit

struct PeekPanelView: View {
    @EnvironmentObject var state: PlayerState
    @State private var dragStartWindowOrigin: NSPoint?
    private let peekingVerticalInset: CGFloat = 6

    private var panelWidth: CGFloat {
        state.snapState == .docked ? 84 : 96
    }

    var body: some View {
        ZStack {
            // Keep content in tree always so it can fade — only hide via opacity
            peekContent
                .opacity(state.snapState == .peeking ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: state.snapState)
                .allowsHitTesting(state.snapState == .peeking)
        }
        .frame(width: panelWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(panelGesture)
        .background(panelBackground)
        .mask(panelMask)
        .allowsHitTesting(state.snapState == .docked || state.snapState == .peeking)
    }

    private var peekContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(maxHeight: 8)

            VStack(spacing: 0) {
                artworkArea
                    .allowsHitTesting(false)

                Spacer().frame(height: 6)

                MarqueeText(text: peekTitleLine, fontSize: 8.5, colorOpacity: 0.92)

                Spacer().frame(height: 7)

                HStack(spacing: 0) {
                    Button { state.selectPreviousTrack() } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(G.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))

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
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.88))

                    Button { state.selectNextTrack() } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(G.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))
                }

                Spacer().frame(height: 8)

                if let bpm = currentBPM {
                    PeekBPMBar(label: bpm, progress: state.progress)
                        .frame(width: 54, height: 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 78)
            .offset(x: -5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if state.snapState == .docked {
            RoundedRectangle(cornerRadius: 16)
                .fill(G.bgWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.vertical, peekingVerticalInset)
        } else {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .fill(G.bgWindow)
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
        if let data = state.current?.artworkData, !data.isEmpty {
            ArtSwatchView(
                index: trackIndex,
                size: 40,
                cornerRadius: 7,
                artworkData: data,
                trackId: state.current?.id,
                showsBrandPlaceholder: false
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                PixelSpectrumView(data: spectrumSlice, isPlaying: state.isPlaying)
                    .padding(5)
            }
            .frame(width: 40, height: 40)
        }
    }

    // MARK: – Gesture: tap → expand, drag → reposition Y

    private var panelGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let window = WindowSnapManager.shared.currentWindow else { return }
                // Capture start + pause proximity on first touch, before the 6px threshold,
                // so the proximity timer can't kick off a competing slide animation.
                if dragStartWindowOrigin == nil {
                    WindowSnapManager.shared.isDragging = true
                    WindowSnapManager.shared.cancelSlide()
                    dragStartWindowOrigin = window.frame.origin
                }
                guard abs(value.translation.height) > 6,
                      let start = dragStartWindowOrigin,
                      let screen = window.screen ?? NSScreen.main else { return }
                let newY = start.y - value.translation.height
                let clamped = max(screen.frame.minY, min(screen.frame.maxY - window.frame.height, newY))
                window.setFrameOrigin(NSPoint(x: start.x, y: clamped))
            }
            .onEnded { value in
                let moved = abs(value.translation.height) > 6
                dragStartWindowOrigin = nil
                WindowSnapManager.shared.isDragging = false
                if moved {
                    WindowSnapManager.shared.constrainCurrentWindow()
                } else {
                    WindowSnapManager.shared.expandCurrentWindow()
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

    private var spectrumSlice: [Float] { state.spectrumData }
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
    let data: [Float]
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
    @State private var colPeak:    [Float] = Array(repeating: 0.08, count: 8)
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
        .onChange(of: isPlaying) { _, playing in
            blendFrom   = blend(at: Date())
            blendStart  = Date()
            blendTarget = playing ? 1 : 0
        }
        .onChange(of: data) { _, newData in
            guard !newData.isEmpty else { return }
            let now = Date()
            for i in 0..<cols {
                let idx = min(i * (newData.count - 1) / max(cols - 1, 1), newData.count - 1)
                let v = newData[idx] * specScale
                if v > decayedPeak(i, now: now) { peaks[i] = v; peakAt[i] = now }
                if v > colPeak[i] {
                    colPeak[i] = colPeak[i] * 0.10 + v * 0.90
                } else {
                    colPeak[i] = max(0.08, colPeak[i] * 0.997)
                }
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
        let idle     = idleBars(now: now)
        let t        = now.timeIntervalSinceReferenceDate
        let colW     = (size.width  - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let rowH     = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        for col in 0..<cols {
            let x    = CGFloat(col) * (colW + gap)
            let idx  = data.isEmpty ? 0 : min(col * max(data.count - 1, 1) / max(cols - 1, 1), data.count - 1)
            let vP: Float = (data.isEmpty ? 0 : data[idx]) * specScale
            let vD: Float = col < idle.count ? idle[col] : 0

            let peak  = col < colPeak.count ? colPeak[col] : 0.08
            let gate: Float  = peak * 0.82
            let ncAgc = CGFloat(min(1, max(0, (vP - gate) / max(0.004, peak - gate))))
            let ncFix = CGFloat(min(1, max(0, vD / 0.22)))
            let nc    = ncAgc * CGFloat(bl) + ncFix * CGFloat(1 - bl)
            let norm  = nc * nc * nc
            let litRows = Int((norm * CGFloat(rows)).rounded(.up))

            var peakRow = -1
            if bl > 0.02 {
                let pv = decayedPeak(col, now: now)
                if pv > 0.056 {
                    let pvNc  = CGFloat(min(1, max(0, (pv - gate) / max(0.004, peak - gate))))
                    peakRow   = min(rows - 1, Int((pvNc * pvNc * pvNc * CGFloat(rows)).rounded(.up)))
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
                guard !text.isEmpty else { return }
                let overflow = measured - containerW + 4
                if overflow > 0 {
                    let duration = Double(overflow) / Double(speed)
                    while !Task.isCancelled {
                        withAnimation(.linear(duration: duration)) { offset = -overflow }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        guard !Task.isCancelled else { break }
                        withAnimation(.none) { offset = 0 }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                } else {
                    // Short text: pause while visible → scroll fully off + gap → reset → repeat
                    let gap: CGFloat = 50
                    let scrollDist = measured + gap
                    let duration = Double(scrollDist) / Double(speed)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { break }
                        withAnimation(.linear(duration: duration)) { offset = -scrollDist }
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
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
