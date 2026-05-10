import SwiftUI

struct PitchFaderView: View {
    @EnvironmentObject var state: PlayerState

    var body: some View {
        VStack(spacing: 0) {
            // Top buttons — F (BPM filter) + ⏻ (bypass)
            HStack(spacing: 0) {
                PitchRailSectionButton(
                    title: "≈",
                    fontSize: 12,
                    contentOffset: -1,
                    active: state.bpmFilterOn,
                    action: {
                        guard !state.tracks.isEmpty else { return }
                        state.bpmFilterOn.toggle()
                        if state.bpmFilterOn {
                            if let current = state.current { state.applyBPMFilter(to: current) }
                        } else {
                            state.pitch = 0
                            state.audioEngine.setPitch(0, masterTempo: state.masterTempo)
                        }
                    }
                )
                .goneTooltip("BPM Fit — shifts tempo to match a target BPM range")

                Rectangle()
                    .fill(G.borderSubtle.opacity(0.8))
                    .frame(width: 1)

                PitchRailSectionButton(
                    title: "R",
                    symbolName: state.pitchBypassed ? "circle.fill" : "circle",
                    fontSize: 6.5,
                    activeBackgroundOpacity: 0.22,
                    contentOffset: -0.5,
                    active: state.pitchBypassed,
                    action: {
                        guard !state.tracks.isEmpty else { return }
                        state.pitchBypassed.toggle()
                        if state.pitchBypassed {
                            state.audioEngine.setPitch(0, masterTempo: state.masterTempo)
                        } else {
                            state.audioEngine.setPitch(state.pitch, masterTempo: state.masterTempo)
                        }
                    }
                )
                .goneTooltip("Bypass pitch shift — plays at original tempo")
            }
            .frame(height: 20)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(G.borderSubtle.opacity(0.8))
                    .frame(height: 1)
            }

            // Fader area — pitch offset or BPM range selector
            if state.bpmFilterOn {
                BPMRangeTrack(
                    low: Binding(
                        get: { state.bpmFilterLow },
                        set: { v in
                            state.bpmFilterLow = v
                            if let current = state.current { state.applyBPMFilter(to: current) }
                        }
                    ),
                    high: Binding(
                        get: { state.bpmFilterHigh },
                        set: { v in
                            state.bpmFilterHigh = v
                            if let current = state.current { state.applyBPMFilter(to: current) }
                        }
                    )
                )
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .opacity(state.pitchBypassed ? 0.28 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: state.pitchBypassed)
                .goneTooltip("Drag handles to set the target BPM range. Double-click to reset to 90–120")
            } else {
                VerticalPitchTrack(
                    value: Binding(
                        get: { state.pitch },
                        set: { state.pitch = $0 }
                    ),
                    range: Double(state.pitchRange),
                    onCommit: { v in
                        if !state.pitchBypassed {
                            state.audioEngine.setPitch(v, masterTempo: state.masterTempo)
                        }
                    }
                )
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .opacity(state.pitchBypassed ? 0.28 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: state.pitchBypassed)
                .goneTooltip("Tempo fader — drag to speed up or slow down. Double-click to reset to 0%")
            }

            // Bottom buttons — range + MT
            HStack(spacing: 0) {
                PitchRailSectionButton(
                    title: "±\(state.pitchRange == 100 ? "100" : "\(state.pitchRange)")",
                    fontSize: 8,
                    xOffset: 1,
                    active: false,
                    action: { state.cyclePitchRange() }
                )
                .goneTooltip("Fader range — ±8 fine-tuning, ±16 medium, ±100 extreme")

                Rectangle()
                    .fill(G.borderSubtle.opacity(0.8))
                    .frame(width: 1)

                PitchRailSectionButton(
                    title: "MT",
                    fontSize: 7,
                    active: state.masterTempo,
                    action: {
                        guard !state.tracks.isEmpty else { return }
                        state.masterTempo.toggle()
                        state.audioEngine.setPitch(state.pitch, masterTempo: state.masterTempo)
                    }
                )
                .goneTooltip("Master Tempo — pitch stays locked to original key when you change speed")
            }
            .frame(height: 20)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(G.borderSubtle.opacity(0.8))
                    .frame(height: 1)
            }
            .opacity(state.pitchBypassed && !state.bpmFilterOn ? 0.28 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: state.pitchBypassed)
        }
        .frame(width: G.pitchRailWidth)
        .background(G.bgPitchRail)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(G.borderDefault)
                .frame(width: 1)
        }
    }
}

