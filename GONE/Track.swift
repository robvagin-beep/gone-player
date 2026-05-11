import Foundation

enum BPMAnalysisState: Equatable {
    case pending
    case analyzing
    case analyzed
    case failed
}

struct Track: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double          // seconds
    var bpm: Double               // 0 if unknown
    var key: String               // "8A", "—"
    var format: String            // "FLAC", "MP3", "WAV", "AIFF", "AAC"
    var bitrate: Int              // kbps; 0 if lossless (use sampleRate instead)
    var sampleRate: Double        // Hz
    var rating: Int               // 0–5
    var hasArtwork: Bool           // true when ArtworkCache has an image for this id
    var waveform: [Float]         // 84 bars, computed async
    var isMissing: Bool           // file not found at url
    var bpmAnalysisState: BPMAnalysisState
    var beatGridOffset: Double = 0      // seconds; 0 = fallback (phase not yet detected)
    var beatGridConfidence: Double = 0  // 0 = no analysis, 1 = high confidence

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

extension Track {
    var displayBitrate: String {
        if bitrate > 0 { return "\(bitrate)" }
        if format == "FLAC" || format == "WAV" || format == "AIFF" { return "lossless" }
        return "—"
    }

    var formattedDuration: String { fmtTime(duration) }
}
