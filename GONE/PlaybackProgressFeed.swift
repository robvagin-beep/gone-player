import Combine

@MainActor
final class PlaybackProgressFeed: ObservableObject {
    static let shared = PlaybackProgressFeed()
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    init() {}

    func reset() {
        progress = 0
        currentTime = 0
    }
}
