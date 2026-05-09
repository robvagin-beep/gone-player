import Combine

final class SpectrumFeed: ObservableObject {
    static let shared = SpectrumFeed()
    @Published var data: [Float] = Array(repeating: 0, count: 28)
    private init() {}

    func reset() {
        data = Array(repeating: 0, count: 28)
    }
}
