import SwiftUI

struct ProgressRulerRow: View {
    @EnvironmentObject var state: PlayerState
    @State private var feedProgress: Double = 0

    var body: some View {
        ProgressRuler(
            progress: feedProgress,
            waveform: state.current?.waveform ?? [],
            bpm: state.current?.bpm ?? 0,
            duration: state.current?.duration ?? 0,
            beatGridOffset: state.current?.beatGridOffset ?? 0,
            beatGridConfidence: state.current?.beatGridConfidence ?? 0,
            isAnalyzingBeatGrid: state.current?.bpmAnalysisState == .analyzing,
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

// Class-based storage for divider animation timestamps.
// Mutations don't trigger SwiftUI invalidation — Canvas re-runs at 30fps.
private final class BarTracker {
    var playedAt: [Int: Date] = [:]
}

// Ruler tick hierarchy — determines height (tallest → shortest).
private enum MusicalTickType: Int {
    case beat    = 1  // 5px — "millimeter" texture
    case bar     = 2  // subDivH — bar downbeats
    case fourBar = 3  // quarterH — 4-bar navigation anchors
}

struct ProgressRuler: View {
    let progress: Double
    let waveform: [Float]
    var bpm: Double = 0
    var duration: Double = 0
    var beatGridOffset: Double = 0
    var beatGridConfidence: Double = 0
    var isAnalyzingBeatGrid: Bool = false
    var meterBeatsPerBar: Int = 4
    var hotCues: [Double?] = []
    var isPlaying: Bool = true
    let onSeek: (Double) -> Void

    @State private var dragRatio: Double?
    @State private var tracker = BarTracker()
    @State private var lastKnownProgress: Double = -1
    @State private var waveMinCache: CGFloat = 0
    @State private var waveRangeCache: CGFloat = 1

    private static let animDuration: Double = 0.38
    private static let confidenceThreshold: Double = 0.60

    // 161 ticks — ~2.5px/tick at 400px width.
    private static let totalTicks: Int = 161

    // Pre-analysis fallback: fixed marks at 0 / 25 / 50 / 75 / 100%.
    private static let defaultStructuralTicks: Set<Int> = [0, 40, 80, 120, 160]

    private var displayProgress: Double { dragRatio ?? progress }
    private var hasBeatGrid: Bool { bpm > 0 && duration > 0 && meterBeatsPerBar > 0 }

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
            if abs(newProgress - last) > 0.05 { tracker.playedAt.removeAll(); return }
            let now = Date()
            let n = Self.totalTicks
            for i in 0..<n {
                let barFrac = Double(i) / Double(n - 1)
                if barFrac <= newProgress && barFrac > last      { tracker.playedAt[i] = now }
                else if barFrac > newProgress && barFrac <= last  { tracker.playedAt.removeValue(forKey: i) }
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

    // Drawing layers (bottom → top):
    //   1. Waveform silhouette — filled grey shape, flat bottom, amplitude top
    //   2. Beat micro-ticks (5px) — "millimeter marks", visible when beats fit
    //   3. Bar ticks (subDivH) — bar downbeats, same visual style as structural
    //   4. 4-bar / structural ticks (quarterH) — tallest, navigation anchors
    //   5. Hot cue markers
    //
    // Before analysis: 5 fixed structural marks at 0/25/50/75/100%.
    // After analysis:  full musical grid — start/end adapt to first/last bar.
    private func drawRuler(ctx: GraphicsContext, size: CGSize, now: Date) {
        let totalTicks = Self.totalTicks
        let playheadX  = size.width * CGFloat(displayProgress)
        let isDragging = dragRatio != nil
        let h          = size.height
        let baseline   = h

        // Height levels (tallest → shortest):
        let quarterH: CGFloat = (h * 0.73).rounded()             // ~16px — 4-bar anchors
        let subDivH:  CGFloat = (quarterH * 0.75).rounded() - 1  // ~11px — bar (2px shorter than before)
        let tinyH:    CGFloat = 5                                 // 5px  — beat micro-ticks
        let maxWaveH: CGFloat = subDivH - 1                      // ~10px — silhouette ceiling

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        let expiryCutoff = now.addingTimeInterval(-Self.animDuration)
        tracker.playedAt = tracker.playedAt.filter { $0.value > expiryCutoff }

        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold

        // ── 1. Waveform silhouette ───────────────────────────────────────────────
        if !waveform.isEmpty {
            func silhouette(toX limitX: CGFloat) -> Path {
                let endPx = Int(min(limitX, size.width).rounded())
                guard endPx > 0 else { return Path() }
                var p = Path()
                p.move(to: CGPoint(x: 0, y: baseline))
                for px in 0...endPx {
                    let frac = CGFloat(px) / size.width
                    let pos  = frac * CGFloat(waveform.count - 1)
                    let ci0  = max(0, min(waveform.count - 1, Int(pos)))
                    let ci1  = min(waveform.count - 1, ci0 + 1)
                    let lerp = pos - CGFloat(ci0)
                    let v    = CGFloat(waveform[ci0]) * (1 - lerp) + CGFloat(waveform[ci1]) * lerp
                    let norm = max(0, (v - waveMin) / waveRange)
                    let amp  = pow(norm, 2.8) * maxWaveH
                    p.addLine(to: CGPoint(x: CGFloat(px), y: baseline - amp))
                }
                p.addLine(to: CGPoint(x: CGFloat(endPx), y: baseline))
                p.closeSubpath()
                return p
            }

            ctx.fill(silhouette(toX: size.width), with: .color(.white.opacity(0.09)))
            if playheadX > 0 {
                ctx.fill(silhouette(toX: playheadX), with: .color(.white.opacity(0.24)))
            }
        }

        // ── 2. Compute tick positions ────────────────────────────────────────────
        var musicalTicks: [Int: MusicalTickType] = [:]
        let structuralTicks: Set<Int>

        if hasBeatGrid && isAnalyzed {
            // Full musical grid — no separate structural set.
            // Start and end are determined by first/last bar positions.
            structuralTicks = []

            let beatDur      = 60.0 / bpm
            let pxPerBeat    = size.width * CGFloat(beatDur / duration)
            let pxPerBar     = pxPerBeat * CGFloat(meterBeatsPerBar)
            let pxPerFourBar = pxPerBar * 4.0
            let minPx: CGFloat = 20.0

            // Bar stride: pick the coarsest level that keeps marks >= minPx apart.
            let barStride: Int
            if      pxPerBar         >= minPx { barStride = 1  }
            else if pxPerFourBar     >= minPx { barStride = 4  }
            else if pxPerFourBar * 2 >= minPx { barStride = 8  }
            else if pxPerFourBar * 4 >= minPx { barStride = 16 }
            else if pxPerFourBar * 8 >= minPx { barStride = 32 }
            else                               { barStride = 64 }

            // Beat micro-ticks: show when there's enough room for distinct marks.
            let showBeats = pxPerBeat >= 2.5

            var beatI = 0
            var t     = beatGridOffset
            if t < 0 {
                let skip = Int(ceil(-t / beatDur))
                t     += Double(skip) * beatDur
                beatI += skip
            }

            while t <= duration + beatDur * 0.5 {
                defer { t += beatDur; beatI += 1 }
                guard t >= 0, t <= duration else { continue }

                let barI      = beatI / meterBeatsPerBar
                let beatInBar = beatI % meterBeatsPerBar
                let mapped    = Int((t / duration * Double(totalTicks - 1)).rounded())
                guard mapped >= 0, mapped < totalTicks else { continue }

                if beatInBar == 0 && barI % barStride == 0 {
                    // 4-bar landmark or bar downbeat — highest type wins.
                    let type: MusicalTickType = (barI % 4 == 0) ? .fourBar : .bar
                    if let existing = musicalTicks[mapped] {
                        if type.rawValue > existing.rawValue { musicalTicks[mapped] = type }
                    } else {
                        musicalTicks[mapped] = type
                    }
                } else if beatInBar != 0 && showBeats {
                    if musicalTicks[mapped] == nil { musicalTicks[mapped] = .beat }
                }
            }

        } else {
            // Pre-analysis: five fixed structural marks at exact quarter positions.
            structuralTicks = Self.defaultStructuralTicks
        }

        // ── 3. Render tick lines ─────────────────────────────────────────────────
        for i in 0..<totalTicks {
            let isMajor = structuralTicks.contains(i)
            let musical = musicalTicks[i]
            guard isMajor || musical != nil else { continue }

            let frac   = CGFloat(i) / CGFloat(totalTicks - 1)
            let x      = (frac * size.width * 2).rounded() / 2
            let played = x <= playheadX

            let animT: CGFloat
            if isDragging {
                animT = played ? 1 : 0
            } else if !played {
                animT = 0
            } else if let playedAt = tracker.playedAt[i] {
                let elapsed = now.timeIntervalSince(playedAt)
                animT = CGFloat(min(1.0, 1.0 - pow(1.0 - min(1.0, elapsed / Self.animDuration), 2.5)))
            } else {
                animT = 1
            }

            let tickH: CGFloat
            let alpha: Double

            if isMajor {
                // Pre-analysis structural mark.
                tickH = quarterH
                alpha = 0.35 + 0.65 * Double(animT)
            } else {
                switch musical! {
                case .fourBar:
                    // 4-bar navigation anchor — tallest.
                    tickH = quarterH
                    alpha = 0.35 + 0.65 * Double(animT)
                case .bar:
                    // Bar downbeat — same visual style, 2px shorter.
                    tickH = subDivH
                    alpha = 0.35 + 0.65 * Double(animT)
                case .beat:
                    // Micro-tick — ruler "millimeter" mark, very subtle.
                    tickH = tinyH
                    alpha = 0.12 + 0.28 * Double(animT)
                }
            }

            var path = Path()
            path.move(to:    CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }

        // ── 4. Hot cue markers — topmost ─────────────────────────────────────────
        let cueColors: [Color] = [
            Color(red: 1.0, green: 0.35, blue: 0.35),
            Color(red: 0.35, green: 0.70, blue: 1.0),
            Color(red: 1.0, green: 0.82, blue: 0.25),
            Color(red: 0.35, green: 0.90, blue: 0.55),
        ]
        for (idx, cue) in hotCues.prefix(4).enumerated() {
            guard let ratio = cue else { continue }
            let cx = CGFloat(ratio) * size.width
            var cuePath = Path()
            cuePath.move(to:    CGPoint(x: cx, y: 0))
            cuePath.addLine(to: CGPoint(x: cx, y: 5))
            ctx.stroke(cuePath, with: .color(cueColors[idx]),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }
    }
}
