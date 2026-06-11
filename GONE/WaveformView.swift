import SwiftUI
import Combine

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
            loopA: state.loopA,
            loopB: state.loopB,
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
        .onReceive(state.progressFeed.objectWillChange) { _ in
            feedProgress = state.progressFeed.progress
        }
    }
}

// Class-based storage for divider animation timestamps.
// Mutations don't trigger SwiftUI invalidation — Canvas re-runs at 30fps.
private final class BarTracker {
    var playedAt: [Int: Date] = [:]
}

// Ruler tick hierarchy — determines height (tallest → shortest).
private enum MusicalTickType: Int {
    case beat    = 1  // 2px — bottom "millimeter" texture
    case bar     = 2  // subDivH — bar downbeats
    case fourBar = 3  // quarterH — 4-bar musical anchors
}

private struct MusicalGridTick {
    let ratio: Double
    let type: MusicalTickType
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
    var loopA: Double? = nil
    var loopB: Double? = nil
    var isPlaying: Bool = true
    let onSeek: (Double) -> Void

    @State private var dragRatio: Double?
    @State private var tracker = BarTracker()
    @State private var lastKnownProgress: Double = -1
    @State private var waveMinCache: CGFloat = 0
    @State private var waveRangeCache: CGFloat = 1

    private static let animDuration: Double = 0.38
    private static let confidenceThreshold: Double = 0.78

    // 161 ticks — ~2.5px/tick at 400px width.
    private static let totalTicks: Int = 161

