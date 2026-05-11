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

// Class-based storage for bar animation timestamps.
// Mutations don't trigger SwiftUI invalidation — Canvas re-runs at 30fps.
private final class BarTracker {
    var playedAt: [Int: Date] = [:]
}

// Tracks the moment a confident analyzed grid arrives for lock-in animation.
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
    var isAnalyzingBeatGrid: Bool = false
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

    // Fixed visual quarter positions (25% / 50% / 75%) in the 121-tick grid.
    // These are track-section dividers — always visible, part of GONE's visual identity.
    // Tick indices: 0=0%, 30=25%, 60=50%, 90=75%, 120=100%.
    private static let fixedDividerTicks: Set<Int> = [0, 30, 60, 90, 120]

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
        .onChange(of: beatGridConfidence) { newConf in
            let wasAnalyzed = gridTransition.lastConfidence >= Self.confidenceThreshold
            let nowAnalyzed = newConf >= Self.confidenceThreshold
            if nowAnalyzed && !wasAnalyzed { gridTransition.lockedInAt = Date() }
            else if !nowAnalyzed           { gridTransition.lockedInAt = nil }
            gridTransition.lastConfidence = newConf
        }
        .onChange(of: progress) { newProgress in
            let last = lastKnownProgress < 0 ? 0.0 : lastKnownProgress
            defer { lastKnownProgress = newProgress }
            if abs(newProgress - last) > 0.05 { tracker.playedAt.removeAll(); return }
            let now = Date()
            for i in 0..<121 {
                let barFrac = Double(i) / 120.0
                if barFrac <= newProgress && barFrac > last     { tracker.playedAt[i] = now }
                else if barFrac > newProgress && barFrac <= last { tracker.playedAt.removeValue(forKey: i) }
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

        // Heights (ruler is 22px, baseline = bottom).
        // Fixed dividers: 16px — always visible above waveform.
        // Waveform bars: up to 11px played, 8px unplayed.
        let majorH:    CGFloat = 16
        let maxWaveH:  CGFloat = 11
        let minWaveH:  CGFloat = 3
        let maxGhostH: CGFloat = 8
        let minGhostH: CGFloat = 2
        let baseline:  CGFloat = size.height

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        // Fixed quarter divider base alpha.
        // While BPM analysis runs: subtle breathing to signal "working".
        // After analysis: stable at 0.45.
        let breathe   = isAnalyzingBeatGrid
            ? 0.50 + 0.18 * CGFloat(sin(now.timeIntervalSinceReferenceDate * 2.0))
            : 0.45

        // Prune expired bar-play animations.
        let expiryCutoff = now.addingTimeInterval(-Self.animDuration)
        tracker.playedAt = tracker.playedAt.filter { $0.value > expiryCutoff }

        for i in 0..<totalTicks {
            let frac    = CGFloat(i) / CGFloat(totalTicks - 1)
            let x       = frac * size.width
            let played  = x <= playheadX
            // Fixed visual quarter dividers — ALWAYS in the set, never removed.
            let isMajor = Self.fixedDividerTicks.contains(i)

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
                // Fixed track-section dividers. Played region → bright; unplayed → base.
                tickH = majorH
                let base = Double(breathe)
                alpha = played ? min(1.0, base + (1.0 - base) * Double(animT)) : base
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

        // Musical beatgrid — drawn after waveform ticks, before hot cues.
        // Requires BPM + duration. Fixed quarter dividers remain visible underneath.
        if hasBeatGrid { drawBeatGrid(ctx: ctx, size: size, now: now) }

        // Hot cue markers — topmost layer.
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

    // Musical beatgrid overlay.
    //
    // Two layers:
    //   Estimated  (offset=0, source=estimated/analyzing): subtle, always when BPM known.
    //   Analyzed   (offset=detected, source=analyzed):     brighter, 4-bar landmarks,
    //                                                       fades in over 250ms.
    //
    // Adaptive barStride ensures something readable always shows (Rekordbox overview model):
    //   pxPerBar ≥ 4  → stride 1  (every bar)
    //   pxPer4Bar ≥ 4 → stride 4  (every 4 bars)
    //   pxPer8Bar ≥ 4 → stride 8
    //   else          → stride 16
    //
    // Heights exceed waveform (maxWaveH=11px) to form a ruler-like structure:
    //   bar ticks  → 75% ruler (~16px)
    //   4-bar mark → 100% ruler (22px, full height)
    //
    // Performance: 3 batched Paths, 3 ctx.stroke calls per layer. O(1) draw calls.
    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize, now: Date) {
        let beatDuration = 60.0 / bpm
        guard beatDuration.isFinite, beatDuration > 0 else { return }

        let h         = size.height
        let beatH:    CGFloat = (h * 0.38).rounded()  // ~8px: inner beat hints
        let barH:     CGFloat = (h * 0.75).rounded()  // ~16px: above waveform
        let fourBarH: CGFloat = h                      // 22px: full ruler height

        let pxPerBeat    = size.width * CGFloat(beatDuration / duration)
        let pxPerBar     = pxPerBeat * CGFloat(meterBeatsPerBar)
        let pxPerFourBar = pxPerBar * 4.0
        let minPx: CGFloat = 4.0

        let barStride: Int
        if      pxPerBar     >= minPx { barStride = 1  }
        else if pxPerFourBar >= minPx { barStride = 4  }
        else if pxPerFourBar * 2 >= minPx { barStride = 8  }
        else                          { barStride = 16 }

        let showBeats = pxPerBeat >= minPx

        // Lock-in transition progress.
        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold
        let lockT: CGFloat
        if isAnalyzed, let arrivedAt = gridTransition.lockedInAt {
            lockT = CGFloat(min(1.0, now.timeIntervalSince(arrivedAt) / Self.gridTransitionDuration))
        } else {
            lockT = 0
        }

        // Layer A — estimated (offset=0).
        // Always visible when BPM is known; fades as analyzed grid arrives.
        let layerAMult = 1.0 - Double(lockT)
        if layerAMult > 0.01 {
            drawGridLayer(ctx: ctx, size: size, offset: 0,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha: 0.20 * layerAMult, barAlpha: 0.40 * layerAMult, fourBarAlpha: 0,
                showBeats: showBeats, barStride: barStride, showFourBar: false)
        }

        // Layer B — analyzed (offset=detected). Grows in after confidence arrives.
        if isAnalyzed && lockT > 0.01 {
            let layerBMult = Double(lockT)
            drawGridLayer(ctx: ctx, size: size, offset: beatGridOffset,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha: 0.28 * layerBMult, barAlpha: 0.55 * layerBMult, fourBarAlpha: 0.80 * layerBMult,
                showBeats: showBeats, barStride: barStride, showFourBar: true)
        }
    }

    // Single-layer grid renderer — 3 batched Path structs regardless of beat count.
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

                // In 1-bar stride: 4-bar landmarks get full-height treatment.
                // In wider stride: every shown marker is already a landmark.
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
