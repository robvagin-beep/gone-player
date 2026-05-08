import Foundation

extension PlayerState {

    static let eqPresets: [String: [Float]] = [
        "Flat":       [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Techno":     [5, 4, 2, -1, -3, -3, -1, 2, 4, 5],
        "Tech House": [3, 3, 2,  0, -1, -1,  0, 2, 3, 3],
        "House":      [4, 4, 3,  2,  0,  0,  1, 2, 2, 3],
        "D&B":        [7, 6, 3, -1, -3, -2,  1, 3, 5, 6],
        "Bass":       [8, 7, 5,  1, -2, -3,  0, 1, 2, 2],
        "Ambient":    [1, 1, 2,  2,  2,  2,  3, 4, 5, 5],
    ]

    static let reverbPresets = ["Room", "Hall", "Plate", "Chamber"]

    func applyPreset(_ name: String) {
        guard let values = Self.eqPresets[name] else { return }
        eqPreset = name
        eqBands = values
    }

    func cycleReverbPreset() {
        let idx = Self.reverbPresets.firstIndex(of: reverbPreset) ?? 0
        reverbPreset = Self.reverbPresets[(idx + 1) % Self.reverbPresets.count]
        AudioEngineNext.shared.setReverbPreset(reverbPreset)
    }
}