private struct PitchRailSectionButton: View {
    let title: String
    var symbolName: String? = nil
    var fontSize: CGFloat = 9
    var activeBackgroundOpacity: Double = 0.12
    var contentOffset: CGFloat = 0
    var xOffset: CGFloat = 0
    let active: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let sym = symbolName {
                    Image(systemName: sym)
                        .font(.system(size: fontSize, weight: .medium))
                } else {
                    Text(title)
                        .font(G.sans(fontSize, weight: .light))
                        .tracking(0.3)
                }
            }
            .offset(x: xOffset, y: contentOffset)
            .foregroundStyle(active ? Color.white.opacity(0.92) : Color.white.opacity(0.42))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                active
                ? G.accentPrimary.opacity(activeBackgroundOpacity)
                : (hovered ? Color.white.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// ── BPM range selector — candlestick style ─────────────────────────────────────
private struct BPMRangeTrack: View {
    @Binding var low: Double
    @Binding var high: Double

    static let bpmFloor: Double = 70
    static let bpmCeil:  Double = 170

    enum Handle { case low, high }
    @State private var active: Handle? = nil
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartBPM: Double = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let inset: CGFloat = 4
            let knobHalf: CGFloat = 7
            let travel = h - inset * 2 - knobHalf * 2

            let yFor: (Double) -> CGFloat = { bpm in
                let t = CGFloat((bpm - Self.bpmFloor) / (Self.bpmCeil - Self.bpmFloor))
                return (1 - t) * travel + inset + knobHalf
            }

            let yHigh = yFor(high)
            let yLow  = yFor(low)
            let bodyH  = max(0, yLow - yHigh)
            let bodyMid = (yHigh + yLow) / 2

            ZStack {
                // Spine
                Canvas { ctx, size in
                    let cx = size.width / 2
                    var spine = Path()
                    spine.move(to:    CGPoint(x: cx, y: 0))
                    spine.addLine(to: CGPoint(x: cx, y: size.height))
                    ctx.stroke(spine, with: .color(Color(hex: "#242424")),
                               style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Candle body between handles
                Rectangle()
                    .fill(G.accentPrimary.opacity(0.10))
                    .frame(width: 18, height: bodyH)
                    .offset(y: bodyMid - h / 2)

                // High knob — shows max BPM value
                BPMKnob(value: high)
                    .offset(y: yHigh - h / 2)

                // Low knob — shows min BPM value
                BPMKnob(value: low)
                    .offset(y: yLow - h / 2)


            }
            .overlay(alignment: .topLeading) {
                Text("\(Int(Self.bpmCeil))")
                    .font(G.mono(6.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.14))
                    .offset(x: -7)
                    .padding(.top, 4)
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(Int(Self.bpmFloor))")
                    .font(G.mono(6.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.14))
                    .offset(x: -7)
                    .padding(.bottom, 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if active == nil {
                            let dh = abs(g.startLocation.y - yHigh)
                            let dl = abs(g.startLocation.y - yLow)
                            active = dh <= dl ? .high : .low
                            dragStartY = g.startLocation.y
                            dragStartBPM = active == .high ? high : low
                        }
                        let dy = g.location.y - dragStartY
                        let bpmPerPx = (Self.bpmCeil - Self.bpmFloor) / Double(max(1, travel))
                        let newBPM = (dragStartBPM - Double(dy) * bpmPerPx).rounded()
                        switch active {
                        case .high: high = max(low + 5, min(Self.bpmCeil, newBPM))
                        case .low:  low  = max(Self.bpmFloor, min(high - 5, newBPM))
                        case .none: break
                        }
                        let displayVal = active == .high ? high : low
                        DragValuePanel.shared.show(text: "\(Int(displayVal.rounded())) BPM")
                    }
                    .onEnded { _ in active = nil; DragValuePanel.shared.hide() }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { high = 120; low = 90 }
            )
            .cursor(NSCursor.resizeUpDown)
        }
    }
}

// ── BPM knob — shows value, edge lines ────────────────────────────────────────
private struct BPMKnob: View {
    let value: Double

    var body: some View {
        RoundedRectangle(cornerRadius: G.rFaderKnob)
            .fill(Color(hex: "#484848"))
            .overlay(
                ZStack {
                    HStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.30))
                            .frame(width: 3, height: 1.5)
                        Spacer()
                        Rectangle()
                            .fill(Color.white.opacity(0.30))
                            .frame(width: 3, height: 1.5)
                    }
                    Text("\(Int(value.rounded()))")
                        .font(G.mono(6.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .monospacedDigit()
                }
            )
            .frame(width: 26, height: 14)
    }
}

