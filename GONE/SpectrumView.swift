import SwiftUI

struct SpectrumView: View {
    let data: [Float]       // 0..0.24 from AudioEngineNext, already smoothed
    let isPlaying: Bool

    @State private var peaks:   [Float] = Array(repeating: 0, count: 24)
    @State private var peakAt:  [Date]  = Array(repeating: .distantPast, count: 24)
    @State private var colPeak: [Float] = Array(repeating: 0.08, count: 24)

    // Blend transition: 0 = idle, 1 = playing
    @State private var blendFrom:   Float = 0
    @State private var blendTarget: Float = 0
    @State private var blendStart:  Date  = .distantPast
    private let blendDuration: Float = 0.75

    private let ceil: Float      = 0.40
    private let peakHold: Double = 0.40
    private let gravity: Float   = 4.5
    // Spectrum input is divided by 2.5 so it builds as if volume is 2.5× quieter
    private let specScale: Float = 0.4

    // Pixel grid: 3px pixels, 1px gaps → 24 cols × 8 rows in 96×34
    private let pixH: CGFloat    = 3
    private let colGap: CGFloat  = 1
    private let rowGap: CGFloat  = 1


    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                drawPixels(ctx: ctx, size: size, now: tl.date)
            }
        }
        .onChange(of: isPlaying) { playing in
            blendFrom   = currentBlend(at: Date())
            blendStart  = Date()
            blendTarget = playing ? 1 : 0
        }
        .onChange(of: data) { newData in
            let now = Date()
            for i in 0..<min(peaks.count, newData.count) {
                let v = newData[i] * specScale
                let vSq = v * v
                if vSq > decayedPeak(i, now: now) {
                    peaks[i] = vSq
                    peakAt[i] = now
                }
            }
            let cnt = 24
            for col in 0..<cnt {
                let srcIdx = newData.isEmpty ? 0 : min(col * (newData.count - 1) / max(cnt - 1, 1), newData.count - 1)
                let v: Float = (newData.isEmpty ? 0 : newData[srcIdx]) * specScale
                let vSq = v * v
                if vSq > colPeak[col] {
                    colPeak[col] = colPeak[col] * 0.10 + vSq * 0.90
                } else {
                    colPeak[col] = max(0.001, colPeak[col] * 0.997)
                }
            }
        }
    }

    private func currentBlend(at now: Date) -> Float {
        let elapsed = Float(now.timeIntervalSince(blendStart))
        let t = min(1, elapsed / blendDuration)
        let eased = t * t * (3 - 2 * t)
        return blendFrom + (blendTarget - blendFrom) * eased
    }

    private func drawPixels(ctx: GraphicsContext, size: CGSize, now: Date) {
        let blend    = currentBlend(at: now)
        let idleVals = idleBars(now: now)
        let count    = 24

        let colW     = (size.width - CGFloat(count - 1) * colGap) / CGFloat(count)
        let rowCount = max(1, Int((size.height + rowGap) / (pixH + rowGap)))

        let t = now.timeIntervalSinceReferenceDate

        for col in 0..<count {
            let x = CGFloat(col) * (colW + colGap)
            let srcIdx = data.isEmpty ? 0 : min(col * (data.count - 1) / max(count - 1, 1), data.count - 1)
            let vP: Float  = (data.isEmpty ? 0 : data[srcIdx]) * specScale
            let vPsq: Float = vP * vP   // squared — amplifies kick/beat contrast over sustained content
            let vD: Float  = col < idleVals.count ? idleVals[col] : 0

            // colPeak tracks vPsq (not vP); gate at 70% pushes sustained bass below threshold
            // so bars fire on beats rather than staying full during sustained content.
            let peak  = col < colPeak.count ? colPeak[col] : 0.001
            let gate  = peak * 0.70
            let ncAgc = CGFloat(min(1, max(0, (vPsq - gate) / max(0.0001, peak - gate))))
            let ncFix = CGFloat(min(1, max(0, vD / 0.22)))
            let nc    = ncAgc * CGFloat(blend) + ncFix * CGFloat(1 - blend)
            let norm  = nc * nc * nc
            let litRows = Int((norm * CGFloat(rowCount)).rounded(.up))

            var peakRow = -1
            if blend > 0.02 {
                let pvSq = decayedPeak(col, now: now)  // stored as vSq
                if pvSq > 0.001 {
                    let pvNc  = CGFloat(min(1, max(0, (pvSq - gate) / max(0.0001, peak - gate))))
                    peakRow   = min(rowCount - 1, Int((pvNc * pvNc * pvNc * CGFloat(rowCount)).rounded(.up)))
                }
            }

            // Shimmer wave: sweeps left→right across columns
            let shimmer = max(0.0, sin(t * 2.6 + Double(col) * 0.55)) * Double(blend)

            for row in 0..<rowCount {
                let y = size.height - CGFloat(row + 1) * pixH - CGFloat(row) * rowGap

                let isLit  = row < litRows
                let isTip  = isLit && row == litRows - 1
                let isPeak = row == peakRow && peakRow >= litRows

                let opacity: Double
                if isTip {
                    // Tip twinkles independently
                    let twinkle = sin(t * 9.5 + Double(col) * 1.8) * 0.5 + 0.5
                    opacity = 0.58 + twinkle * 0.22
                } else if isLit {
                    let pos = litRows > 1 ? Double(row) / Double(litRows - 1) : 0
                    if pos > 0.85      { opacity = 0.50 + shimmer * 0.14 }
                    else if pos > 0.55 { opacity = 0.30 + shimmer * 0.08 }
                    else               { opacity = 0.16 + shimmer * 0.04 }
                } else if isPeak {
                    opacity = Double(blend) * 0.42
                } else {
                    opacity = 0.045
                }

                ctx.fill(
                    Path(CGRect(x: x, y: y, width: colW, height: pixH)),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }

    private func decayedPeak(_ i: Int, now: Date) -> Float {
        let h = peaks[i]
        guard h > 0 else { return 0 }
        let elapsed = Float(now.timeIntervalSince(peakAt[i]))
        guard elapsed > Float(peakHold) else { return h }
        return max(0, h - gravity * pow(elapsed - Float(peakHold), 2))
    }

    // Idle: phase-modulated FM waves — phases themselves drift, pattern never exactly repeats
    private func idleBars(now: Date) -> [Float] {
        let t = now.timeIntervalSinceReferenceDate
        return (0..<24).map { i in
            let pos = Double(i) / 23.0
            // Slow phase modulators (FM carriers)
            let pm1 = sin(t * 0.31 + pos * 1.70) * 1.40
            let pm2 = sin(t * 0.19 - pos * 2.30) * 1.10
            // Six waves with irrational ratios + phase modulation
            let a = (sin(t * 0.55 + pos * .pi * 2.8 + pm1)          + 1) * 0.5
            let b = (sin(t * 1.73 - pos * .pi * 1.6 + pm2)          + 1) * 0.5
            let c = (sin(t * 0.22 + pos * 0.80)                      + 1) * 0.5
            let d = (sin(t * 3.14 + pos * .pi * 5.2 + pm1 * 0.50)   + 1) * 0.5
            let e = (sin(t * 0.97 + pos * .pi * 0.9 - pm2 * 0.30)   + 1) * 0.5
            let f = (sin(t * 2.41 - pos * 3.10 + sin(t * 0.43 + pos) * 0.90) + 1) * 0.5
            let combined = a * 0.20 + b * 0.18 + c * 0.15 + d * 0.15 + e * 0.17 + f * 0.15
            return Float(combined * 0.22)
        }
    }
}
