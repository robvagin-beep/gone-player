import SwiftUI

struct EQPanelView: View {
    @EnvironmentObject var state: PlayerState
    private let controlBlockHeight: CGFloat = 128

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(G.borderSubtle)
                .frame(height: 1)

            VStack(spacing: 0) {
                // Faders + knob stack + curve
                HStack(alignment: .top, spacing: 8) {
                    // ── Left: all faders ──────────────────────────────────────
                    HStack(spacing: 4) {
                        EQFaderColumn(
                            value: Binding(
                                get: { Double(state.eqPreamp) },
                                set: { v in
                                    state.eqPreamp = Float(v)
                                    AudioEngineNext.shared.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
                                }
                            ),
                            label: "PRE", isPreamp: true
                        )

                        // Separator
                        Rectangle()
                            .fill(G.borderSubtle)
                            .frame(width: 1, height: 96)
                            .padding(.horizontal, 3)
                            .padding(.top, 2)

                        EQFaderColumn(
                            value: Binding(
                                get: { Double((state.eqBands[0] + state.eqBands[1] + state.eqBands[2]) / 3) },
                                set: { v in
                                    var b = state.eqBands; b[0] = Float(v); b[1] = Float(v); b[2] = Float(v)
                                    state.eqBands = b
                                    if state.eqPreset != "Custom" { state.eqPreset = "Custom" }
                                    AudioEngineNext.shared.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
                                }
                            ),
                            label: "LO", isPreamp: false
                        )
                        EQFaderColumn(
                            value: Binding(
                                get: { Double((state.eqBands[3] + state.eqBands[4]) / 2) },
                                set: { v in
                                    var b = state.eqBands; b[3] = Float(v); b[4] = Float(v)
                                    state.eqBands = b
                                    if state.eqPreset != "Custom" { state.eqPreset = "Custom" }
                                    AudioEngineNext.shared.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
                                }
                            ),
                            label: "ML", isPreamp: false
                        )
                        EQFaderColumn(
                            value: Binding(
                                get: { Double((state.eqBands[5] + state.eqBands[6]) / 2) },
                                set: { v in
                                    var b = state.eqBands; b[5] = Float(v); b[6] = Float(v)
                                    state.eqBands = b
                                    if state.eqPreset != "Custom" { state.eqPreset = "Custom" }
                                    AudioEngineNext.shared.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
                                }
                            ),
                            label: "MH", isPreamp: false
                        )
                        EQFaderColumn(
                            value: Binding(
                                get: { Double((state.eqBands[7] + state.eqBands[8] + state.eqBands[9]) / 3) },
                                set: { v in
                                    var b = state.eqBands; b[7] = Float(v); b[8] = Float(v); b[9] = Float(v)
                                    state.eqBands = b
                                    if state.eqPreset != "Custom" { state.eqPreset = "Custom" }
                                    AudioEngineNext.shared.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
                                }
                            ),
                            label: "HI", isPreamp: false
                        )

                        // Separator
                        Rectangle()
                            .fill(G.borderSubtle)
                            .frame(width: 1, height: 96)
                            .padding(.horizontal, 3)
                            .padding(.top, 2)

                        // HPF · LPF · FX knob stack
                        EQKnobStack()
                    }
                    .frame(height: controlBlockHeight)
                    .opacity(state.eqOn ? 1 : 0.45)
                    .allowsHitTesting(state.eqOn)

                    // ── Right: EQ curve ───────────────────────────────────────
                    EQCurveView()
                        .frame(maxWidth: .infinity)
                        .frame(height: controlBlockHeight)
                        .opacity(state.eqOn ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(G.bgPanelEQ)
        }
    }
}

// ── EQ ON/OFF button ──────────────────────────────────────────────────────────
struct EQToggleButton: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("EQ \(on ? "ON" : "OFF")")
                .font(G.sans(9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(on ? G.textOnLight : Color.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(on ? G.accentPrimary : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: G.rControl))
        }
        .buttonStyle(.plain)
    }
}

// ── Preset picker — same pill shape as EQ ON ─────────────────────────────────
struct EQPresetPicker: View {
    @Binding var preset: String

    private static let orderedPresets: [String] = {
        let all = Array(PlayerState.eqPresets.keys.filter { $0 != "Flat" }.sorted())
        return ["Flat"] + all + ["Custom"]
    }()

    private var isActive: Bool { preset != "Flat" }