// ── Vertical pitch fader ───────────────────────────────────────────────────────
struct VerticalPitchTrack: View {
    @Binding var value: Double
    let range: Double
    var onCommit: ((Double) -> Void)? = nil

    @State private var lastCommit: Date = .distantPast
    private let commitThrottle: TimeInterval = 0.016

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let trackInset: CGFloat = 4
            let knobHalfHeight: CGFloat = 7
            let travelHeight = h - trackInset * 2 - knobHalfHeight * 2
            let pos = (1 - (value + range) / (range * 2)) * travelHeight + trackInset + knobHalfHeight

            ZStack {
                Canvas { ctx, size in
                    let color = Color(hex: "#242424")
                    let cx = size.width / 2
                    let tickMargin: CGFloat = 9

                    var spine = Path()
                    spine.move(to:    CGPoint(x: cx, y: 0))
                    spine.addLine(to: CGPoint(x: cx, y: size.height))
                    ctx.stroke(spine, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))

                    for i in 1...5 {
                        let ty = size.height * CGFloat(i) / 6.0
                        let isCenter = i == 3
                        let margin: CGFloat = isCenter ? 2 : tickMargin
                        let tickColor = isCenter ? Color(hex: "#383838") : color
                        var path = Path()
                        path.move(to:    CGPoint(x: margin, y: ty))
                        path.addLine(to: CGPoint(x: size.width - margin, y: ty))
                        ctx.stroke(path, with: .color(tickColor),
                                   style: StrokeStyle(lineWidth: 1.0, lineCap: .butt))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                RoundedRectangle(cornerRadius: G.rFaderKnob)
                    .fill(Color(hex: "#484848"))
                    .overlay(
                        Rectangle()
                            .fill(abs(value) < 0.001
                                ? Color.white.opacity(0.22)
                                : Color.white.opacity(0.80))
                            .frame(height: 1)
                    )
                    .frame(width: 26, height: 14)
                    .offset(y: pos - h / 2)

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // Absolute: click/drag anywhere maps directly to a fader value
                        let trackTop    = trackInset + knobHalfHeight
                        let trackBottom = h - trackInset - knobHalfHeight
                        let clampedY    = max(trackTop, min(trackBottom, g.location.y))
                        let t = (clampedY - trackTop) / max(1, travelHeight) // 0=top(+range) 1=bottom(-range)
                        var v = range - t * range * 2
                        if abs(v) < 0.3 { v = 0 }
                        value = max(-range, min(range, (v * 100).rounded() / 100))
                        let now = Date()
                        guard now.timeIntervalSince(lastCommit) >= commitThrottle else { return }
                        lastCommit = now
                        onCommit?(value)
                        let label = abs(value) < 0.001 ? "±0.0%" : String(format: "%+.1f%%", value)
                        DragValuePanel.shared.show(text: label)
                    }
                    .onEnded { _ in
                        DragValuePanel.shared.hide()
                        onCommit?(value)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { value = 0; onCommit?(0) }
            )
            .cursor(NSCursor.resizeUpDown)
        }
    }
}