    // Pre-analysis fallback: fixed marks at 0 / 25 / 50 / 75 / 100%.
    private static let defaultStructuralTicks: Set<Int> = [0, 40, 80, 120, 160]
    private static let defaultSubStructuralTicks: Set<Int> = [
        10, 20, 30,
        50, 60, 70,
        90, 100, 110,
        130, 140, 150
    ]

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
        waveRangeCache = max(hi - lo, 0.001)
    }

    // Drawing layers (bottom → top):
    //   1. Waveform silhouette — filled grey shape, flat bottom, amplitude top
    //   2. Interstitial bottom ticks (3px) — one extra mark between ruler divisions
    //   3. Beat micro-ticks (2px) — bottom ruler texture, visible when beats fit
    //   4. Bar / sub-quarter ticks (subDivH) — secondary structure
    //   5. Track-quarter structural ticks (quarterH) — tallest navigation anchors
    //   6. A-B loop region and markers
    //   7. Hot cue markers
    //
        // Base ruler is always rendered so every track keeps the same "measuring tape"
        // texture. Beat-grid ticks are an overlay, not a replacement for the ruler.
    private func drawRuler(ctx: GraphicsContext, size: CGSize, now: Date) {
        let totalTicks = Self.totalTicks
        let playheadX  = size.width * CGFloat(displayProgress)
        let h          = size.height
        let baseline   = h

        // Height levels (tallest → shortest):
        let quarterH: CGFloat = max(14, h - 4).rounded()         // tallest, leaves a small top gutter
        let subDivH:  CGFloat = max(8, (quarterH * 0.56).rounded()) // middle divisions
        let tinyH:    CGFloat = 2                                // smallest bottom micro-ticks
        let interstitialH: CGFloat = 3                           // tiny fallback texture between divisions
        let maxWaveH: CGFloat = max(4, subDivH + 3)              // peaks rise above middle dividers

        let waveMin   = waveMinCache
        let waveRange = waveRangeCache

        let expiryCutoff = now.addingTimeInterval(-Self.animDuration)
        tracker.playedAt = tracker.playedAt.filter { $0.value > expiryCutoff }

        let isAnalyzed = beatGridConfidence >= Self.confidenceThreshold
        let structuralTicks = Self.defaultStructuralTicks
        let subStructuralTicks = Self.defaultSubStructuralTicks

        // ── 1. Waveform bars — SoundCloud-style discrete one-color strips ────────
        // Same data, same zone as the old filled silhouette; just rendered as neat
        // vertical bars with a gap, plus a gamma curve (^1.45) so quiet sections sink
        // and drops stand out — the relief reads as track structure at a glance.
        if !waveform.isEmpty {
            // Dense 1px lattice: hairline strips on a 2px pitch — the track body reads
            // as fine texture, structural dividers (2px, below) stay visually superior.
            let barW: CGFloat = 1
            let gap:  CGFloat = 1
            let step = barW + gap
            let slots = max(1, Int(size.width / step))

            func amp(atFrac frac: CGFloat) -> CGFloat {
                let pos  = frac * CGFloat(waveform.count - 1)
                let ci0  = max(0, min(waveform.count - 1, Int(pos)))
                let ci1  = min(waveform.count - 1, ci0 + 1)
                let lerp = pos - CGFloat(ci0)
                let v    = CGFloat(waveform[ci0]) * (1 - lerp) + CGFloat(waveform[ci1]) * lerp
                let norm = max(0, min(1, (v - waveMin) / waveRange))
                let shaped = pow(norm, 1.8)   // hard relief: quiet parts sink, drops spike
                return max(1.0, shaped * maxWaveH)
            }

            var played = Path()
            var rest   = Path()
            for s in 0..<slots {
                let x = CGFloat(s) * step
                let a = amp(atFrac: (x + barW / 2) / size.width)
                let bar = Path(CGRect(x: x, y: baseline - a, width: barW, height: a))
                if x + barW / 2 <= playheadX { played.addPath(bar) } else { rest.addPath(bar) }
            }
            ctx.fill(rest,   with: .color(.white.opacity(0.11)))
            ctx.fill(played, with: .color(.white.opacity(0.30)))
        }

        // ── 2. Compute tick positions ────────────────────────────────────────────
        var musicalTicks: [MusicalGridTick] = []

        if hasBeatGrid && isAnalyzed {
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
                let ratio = t / duration
                guard ratio >= 0, ratio <= 1 else { continue }

                if beatInBar == 0 && barI % barStride == 0 {
                    // When the grid is coarsened, do not promote every visible tick
                    // to a tall 4-bar anchor. Keep a visual hierarchy across visible marks.
                    let visibleBarIndex = max(0, barI / max(1, barStride))
                    let type: MusicalTickType = (visibleBarIndex % 4 == 0) ? .fourBar : .bar
                    musicalTicks.append(MusicalGridTick(ratio: ratio, type: type))
                } else if beatInBar != 0 && showBeats {
                    musicalTicks.append(MusicalGridTick(ratio: ratio, type: .beat))
                }
            }
        }

        // ── 3. Render base interstitial bottom ticks ─────────────────────────────
        for i in 0..<(totalTicks - 1) {
            let posInGap = i % 10
            guard posInGap == 3 || posInGap == 6 else { continue }
            let frac = (CGFloat(i) + 0.5) / CGFloat(totalTicks - 1)
            let x = (frac * size.width * 2).rounded() / 2
            let alpha: Double = 0.04

            var path = Path()
            path.move(to: CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - interstitialH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }

        // ── 4. Render musical grid ticks at exact time positions ─────────────────
        for tick in musicalTicks {
            let x = (CGFloat(tick.ratio) * size.width * 2).rounded() / 2

            // Dividers outrank the 1px track lattice — SoundCloud-style hierarchy:
            // structural marks are 2px, the waveform body stays hairline.
            let tickH: CGFloat
            let alpha: Double
            let width: CGFloat
            switch tick.type {
            case .fourBar:
                tickH = quarterH
                alpha = 0.22
                width = 2.0
            case .bar:
                tickH = subDivH
                alpha = 0.14
                width = 2.0
            case .beat:
                tickH = tinyH
                alpha = 0.07
                width = 1.0
            }

            var path = Path()
            path.move(to: CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }

        // ── 5. Render stable structural tick lines ───────────────────────────────
        for i in 0..<totalTicks {
            let isMajor = structuralTicks.contains(i)
            let isSubMajor = subStructuralTicks.contains(i)
            guard isMajor || isSubMajor else { continue }

            let frac   = CGFloat(i) / CGFloat(totalTicks - 1)
            let x      = (frac * size.width * 2).rounded() / 2

            let tickH: CGFloat
            let alpha: Double

            if isMajor {
                tickH = quarterH
                alpha = 0.20
            } else if isSubMajor {
                tickH = subDivH
                alpha = 0.13
            } else { continue }

            var path = Path()
            path.move(to:    CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 2.0, lineCap: .butt))
        }

        // ── 6. A-B loop markers ──────────────────────────────────────────────────
        if let loopA,
           let loopB,
           duration > 0,
           loopB > loopA {
            let ax = CGFloat(loopA / duration) * size.width
            let bx = CGFloat(loopB / duration) * size.width
            let region = CGRect(x: ax, y: 0, width: max(1, bx - ax), height: size.height)
            ctx.fill(Path(region), with: .color(G.accentPrimary.opacity(0.10)))

            for (x, label) in [(ax, "A"), (bx, "B")] {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(G.accentPrimary.opacity(0.78)),
                           style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
                ctx.draw(
                    Text(label).font(G.mono(7, weight: .bold)).foregroundColor(G.textPrimary.opacity(0.75)),
                    at: CGPoint(x: x + 4, y: 4),
                    anchor: .topLeading
                )
            }
        }

        // ── 7. Hot cue markers — topmost ─────────────────────────────────────────
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
