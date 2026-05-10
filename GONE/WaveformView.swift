import SwiftUI

struct ProgressRulerRow: View {
    @EnvironmentObject var state: PlayerState
    @State private var feedProgress: Double = 0

    var body: some View {
        ProgressRuler(
            progress: feedProgress,
            waveform: state.current?.waveform ?? [],
            hotCues: state.hotCues,
            isPlaying: state.isPlaying,
            onSeek: { ratio in
                feedProgress = ratio
                state.audioEngine.seek(ratio: ratio)
            }
        )
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .padding(.bottom, 4)
        .onReceive(state.progressFeed.$progress) { feedProgress = $0 }
    }
}

struct ProgressRuler: View {
    let progress: Double
    let waveform: [Float]
    var hotCues: [Double?] = []
    var isPlaying: Bool = true
    let onSeek: (Double) -> Void

    @State private var dragRatio: Double?
    @State private var barPlayedAt: [Int: Date] = [:]
    @State private var lastKnownProgress: Double = -1
    @State private var waveMinCache: CGFloat = 0
    @State private var waveRangeCache: CGFloat = 1

    private static let animDuration: Double = 0.38

    private var displayProgress: Double { dragRatio ?? progress }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: (isPlaying || dragRatio != nil) ? 1.0 / 30.0 : 1.0 / 10.0)) { tl in
                Canvas { ctx, size in
                    drawRuler(ctx: ctx, size: size, now: tl.date)
                }
                .allowsHitTesting(false)
            }

            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            dragRatio = max(0, min(1, val.location.x / geo.size.width))
                        }
                        .onEnded { val in
                            let ratio = dragRatio ?? max(0, min(1, val.location.x / geo.size.width))
                            onSeek(ratio)
                            dragRatio = nil
                        }
                )
                .cursor(.pointingHand)
        }
        .onAppear { updateWaveCache() }
        .onChange(of: waveform) { _ in updateWaveCache() }
        .onChange(of: progress) { newProgress in
            let last = lastKnownProgress < 0 ? 0.0 : lastKnownProgress
            defer { lastKnownProgress = newProgress }
            if abs(newProgress - last) > 0.05 {
                barPlayedAt.removeAll()
                return
            }
            let now = Date()
            for i in 0..<121 {
                let barFrac = Double(i) / 120.0
                if barFrac <= newProgress && barFrac > last {
                    barPlayedAt[i] = now
                } else if barFrac > newProgress && barFrac <= last {
                    barPlayedAt.removeValue(forKey: i)
                }
            }
        }
    }

    private func updateWaveCache() {
        guard !waveform.isEmpty else { waveMinCache = 0; waveRangeCache = 1; return }
        let lo = CGFloat(waveform.min()!)
        let hi = CGFloat(waveform.max()!)
        waveMinCache   = lo
        waveRangeCache = max(hi - lo, 0.02)
    }

    private func drawRuler(ctx: GraphicsContext, size: CGSize, now: Date) {
        // 121 = 4×30+1 → quarters land exactly at indices 0,30,60,90,120
        let totalTicks = 121
        let playheadX  = size.width * CGFloat(displayProgress)
        let isDragging = dragRatio != nil

        let majorH:    CGFloat = 16   // quarter-mark dividers — stand above played bars
        let maxWaveH:  CGFloat = 11   // played peak (below majorH so dividers are visible)
        let minWaveH:  CGFloat = 3    // played trough
        let maxGhostH: CGFloat = 8    // unplayed peak
        let minGhostH: CGFloat = 2    // unplayed trough
        let baseline:  CGFloat = size.height

        let majorSet: Set<Int> = [0, 30, 60, 90, 120]

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        for i in 0..<totalTicks {
            let frac    = CGFloat(i) / CGFloat(totalTicks - 1)
            let x       = frac * size.width
            let played  = x <= playheadX
            let isMajor = majorSet.contains(i)

            // animT: 0 = ghost state, 1 = fully played
            // During drag: instant binary; during playback: ease-out over animDuration
            let animT: CGFloat
            if isDragging {
                animT = played ? 1 : 0
            } else if !played {
                animT = 0
            } else if let playedAt = barPlayedAt[i] {
                let elapsed = now.timeIntervalSince(playedAt)
                let t = min(1.0, elapsed / Self.animDuration)
                animT = CGFloat(1.0 - pow(1.0 - t, 2.5))  // ease-out
            } else {
                animT = 1  // played long before tracking started
            }

            let tickH: CGFloat
            let alpha: Double

            if isMajor {
                // Dividers: fixed height, animate opacity 0.18 → 1.0 when played
                tickH = majorH
                alpha = played ? (0.18 + 0.82 * Double(animT)) : 0.18
            } else if !waveform.isEmpty {
                let pos = frac * CGFloat(waveform.count - 1)
                let ci0 = max(0, min(waveform.count - 1, Int(pos)))
                let ci1 = min(waveform.count - 1, ci0 + 1)
                let t   = pos - CGFloat(ci0)
                let v   = CGFloat(waveform[ci0]) * (1 - t) + CGFloat(waveform[ci1]) * t
                let norm = max(0, (v - waveMin) / waveRange)
                let ghostH = minGhostH + norm * (maxGhostH - minGhostH)
                let fullH  = minWaveH  + norm * (maxWaveH  - minWaveH)
                tickH = ghostH + (fullH - ghostH) * animT
                alpha = 0.22 + 0.63 * Double(animT)
            } else {
                tickH = 2 + 2 * animT
                alpha = 0.18 + 0.37 * Double(animT)
            }

            var path = Path()
            path.move(to:    CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }

        // Hot cue markers — small colored ticks at the top of the ruler
        let cueColors: [Color] = [
            Color(red: 1.0, green: 0.35, blue: 0.35),   // 1 · red
            Color(red: 0.35, green: 0.70, blue: 1.0),   // 2 · blue
            Color(red: 1.0, green: 0.82, blue: 0.25),   // 3 · yellow
            Color(red: 0.35, green: 0.90, blue: 0.55),  // 4 · green
        ]
        for (idx, cue) in hotCues.prefix(4).enumerated() {
            guard let ratio = cue else { continue }
            let cx = CGFloat(ratio) * size.width
            var cuePath = Path()
            cuePath.move(to:    CGPoint(x: cx, y: 0))
            cuePath.addLine(to: CGPoint(x: cx, y: 5))
            ctx.stroke(cuePath, with: .color(cueColors[idx]),
                       style: StrokeStyle(lineWidth: 2.0, lineCap: .butt))
        }
    }
}