    var body: some View {
        Menu {
            ForEach(Self.orderedPresets, id: \.self) { option in
                Button {
                    preset = option
                } label: {
                    HStack {
                        Text(option)
                        if option == preset { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                Text(preset)
                    .font(G.sans(9, weight: .semibold))
                    .tracking(0.5)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? G.textOnLight : Color.white.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isActive ? G.accentPrimary : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: G.rControl))
        }
        .menuStyle(.borderlessButton)
    }
}

// ── Single EQ fader column ────────────────────────────────────────────────────
struct EQFaderColumn: View {
    @Binding var value: Double
    let label: String
    let isPreamp: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            EQVerticalFader(value: $value, isPreamp: isPreamp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(label)
                .font(G.mono(8, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.50))
                .tracking(0.2)
                .padding(.bottom, 5)
        }
        .frame(width: 26)
    }
}

// ── Vertical bar fader — click anywhere to set ────────────────────────────────
struct EQVerticalFader: View {
    @Binding var value: Double
    let isPreamp: Bool

    private let range = 12.0
    private let cr: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let fraction = CGFloat((value + range) / (range * 2))   // 0..1; 0.5 = 0 dB
            let fillH = max(cr * 2, fraction * h)

            ZStack(alignment: .bottom) {
                // Track background
                RoundedRectangle(cornerRadius: cr)
                    .fill(Color.white.opacity(0.08))

                // Fill — plain rect, clipped by container's rounded corners
                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: fillH)

                // 0 dB center tick
                Color.white.opacity(0.20)
                    .frame(height: 1)
                    .offset(y: -(h / 2))
            }
            .clipShape(RoundedRectangle(cornerRadius: cr))
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let ratio = 1.0 - Double(g.location.y / h)
                        let v = (ratio * 2 - 1) * range
                        value = max(-range, min(range, abs(v) < 0.5 ? 0 : (v * 10).rounded() / 10))
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
            .cursor(NSCursor.resizeUpDown)
        }
    }
}


// ── Stacked knob column: HPF · LPF · FX ──────────────────────────────────────
struct EQKnobStack: View {
    @EnvironmentObject var state: PlayerState

    private var hpfLabel: String {
        guard state.hpfCutoff >= 0.015 else { return "HPF" }
        let hz = 20.0 * powf(100.0, state.hpfCutoff)
        return hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }

    private var lpfLabel: String {
        guard state.lpfCutoff >= 0.015 else { return "LPF" }
        let hz = 20000.0 * powf(0.01, state.lpfCutoff)
        return hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }

    private var fxLabel: String {
        guard state.reverbAmount >= 0.015 else { return "FX" }
        return "\(Int(state.reverbAmount * 100))%"
    }

