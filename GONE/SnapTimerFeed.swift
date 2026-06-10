import Combine
import Foundation

// Isolated feed for the snap inactivity countdown start time.
// WindowSnapManager rewrites this on every user-activity event (including mouse moves
// inside the window), so it must NOT live as @Published on PlayerState — that broadcast
// re-diffed the entire window tree at mouse-move rate. Only SnapTimerBtn observes this.
@MainActor
final class SnapTimerFeed: ObservableObject {
    @Published private(set) var start: Date?

    func set(_ date: Date?) {
        guard start != date else { return }
        start = date
    }
}
