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

// Class-based storage for bar animation timestamps.
// Mutations don't trigger SwiftUI invalidation — the TimelineView Canvas
// already re-runs at 30fps and reads the latest values on each tick.
private final class BarTracker {
    var playedAt: [Int: Date] = [:]
}

// Class-based storage for beat grid lock-in animation.
// Records when the analyzed grid first arrived so the Canvas can
// compute transition progress without triggering SwiftUI re-renders.
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
    private static let confidenceThreshold: Double = 0.30

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
            // Record exact moment the analyzed grid arrives so the Canvas
            // can animate a smooth lock-in without needing @State mutation.
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

        // When a real beat grid is available, suppress the arbitrary 0/25/50/75/100
        // fixed dividers — musical bar markers provide better visual structure.
        let majorSet: Set<Int> = hasBeatGrid ? [] : [0, 30, 60, 90, 120]

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        // Prune entries whose animation has completed (elapsed > animDuration).
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

        // Beat grid — drawn after waveform so bars read over the waveform texture,
        // before hot cues so cues remain the topmost visual layer.
        if hasBeatGrid {
            drawBeatGrid(ctx: ctx, size: size, now: now)
        }

        // Hot cue markers — small colored ticks at the top of the ruler
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

    // Draws the adaptive beat/bar grid.
    //
    // Two-layer system:
    //   Layer A (fallback): offset=0, muted alpha — always visible when hasBeatGrid
    //   Layer B (analyzed): offset=beatGridOffset, full alpha — fades in when confidence ≥ threshold
    //
    // Lock-in animation: layer A fades out, layer B grows in over gridTransitionDuration.
    //
    // Visual hierarchy (bottom → top):
    //   beat ticks · bar ticks · 4-bar ticks
    //
    // LOD tiers (density guard):
    //   pxPerBeat ≥ 6 → beats + bars + 4-bar
    //   pxPerBeat < 6 AND pxPerBar ≥ 8 → bars + 4-bar only
    //   pxPerBar  < 8 → phrase markers only (every 8 bars)
    //
    // Performance: 3 batched Path structs max, 3 ctx.stroke calls per layer — O(1) draw
    // calls regardless of beat count.
    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize, now: Date) {
        let beatDuration = 60.0 / bpm
        guard beatDuration.isFinite, beatDuration > 0 else { return }

        // Tier heights
        let beatH:    CGFloat = 4
        let barH:     CGFloat = 12
        let fourBarH: CGFloat = 20

        // LOD thresholds
        let pxPerBeat = size.width * CGFloat(beatDuration / duration)
        let pxPerBar  = pxPerBeat * CGFloat(meterBeatsPerBar)
        let drawBeats   = pxPerBeat >= 6.0
        let drawBars    = pxPerBar  >= 8.0
        let phraseOnly  = !drawBars
        let phraseEvery = 8

        guard drawBeats || drawBars else { return }

        // Transition progress: 0 = fallback only, 1 = analyzed fully locked in
        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold
        let transitionT: CGFloat
        if isAnalyzed, let arrivedAt = gridTransition.lockedInAt {
            let elapsed = now.timeIntervalSince(arrivedAt)
            transitionT = CGFloat(min(1.0, elapsed / Self.gridTransitionDuration))
        } else {
            transitionT = 0
        }

        // Layer A: fallback grid (offset = 0), fades out as analyzed arrives.
        // Alpha envelope: 1.0 → 0 over the transition.
        let layerAMultiplier = 1.0 - Double(transitionT)
        if layerAMultiplier > 0.01 {
            drawGridLayer(
                ctx: ctx, size: size,
                offset: 0,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha:    0.14 * layerAMultiplier,
                barAlpha:     0.30 * layerAMultiplier,
                fourBarAlpha: 0,           // fallback shows no 4-bar emphasis
                drawBeats: drawBeats, drawBars: drawBars,
                phraseOnly: phraseOnly, phraseEvery: phraseEvery,
                showFourBar: false
            )
        }

        // Layer B: analyzed grid (offset = beatGridOffset), grows in.
        // Only rendered when analysis has arrived.
        if isAnalyzed && transitionT > 0.01 {
            let layerBMultiplier = Double(transitionT)
            drawGridLayer(
                ctx: ctx, size: size,
                offset: beatGridOffset,
                beatH: beatH, barH: barH, fourBarH: fourBarH,
                beatAlpha:    0.22 * layerBMultiplier,
                barAlpha:     0.50 * layerBMultiplier,
                fourBarAlpha: 0.70 * layerBMultiplier,
                drawBeats: drawBeats, drawBars: drawBars,
                phraseOnly: phraseOnly, phraseEvery: phraseEvery,
                showFourBar: true
            )
        }
    }

    // Single-layer grid renderer. Caller controls alpha envelope so this stays
    // allocation-budget neutral: 3 Path structs, 3 ctx.stroke calls regardless of BPM/length.
    private func drawGridLayer(
        ctx: GraphicsContext, size: CGSize,
        offset: Double,
        beatH: CGFloat, barH: CGFloat, fourBarH: CGFloat,
        beatAlpha: Double, barAlpha: Double, fourBarAlpha: Double,
        drawBeats: Bool, drawBars: Bool,
        phraseOnly: Bool, phraseEvery: Int,
        showFourBar: Bool
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
                let barIdx    = beatIndex / meterBeatsPerBar
                let isFourBar = barIdx % 4 == 0
                let isPhrase  = barIdx % phraseEvery == 0

                if showFourBar && isFourBar && drawBars {
                    fourBarPath.move(to:    CGPoint(x: x, y: baseline))
                    fourBarPath.addLine(to: CGPoint(x: x, y: baseline - fourBarH))
                } else if drawBars || (phraseOnly && isPhrase) {
                    barPath.move(to:    CGPoint(x: x, y: baseline))
                    barPath.addLine(to: CGPoint(x: x, y: baseline - barH))
                }
            } else if drawBeats {
                beatPath.move(to:    CGPoint(x: x, y: baseline))
                beatPath.addLine(to: CGPoint(x: x, y: baseline - beatH))
            }
        }

        if drawBeats && beatAlpha > 0 {
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
