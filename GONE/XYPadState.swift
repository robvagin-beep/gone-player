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
