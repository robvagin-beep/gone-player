import Foundation
import Combine

// Per-player BPM scan progress, isolated from PlayerState so writes during
// background analysis don't broadcast PlayerState.objectWillChange to the full tree.
@MainActor
final class AnalysisProgressFeed: ObservableObject {
    @Published var progress: [UUID: Double] = [:]
}
