import SwiftUI

struct ProgressRulerRow: View {
    @EnvironmentObject var state: PlayerState

    var body: some View {
        ProgressRuler(
            progress: state.progress,
            waveform: state.current?.waveform ?? [],
            onSeek: { ratio in
                state.progress = ratio
                AudioEngineNext.shared.seek(ratio: ratio)
            }
        )
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.top, 3)
        .padding(.bottom, 4)
    }
}

struct ProgressRuler: View {
    let progress: Double
    let waveform: [Float]
    let onSeek: (Double) -> Void

    @State private var dragRatio: Double?

    private var displayProgress: Double { dragRatio ?? progress }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawRuler(ctx: ctx, size: size)
            }
            .allowsHitTesting(false)

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
    }

    private func drawRuler(ctx: GraphicsContext, size: CGSize) {
        // 121 = 4×30+1 → quarters land exactly at indices 0,30,60,90,120
        let totalTicks = 121
        let playheadX  = size.width * CGFloat(displayProgress)

        let tallH:     CGFloat = 16   // quarter dividers — always tallest
        let maxWaveH:  CGFloat = 12   // played peak — 4pt below dividers
        let minWaveH:  CGFloat = 2    // played floor
        let maxGhostH: CGFloat = 6    // unplayed silhouette — 50% of played peak
        let minGhostH: CGFloat = 1
        let shortH:    CGFloat = 3    // fallback when no waveform data
        let baseline:  CGFloat = size.height

        let majorSet: Set<Int> = [0, 30, 60, 90, 120]

        for i in 0..<totalTicks {
            let frac    = CGFloat(i) / CGFloat(totalTicks - 1)
            let x       = frac * size.width
            let played  = x <= playheadX
            let isMajor = majorSet.contains(i)

            let tickH: CGFloat
            let alpha: Double

            if isMajor {
                tickH = tallH
                alpha = played ? 0.85 : 0.25
            } else if !waveform.isEmpty {
                // Interpolate between adjacent waveform bars for smooth transitions
                let pos = frac * CGFloat(waveform.count - 1)
                let ci0 = max(0, min(waveform.count - 1, Int(pos)))
                let ci1 = min(waveform.count - 1, ci0 + 1)
                let t   = pos - CGFloat(ci0)
                let v   = CGFloat(waveform[ci0]) * (1 - t) + CGFloat(waveform[ci1]) * t
                let norm = pow(max(0, (v - 0.04) / 0.86), 3.0)
                if played {
                    tickH = minWaveH + norm * (maxWaveH - minWaveH)
                    alpha = 0.85
                } else {
                    // Unplayed silhouette: same shape, 50% height, dim
                    tickH = minGhostH + norm * (maxGhostH - minGhostH)
                    alpha = 0.22
                }
            } else if played {
                tickH = shortH + 1
                alpha = 0.50
            } else {
                tickH = shortH
                alpha = 0.18
            }

            var path = Path()
            path.move(to:    CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - tickH))
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
        }
    }
}
