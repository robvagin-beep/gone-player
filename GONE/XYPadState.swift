import SwiftUI
import Combine

// Isolated ObservableObject for XY pad interaction state.
// Extracted from PlayerState so 60Hz writes during drag/spring don't
// propagate PlayerState.objectWillChange to the full view tree.
@MainActor
final class XYPadState: ObservableObject {
    @Published var point: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var holdMode = false
    @Published var active = false
    @Published var effectAxis: PlayerState.XYEffectAxis = .filter
}

extension PlayerState {
    func bindXYPadSideEffectsIfNeeded() {
        guard xyBridgeCancellables.isEmpty else { return }

        xyPad.$point
            .dropFirst()
            .sink { [weak self] point in
                guard let self, self.xyPad.active else { return }
                self.applyXYEffect(point)
            }
            .store(in: &xyBridgeCancellables)

        xyPad.$active
            .dropFirst()
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    self.cancelXYSpring()
                    self.startActiveXYTimerIfNeeded()
                    self.applyXYEffect(self.xyPad.point)
                } else {
                    self.resetXYEffectAndSpringBack()
                }
            }
            .store(in: &xyBridgeCancellables)

        xyPad.$effectAxis
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.stopLFO()
                self.stopBPMChop()
                self.stopSlicer()
                self.audioEngine.setHPF(cutoff: 0)
                self.audioEngine.setLPF(cutoff: 0)
                self.audioEngine.resetFXNodes()
                self.lpfCutoff = 0
                guard self.xyPad.active else { return }
                self.startActiveXYTimerIfNeeded()
                self.applyXYEffect(self.xyPad.point)
            }
            .store(in: &xyBridgeCancellables)

        xyPad.$holdMode
            .dropFirst()
            .sink { [weak self] holdMode in
                guard let self, !holdMode, self.xyPad.active else { return }
                self.startXYSpring {
                    self.xyPad.active = false
                }
            }
            .store(in: &xyBridgeCancellables)
    }

    private func startActiveXYTimerIfNeeded() {
        if xyPad.effectAxis == .lfo     { startLFO() }
        if xyPad.effectAxis == .bpmChop { startBPMChop() }
        if xyPad.effectAxis == .slicer  { startSlicer() }
    }

    private func resetXYEffectAndSpringBack() {
        stopLFO()
        stopBPMChop()
        stopSlicer()
        cancelXYSpring()
        hpfCutoff    = 0
        lpfCutoff    = 0
        reverbAmount = 0
        xyResonance  = 1.0
        audioEngine.setHPF(cutoff: 0)
        audioEngine.setLPF(cutoff: 0)
        audioEngine.setLPFResonance(1.0)
        audioEngine.setReverb(amount: 0)
        audioEngine.resetFXNodes()
        startXYSpring()
    }

    // Perceptual wet curve. The ear hears the first few percent of reverb/delay/crush
    // loudest, so a linear pad mapping made 0.1 sound already "fully on" (tester
    // feedback). Quadratic keeps the top end intact and turns the lower third of the
    // pad into a fine-control zone. Frequencies and feedback stay linear.
    private func wetCurve(_ v: Float) -> Float { v * v }

    private func applyXYEffect(_ point: CGPoint) {
        let x = Float(point.x)
        let y = Float(point.y)

        switch xyPad.effectAxis {
        case .filter:
            audioEngine.setHPF(cutoff: x * 0.55)
            audioEngine.setLPF(cutoff: (1 - y) * 0.55)
            audioEngine.setLPFResonance(1.0)
        case .lowpass:
            let bw = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPF(cutoff: x * 0.85)
            audioEngine.setLPFResonance(bw)
        case .highpass:
            let bw = Float(max(0.05, 2.0 * pow(0.025, Double(y))))
            audioEngine.setLPF(cutoff: 0)
            audioEngine.setHPF(cutoff: x * 0.85)
            audioEngine.setHPFResonance(bw)
        case .bandpass:
            let centerHz = 100.0 * pow(80.0, Double(x))
            let widthOct = 0.5 + (1.0 - Double(y)) * 3.0
            let hpfHz    = centerHz / pow(2.0, widthOct * 0.5)
            let lpfHz    = centerHz * pow(2.0, widthOct * 0.5)
            audioEngine.setHPF(cutoff: Float(max(0, min(1, log(max(20, hpfHz) / 20.0) / log(100.0)))))
            audioEngine.setLPF(cutoff: Float(max(0, min(1, log(20000.0 / max(200, lpfHz)) / log(100.0)))))
            audioEngine.setLPFResonance(1.0)
        case .reso:
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPF(cutoff: x * 0.75)
            audioEngine.setLPFResonance(Float(max(0.05, 2.0 * pow(0.025, Double(y)))))
        case .lfo:
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPFResonance(1.0)
            startLFO()
        case .bpmChop:
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPFResonance(1.0)
            startBPMChop()
        case .slicer:
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPF(cutoff: 0)
            startSlicer()
        case .reverb:
            audioEngine.setReverb(amount: wetCurve(x))
        case .filtVerb:
            audioEngine.setHPF(cutoff: 0)
            audioEngine.setLPF(cutoff: x * 0.7)
            audioEngine.setLPFResonance(1.0)
            audioEngine.setReverb(amount: wetCurve(y))
        case .simpleDelay:
            let time     = Double(x) * 1.0
            let feedback = y * 0.75
            let wet      = min(1.0, wetCurve(y) * 1.5)
            audioEngine.setDelay(time: time, feedback: feedback, wet: wet)
        case .dubDelay:
            let time      = Double(x) * 0.75
            let feedback  = y * 0.65
            let wet       = min(1.0, wetCurve(y) * 1.2)
            let darkness  = Float(max(200, 22050.0 * pow(0.005, Double(y))))
            audioEngine.setDelay(time: time, feedback: feedback, wet: wet, lowPassCutoff: darkness)
        case .lofi:
            audioEngine.setLoFi(wet: wetCurve(x * y))
        }
    }
}