    var body: some View {
        // Centered vertically with equal top/bottom breathing room
        VStack {
            Spacer(minLength: 0)

            EQMiniKnob(
                value: Binding(
                    get: { state.hpfCutoff },
                    set: { state.hpfCutoff = $0; AudioEngineNext.shared.setHPF(cutoff: $0) }
                ),
                label: hpfLabel
            )

            Spacer(minLength: 0).frame(maxHeight: 8)

            EQMiniKnob(
                value: Binding(
                    get: { state.lpfCutoff },
                    set: { state.lpfCutoff = $0; AudioEngineNext.shared.setLPF(cutoff: $0) }
                ),
                label: lpfLabel
            )

            Spacer(minLength: 0).frame(maxHeight: 8)

            VStack(spacing: 2) {
                EQMiniKnob(
                    value: Binding(
                        get: { state.reverbAmount },
                        set: { state.reverbAmount = $0; AudioEngineNext.shared.setReverb(amount: $0) }
                    ),
                    label: fxLabel
                )
                Button { state.cycleReverbPreset() } label: {
                    Text(state.reverbPreset.uppercased())
                        .font(G.mono(6.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .tracking(0.4)
                        .frame(width: 36)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .opacity(state.reverbAmount >= 0.015 ? 1 : 0.45)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 36)
    }
}

// ── Mini rotary knob (24×24) — flat style ────────────────────────────────────
struct EQMiniKnob: View {
    @Binding var value: Float
    let label: String

    @State private var dragStart: (y: CGFloat, v: Float)? = nil

    var body: some View {
        VStack(spacing: 3) {
            Canvas { ctx, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let trackR = min(size.width, size.height) / 2 - 2.0
                let center = CGPoint(x: cx, y: cy)

                // Background arc — 7:30 → CW 270° → 4:30
                var bgArc = Path()
                bgArc.addArc(center: center, radius: trackR,
                             startAngle: .degrees(135), endAngle: .degrees(45),
                             clockwise: false)
                ctx.stroke(bgArc, with: .color(.white.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                // Active arc
                if value > 0.01 {
                    let endDeg = 135.0 + 270.0 * Double(value)
                    var activeArc = Path()
                    activeArc.addArc(center: center, radius: trackR,
                                     startAngle: .degrees(135), endAngle: .degrees(endDeg),
                                     clockwise: false)
                    ctx.stroke(activeArc, with: .color(.white.opacity(0.68)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }

                // Knob body — flat, no heavy gradient
                let knobR = trackR - 3.5
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - knobR, y: cy - knobR,
                                          width: knobR * 2, height: knobR * 2)),
                    with: .color(.white.opacity(0.14))
                )

                // Indicator dot
                let angleDeg = -135.0 + 270.0 * Double(value)
                let angleRad = angleDeg * .pi / 180.0
                let dotR = knobR * 0.55
                let dotX = cx + dotR * CGFloat(sin(angleRad))
                let dotY = cy - dotR * CGFloat(cos(angleRad))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: dotX - 1.0, y: dotY - 1.0, width: 2, height: 2)),
                    with: .color(value < 0.015 ? .white.opacity(0.22) : .white.opacity(0.88))
                )
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStart == nil { dragStart = (g.startLocation.y, value) }
                        let dy = g.location.y - (dragStart?.y ?? 0)
                        value = max(0, min(1, (dragStart?.v ?? 0) - Float(dy / 80)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { value = 0 }
            )
            .cursor(NSCursor.resizeUpDown)

            Text(label)
                .font(G.mono(7, weight: .medium))
                .foregroundStyle(value < 0.015 ? G.textTertiary : G.textSecondary)
                .tracking(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 36)
        }
    }
}

// ── EQ frequency response curve ───────────────────────────────────────────────
struct EQCurveView: View {
    @EnvironmentObject var state: PlayerState
    @State private var displayedBands: [Float] = Array(repeating: 0, count: 10)
    @State private var displayedPreamp: Float = 0
    @State private var animTask: Task<Void, Never>? = nil

    private let bandFreqs: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    private let dbLines: [Float] = [-12, -6, 0, 6, 12]

    var body: some View {
        Canvas { ctx, size in
            let bands  = displayedBands
            let preamp = displayedPreamp
            let hpfCut = state.hpfCutoff
            let lpfCut = state.lpfCutoff

            let pad  = (l: CGFloat(14), r: CGFloat(10), t: CGFloat(10), b: CGFloat(6))
            let iW   = size.width  - pad.l - pad.r
            let iH   = size.height - pad.t - pad.b
            let dbMax: Float = 14

            let logFmin = log10(Float(20))
            let logFmax = log10(Float(20000))

            func tForHz(_ hz: Float) -> Float {
                (log10(max(hz, 1)) - logFmin) / (logFmax - logFmin)
            }
            func xForT(_ t: Float) -> CGFloat {
                pad.l + CGFloat(max(0, min(1, t))) * iW
            }
            func yFor(_ db: Float) -> CGFloat {
                pad.t + iH / 2 - CGFloat(db / dbMax) * (iH / 2)
            }

            let zeroY = yFor(0)

            // Horizontal dB grid + labels
            for db in dbLines {
                let y   = yFor(db)
                let mid = db == 0
                var ln  = Path()
                ln.move(to: CGPoint(x: pad.l, y: y))
                ln.addLine(to: CGPoint(x: size.width - pad.r, y: y))
                ctx.stroke(ln,
                           with: .color(.white.opacity(mid ? 0.18 : 0.07)),
                           style: StrokeStyle(lineWidth: 0.5, dash: mid ? [] : [1.5, 2.5]))

                let dbLabel = db == 0 ? "0" : (db > 0 ? "+\(Int(db))" : "\(Int(db))")
                ctx.draw(
                    Text(dbLabel)
                        .font(.system(size: 6.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(mid ? 0.40 : 0.26)),
                    at: CGPoint(x: pad.l - 4, y: y),
                    anchor: .trailing
                )
            }

            // Vertical frequency grid lines
            for hz: Float in [100, 1000, 10000] {
                let x = xForT(tForHz(hz))
                var vln = Path()
                vln.move(to: CGPoint(x: x, y: pad.t))
                vln.addLine(to: CGPoint(x: x, y: pad.t + iH))
                ctx.stroke(vln,
                           with: .color(.white.opacity(0.05)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5]))
            }

            // Frequency labels at bottom
            let freqLabels: [(Float, String)] = [
                (20, "20"), (100, "100"), (1000, "1k"), (10000, "10k"), (20000, "20k")
            ]
            for (hz, label) in freqLabels {
                let x = xForT(tForHz(hz))
                ctx.draw(
                    Text(label)
                        .font(.system(size: 6, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.30)),
                    at: CGPoint(x: x, y: size.height - 3),
                    anchor: .bottom
                )
            }

            // EQ + HP/LP filter response
            let N = 80
            var pts = [CGPoint]()
            for i in 0..<N {
                let t = Float(i) / Float(N - 1)
                var total = preamp

                for (b, gain) in bands.enumerated() {
                    let ct   = tForHz(bandFreqs[b])
                    let dist = t - ct
                    total += gain * exp(-(dist * dist) / 0.012)
                }

                let freq = powf(10.0, logFmin + (logFmax - logFmin) * t)
                if hpfCut > 0.015 {
                    let fc = 20.0 * powf(100.0, hpfCut)
                    let r = freq / fc; let r4 = r * r * r * r
                    total += 10.0 * log10(max(1e-12, r4 / (1.0 + r4)))
                }
                if lpfCut > 0.015 {
                    let fc = 20000.0 * powf(0.01, lpfCut)
                    let r = freq / fc; let r4 = r * r * r * r
                    total += -10.0 * log10(1.0 + r4)
                }

                pts.append(CGPoint(x: xForT(t), y: yFor(max(-dbMax, min(dbMax, total)))))
            }
            guard pts.count > 1 else { return }

            func catmullControls(_ i: Int) -> (CGPoint, CGPoint) {
                let p0 = pts[max(0, i - 1)], p1 = pts[i]
                let p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                return (c1, c2)
            }

            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
            fill.addLine(to: pts[0])
            for i in 0..<pts.count - 1 {
                let (c1, c2) = catmullControls(i)
                fill.addCurve(to: pts[i + 1], control1: c1, control2: c2)
            }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(.white.opacity(0.06)))

            var curve = Path()
            curve.move(to: pts[0])
            for i in 0..<pts.count - 1 {
                let (c1, c2) = catmullControls(i)
                curve.addCurve(to: pts[i + 1], control1: c1, control2: c2)
            }
            ctx.stroke(curve,
                       with: .color(.white.opacity(0.92)),
                       style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))

            // Band control dots
            for (b, gain) in bands.enumerated() {
                let t = tForHz(bandFreqs[b])
                let x = xForT(t)

                var totalAtBand = preamp
                for (b2, g2) in bands.enumerated() {
                    let ct = tForHz(bandFreqs[b2]); let dist = t - ct
                    totalAtBand += g2 * exp(-(dist * dist) / 0.012)
                }
                let freq = bandFreqs[b]
                if hpfCut > 0.015 {
                    let fc = 20.0 * powf(100.0, hpfCut); let r = freq / fc; let r4 = r*r*r*r
                    totalAtBand += 10.0 * log10(max(1e-12, r4 / (1.0 + r4)))
                }
                if lpfCut > 0.015 {
                    let fc = 20000.0 * powf(0.01, lpfCut); let r = freq / fc; let r4 = r*r*r*r
                    totalAtBand += -10.0 * log10(1.0 + r4)
                }

                let y = yFor(max(-dbMax, min(dbMax, totalAtBand)))
                let isActive = abs(gain) > 0.5
                let outerR: CGFloat = isActive ? 3.2 : 2.0
                let innerR: CGFloat = isActive ? 1.5 : 0.8

                ctx.stroke(
                    Path(ellipseIn: CGRect(x: x - outerR, y: y - outerR,
                                          width: outerR * 2, height: outerR * 2)),
                    with: .color(.white.opacity(isActive ? 0.55 : 0.18)),
                    lineWidth: 0.75
                )
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x - innerR, y: y - innerR,
                                          width: innerR * 2, height: innerR * 2)),
                    with: .color(.white.opacity(isActive ? 0.95 : 0.28))
                )
            }
        }
        .background(Color.black.opacity(0.45))
        .overlay(
            RoundedRectangle(cornerRadius: G.rBadge)
                .stroke(G.borderSubtle, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
        .onChange(of: state.eqBands) { _, newBands in
            animateTo(bands: newBands, preamp: displayedPreamp)
        }
        .onChange(of: state.eqPreamp) { _, newPreamp in
            animateTo(bands: displayedBands, preamp: newPreamp)
        }
        .onAppear {
            displayedBands  = state.eqBands
            displayedPreamp = state.eqPreamp
        }
    }

    private func animateTo(bands target: [Float], preamp targetPre: Float) {
        animTask?.cancel()
        let fromBands = displayedBands
        let fromPre   = displayedPreamp
        animTask = Task { @MainActor in
            let steps = 11
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                let t    = Double(i) / Double(steps)
                let ease = 1.0 - pow(1.0 - t, 3.0)
                displayedBands  = zip(fromBands, target).map { a, b in a + Float(ease) * (b - a) }
                displayedPreamp = fromPre + Float(ease) * (targetPre - fromPre)
            }
        }
    }
}
