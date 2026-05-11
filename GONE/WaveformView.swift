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

private final class BarTracker {
    var playedAt: [Int: Date] = [:]
}

private final class GridTransitionState {
    var lockedInAt: Date?
    var lastConfidence: Double = 0
}

struct ProgressRuler: View {
    let progress: Double
    let waveform: [Float]
    var bpm: Double = 0
    var duration: Double = 0
    var beatGridOffset: Double = 0
    var beatGridConfidence: Double = 0
    var meterBeatsPerBar: Int = 4
    var hotCues: [Double?] = []
    var isPlaying: Bool = true
    let onSeek: (Double) -> Void

    @State private var dragRatio: Double?
    @State private var tracker = BarTracker()
    @State private var gridTransition = GridTransitionState()
    @State private var lastKnownProgress: Double = -1
    @State private var waveMinCache: CGFloat = 0
    @State private var waveRangeCache: CGFloat = 1

    private static let animDuration: Double = 0.38
    private static let gridTransitionDuration: Double = 0.25
    private static let confidenceThreshold: Double = 0.60

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
        .onChange(of: beatGridConfidence) { newConfidence in
            let wasAnalyzed = gridTransition.lastConfidence >= Self.confidenceThreshold
            let nowAnalyzed = newConfidence >= Self.confidenceThreshold
            if nowAnalyzed && !wasAnalyzed {
                gridTransition.lockedInAt = Date()
            } else if !nowAnalyzed {
                gridTransition.lockedInAt = nil
            }
            gridTransition.lastConfidence = newConfidence
        }
        .onChange(of: progress) { newProgress in
            let last = lastKnownProgress < 0 ? 0.0 : lastKnownProgress
            defer { lastKnownProgress = newProgress }
            if abs(newProgress - last) > 0.05 {
                tracker.playedAt.removeAll()
                return
            }
            let now = Date()
            for i in 0..<121 {
                let barFrac = Double(i) / 120.0
                if barFrac <= newProgress && barFrac > last {
                    tracker.playedAt[i] = now
                } else if barFrac > newProgress && barFrac <= last {
                    tracker.playedAt.removeValue(forKey: i)
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
        let totalTicks = 121
        let playheadX  = size.width * CGFloat(displayProgress)
        let isDragging = dragRatio != nil

        let majorH:    CGFloat = 16
        let maxWaveH:  CGFloat = 11
        let minWaveH:  CGFloat = 3
        let maxGhostH: CGFloat = 8
        let minGhostH: CGFloat = 2
        let baseline:  CGFloat = size.height

        // Suppress arbitrary fixed dividers when beat grid provides real structure.
        let majorSet: Set<Int> = hasBeatGrid ? [] : [0, 30, 60, 90, 120]

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        let expiryCutoff = now.addingTimeInterval(-Self.animDuration)
        tracker.playedAt = tracker.playedAt.filter { $0.value > expiryCutoff }

        for i in 0..<totalTicks {
            let frac    = CGFloat(i) / CGFloat(totalTicks - 1)
            let x       = frac * size.width
            let played  = x <= playheadX
            let isMajor = majorSet.contains(i)

            let animT: CGFloat
            if isDragging {
                animT = played ? 1 : 0
            } else if !played {
                animT = 0
            } else if let playedAt = tracker.playedAt[i] {
                let elapsed = now.timeIntervalSince(playedAt)
                let t = min(1.0, elapsed / Self.animDuration)
                animT = CGFloat(1.0 - pow(1.0 - t, 2.5))
            } else {
                animT = 1
            }

            let tickH: CGFloat
            let alpha: Double

            if isMajor {
                tickH = majorH
                alpha = played ? (0.18 + 0.82 * Double(animT)) : 0.18
            } else if !waveform.isEmpty {
                let pos  = frac * CGFloat(waveform.count - 1)
                let ci0  = max(0, min(waveform.count - 1, Int(pos)))
                let ci1  = min(waveform.count - 1, ci0 + 1)
                let t    = pos - CGFloat(ci0)
                let v    = CGFloat(waveform[ci0]) * (1 - t) + CGFloat(waveform[ci1]) * t
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

        // Beat grid: drawn after waveform (on top), before hot cues.
        if hasBeatGrid { drawBeatGrid(ctx: ctx, size: size, now: now) }

        // Hot cues — topmost layer.
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
                       style: StrokeStyle(lineWidth: 2.0, lineCap: .butt))
        }
    }

    // Draws musical bar markers that form a ruler-like structure over the waveform.
    //
    // Heights are scaled to the ruler (22px typ.) and EXCEED the waveform bars so
    // musical structure is always readable above the audio texture:
    //   beat ticks  → 38% ruler height (~8px): subtle quarter-note hints
    //   bar markers → 75% ruler height (~16px): clearly above waveform
    //   4-bar marks → 100% ruler height (22px): full-height landmarks
    //
    // Adaptive stride (Rekordbox overview behavior):
    //   always show SOMETHING when BPM is known — find the bar subdivision
    //   that keeps markers ≥ 4px apart and show that level.
    //   pxPerBar ≥ 4 → every bar    (1-bar stride)
    //   pxPer4Bar ≥ 4 → every 4 bars (4-bar stride)
    //   pxPer8Bar ≥ 4 → every 8 bars (8-bar stride)
    //   else → every 16 bars
    //
    // Two-layer animation: fallback (offset=0) fades, analyzed (offset=detected) grows.
    // Performance: 3 batched Path structs × 2 layers = 6 ctx.stroke calls max.
    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize, now: Date) {
        let beatDuration = 60.0 / bpm
        guard beatDuration.isFinite, beatDuration > 0 else { return }

        let h = size.height
        let beatH:    CGFloat = (h * 0.38).rounded()   // ~8px
        let barH:     CGFloat = (h * 0.75).rounded()   // ~16px, exceeds waveform
        let fourBarH: CGFloat = h                       // full height — ruler landmark

        let pxPerBeat    = size.width * CGFloat(beatDuration / duration)
        let pxPerBar     = pxPerBeat * CGFloat(meterBeatsPerBar)
        let pxPerFourBar = pxPerBar * 4.0
        let minPx: CGFloat = 4.0

        // Adaptive stride: always draw at least the tier that stays readable.
        let barStride: Int
        if      pxPerBar     >= minPx { barStride = 1  }
        else if pxPerFourBar >= minPx { barStride = 4  }
        else if pxPerFourBar * 2 >= minPx { barStride = 8  }
        else                          { barStride = 16 }

        // Individual beats only when they're actually readable.
        let showBeats = pxPerBeat >= minPx

        // Transition progress: 0 = fallback, 1 = analyzed fully locked in.
        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold
        let transitionT: CGFloat
        if isAnalyzed, let arrivedAt = gridTransition.lockedInAt {
            let elapsed = now.timeIntervalSince(arrivedAt)
            transitionT = CGFloat(min(1.0, elapsed / Self.gridTransitionDuration))
        } else {
            transitionT = 0
        }

        // Layer A: fallback (offset=0) — provisional, more muted, fades as analysis arrives.
        let layerAMult = 1.0 - Double(transitionT)
        if layerAMult > 0.01 {
            drawGridLayer(ctx: ctx, size: size, offset: 0,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha:    0.20 * layerAMult,
                barAlpha:     0.42 * layerAMult,
                fourBarAlpha: 0,              // fallback shows no 4-bar emphasis
                showBeats: showBeats, barStride: barStride, showFourBar: false)
        }

        // Layer B: analyzed (offset=beatGridOffset) — grows in with full visual hierarchy.
        if isAnalyzed && transitionT > 0.01 {
            let layerBMult = Double(transitionT)
            drawGridLayer(ctx: ctx, size: size, offset: beatGridOffset,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha:    0.28 * layerBMult,
                barAlpha:     0.55 * layerBMult,
                fourBarAlpha: 0.80 * layerBMult,
                showBeats: showBeats, barStride: barStride, showFourBar: true)
        }
    }

    // Renders one grid layer. Caller controls alpha envelope.
    // barStride controls which bars are drawn; showFourBar enables the full-height tier.
    // 3 batched Path structs: O(1) draw calls regardless of beat count.
    private func drawGridLayer(
        ctx: GraphicsContext, size: CGSize, offset: Double,
        beatH: CGFloat, barH: CGFloat, fourBarH: CGFloat,
        beatAlpha: Double, barAlpha: Double, fourBarAlpha: Double,
        showBeats: Bool, barStride: Int, showFourBar: Bool
    ) {
        let beatDuration = 60.0 / bpm
        let baseline     = size.height

        let firstBeat = max(0, Int(floor(-offset / beatDuration)))
        let lastBeat  = Int(ceil((duration - offset) / beatDuration))
        guard lastBeat >= firstBeat else { return }

        var beatPath    = Path()
        var barPath     = Path()
        var fourBarPath = Path()

        for beatIndex in firstBeat...lastBeat {
            let beatTime = offset + Double(beatIndex) * beatDuration
            guard beatTime >= 0, beatTime <= duration else { continue }

            let x     = CGFloat(beatTime / duration) * size.width
            let isBar = beatIndex % meterBeatsPerBar == 0

            if isBar {
                let barIdx = beatIndex / meterBeatsPerBar
                guard barIdx % barStride == 0 else { continue }

                // 4-bar landmarks only get special treatment in 1-bar stride mode
                // (when stride > 1, every shown marker IS already a sparse landmark).
                let isFourBarLandmark = barIdx % 4 == 0
                if isFourBarLandmark && showFourBar {
                    fourBarPath.move(to:    CGPoint(x: x, y: baseline))
                    fourBarPath.addLine(to: CGPoint(x: x, y: baseline - fourBarH))
                } else {
                    barPath.move(to:    CGPoint(x: x, y: baseline))
                    barPath.addLine(to: CGPoint(x: x, y: baseline - barH))
                }
            } else if showBeats {
                beatPath.move(to:    CGPoint(x: x, y: baseline))
                beatPath.addLine(to: CGPoint(x: x, y: baseline - beatH))
            }
        }

        if showBeats && beatAlpha > 0 {
            ctx.stroke(beatPath, with: .color(.white.opacity(beatAlpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }
        if barAlpha > 0 {
            ctx.stroke(barPath, with: .color(.white.opacity(barAlpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }
        if showFourBar && fourBarAlpha > 0 {
            ctx.stroke(fourBarPath, with: .color(.white.opacity(fourBarAlpha)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
        }
    }
}
