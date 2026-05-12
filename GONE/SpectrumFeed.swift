import Combine

@MainActor
final class SpectrumFeed: ObservableObject {
    @Published var data: [Float] = Array(repeating: 0, count: 28)
    init() {}

    func reset() {
        data = Array(repeating: 0, count: 28)
    }
}
