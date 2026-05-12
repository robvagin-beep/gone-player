import Combine

@MainActor
final class PlaybackProgressFeed: ObservableObject {
    static let shared = PlaybackProgressFeed()
    private(set) var progress: Double = 0
    private(set) var currentTime: Double = 0
    init() {}

    func update(progress p: Double, currentTime t: Double) {
        progress = p
        currentTime = t
        objectWillChange.send()
    }

    func reset() {
        update(progress: 0, currentTime: 0)
    }
}
