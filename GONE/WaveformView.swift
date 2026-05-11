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

// Musical position within the ruler hierarchy.
private enum MusicalTickType: Int {
    case beat    = 1  // individual beat (~10px)
    case bar     = 2  // bar downbeat (~16px)
    case fourBar = 3  // 4-bar landmark (22px, full ruler height)
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

    // 61 ticks → clean 25% breakpoints at indices 0, 15, 30, 45, 60.
    // Half the density of the old 121-tick grid: ~6.5px/tick at 400px width.
    private static let totalTicks: Int = 61

    // Fixed visual quarter positions — always visible, part of GONE's visual identity.
    // Tick indices: 0=0%, 15=25%, 30=50%, 45=75%, 60=100%.
    private static let fixedDividerTicks: Set<Int> = [0, 15, 30, 45, 60]

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

    // Single unified ruler pass — NO separate overlay.
    //
    // Height cascade (tallest → shortest):
    //   4-bar landmark : 100% ruler height (22px) — navigation anchor, lineWidth 1.5
    //   bar / quarter  : 75% ruler height (~16px) — bar downbeats + fixed quarter dividers
    //   beat hint      : 44% ruler height (~10px) — individual beats when readable
    //   waveform bar   : amplitude-driven, max 44% — texture between anchors
    //
    // Musical positions are pre-computed from beat grid (or estimated at offset=0
    // while analysis is pending) and mapped to the nearest tick index. Each tick
    // inherits the highest-priority musical role that maps to it. Waveform amplitude
    // fills the gaps — it never exceeds beatH so the hierarchy stays intact.
    private func drawRuler(ctx: GraphicsContext, size: CGSize, now: Date) {
        let totalTicks = Self.totalTicks
        let playheadX  = size.width * CGFloat(displayProgress)
        let isDragging = dragRatio != nil
        let h          = size.height
        let baseline   = h

        // Height hierarchy — tallest → shortest, all within the original tick height cap:
        //   Fixed quarter dividers : 16px — ruler maximum (matches former barH)
        //   Musical sub-dividers   : 8px  — exactly half of quarters
        //   Waveform played        : 1-6px — main spectrum texture, below all dividers
        //   Waveform unplayed      : 1-2px — faint contour only
        let quarterH: CGFloat = (h * 0.73).rounded()  // ~16px
        let subDivH:  CGFloat = (h * 0.36).rounded()  // ~8px

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        // Fixed-quarter dividers breathe while BPM analysis is running.
        let breathe = isAnalyzingBeatGrid
            ? 0.50 + 0.18 * CGFloat(sin(now.timeIntervalSinceReferenceDate * 2.0))
            : 0.45

        // Prune expired play animations.
        let expiryCutoff = now.addingTimeInterval(-Self.animDuration)
        tracker.playedAt = tracker.playedAt.filter { $0.value > expiryCutoff }

        // Lock-in transition: fade musical grid from estimated (dim) → analyzed (full).
        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold
        let lockT: CGFloat
        if isAnalyzed, let arrivedAt = gridTransition.lockedInAt {
            lockT = CGFloat(min(1.0, now.timeIntervalSince(arrivedAt) / Self.gridTransitionDuration))
        } else {
            lockT = 0
        }

        // Pre-compute which tick indices carry musical significance.
        // Estimated grid (offset=0) shown at 55% alpha until analysis locks in.
        // Analyzed grid grows to 100% as lockT → 1.
        var musicalTicks: [Int: MusicalTickType] = [:]
        var musAlphaMult: Double = 0.0

        if hasBeatGrid {
            let beatDur      = 60.0 / bpm
            let pxPerBeat    = size.width * CGFloat(beatDur / duration)
            let pxPerBar     = pxPerBeat * CGFloat(meterBeatsPerBar)
            let pxPerFourBar = pxPerBar * 4.0
            // Target: musical markers no closer than 20px — keeps the ruler readable
            // at any BPM/duration. Beats only shown when unambiguously spaced.
            let minPx: CGFloat = 20.0

            let barStride: Int
            if      pxPerBar         >= minPx { barStride = 1  }
            else if pxPerFourBar     >= minPx { barStride = 4  }
            else if pxPerFourBar * 2 >= minPx { barStride = 8  }
            else if pxPerFourBar * 4 >= minPx { barStride = 16 }
            else if pxPerFourBar * 8 >= minPx { barStride = 32 }
            else                               { barStride = 64 }
            let showBeats = pxPerBeat >= minPx

            // Before analysis: estimated grid (offset=0) at 55% alpha.
            // After analysis: use detected offset, fade to 100% via lockT.
            let gridOffset = isAnalyzed ? beatGridOffset : 0
            musAlphaMult   = isAnalyzed ? (0.55 + 0.45 * Double(lockT)) : 0.55

            var beatI = 0
            var t     = gridOffset
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
        }

        // Single tick render loop — waveform and beat grid unified.
        for i in 0..<totalTicks {
            let frac    = CGFloat(i) / CGFloat(totalTicks - 1)
            let x       = frac * size.width
            let played  = x <= playheadX
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
            let lineW: CGFloat

            if isMajor {
                // Fixed quarter dividers — tallest element, always visible.
                tickH = quarterH
                lineW = 1.0
                let base = Double(breathe)
                alpha = played ? min(1.0, base + (1.0 - base) * Double(animT)) : base
            } else if musicalTicks[i] != nil {
                // Musical sub-dividers — all types at the same level (half of quarters).
                // They sit clearly above the waveform but never challenge the fixed marks.
                tickH = subDivH
                lineW = 1.0
                let baseA = 0.28 + 0.50 * Double(animT)
                alpha = baseA * musAlphaMult
            } else if !waveform.isEmpty {
                // Waveform texture — the main musical spectrum between anchors.
                // Unplayed (ghost): 1-3px — faint contour, shows track shape.
                // Played   (full):  1-9px — rich relief, energy is visible.
                let pos    = frac * CGFloat(waveform.count - 1)
                let ci0    = max(0, min(waveform.count - 1, Int(pos)))
                let ci1    = min(waveform.count - 1, ci0 + 1)
                let lerp   = pos - CGFloat(ci0)
                let v      = CGFloat(waveform[ci0]) * (1 - lerp) + CGFloat(waveform[ci1]) * lerp
                let norm   = max(0, (v - waveMin) / waveRange)
                let ghostH = 1.0 + norm * 1.5
                let fullH  = 1.0 + norm * 5.0
                tickH = ghostH + (fullH - ghostH) * animT
                alpha = 0.20 + 0.55 * Double(animT)
                lineW = 1.0
            } else {
                tickH = 2 + 2 * animT
                alpha = 0.15 + 0.28 * Double(animT)
                lineW = 1.0
            }

            var path = Path()
            path.move(to:    CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: lineW, lineCap: .butt))
        }

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
}
