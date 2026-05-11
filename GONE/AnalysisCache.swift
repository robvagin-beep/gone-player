import Foundation

// On-disk cache for BPM + waveform analysis results.
// Eliminates re-analysis on relaunch — second launch of the same library populates
// BPM column in <200 ms regardless of size.
//
// Keyed by (standardized path, file size, mtime) so external re-encodes invalidate.
// Stored as a single JSON file in Application Support/GONE/analysis-cache.json.
// Writes are coalesced — flushSoon debounces to 1.5s after the last mutation.

struct AnalysisCacheEntry: Codable {
    let bpm: Double
    let waveform: [Float]
    let size: Int64
    let mtime: TimeInterval
    let analyzerVersion: Int
}

actor AnalysisCache {
    static let shared = AnalysisCache()
    private static let version = 1  // bump when BPM / waveform algorithm changes

    private var map: [String: AnalysisCacheEntry] = [:]
    private let fileURL: URL
    private var dirty = false
    private var flushPending = false

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("GONE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("analysis-cache.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: AnalysisCacheEntry].self, from: data) {
            // Drop entries from older algorithm versions on load — cheaper than scanning at lookup.
            self.map = decoded.filter { $0.value.analyzerVersion == Self.version }
        }
    }

    private nonisolated func fileKey(for url: URL) -> (key: String, size: Int64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        return (url.standardized.path, size, mtime)
    }

    func get(for url: URL) -> AnalysisCacheEntry? {
        guard let f = fileKey(for: url), let entry = map[f.key],
              entry.size == f.size, abs(entry.mtime - f.mtime) < 1.0
        else { return nil }
        return entry
    }

    func putBPMAndWaveform(url: URL, bpm: Double, waveform: [Float]) {
        guard let f = fileKey(for: url) else { return }
        map[f.key] = AnalysisCacheEntry(
            bpm: bpm, waveform: waveform,
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version
        )
        dirty = true
        Task { await flushSoon() }
    }

    func putBPM(url: URL, bpm: Double) {
        guard let f = fileKey(for: url) else { return }
        let existing = map[f.key]
        map[f.key] = AnalysisCacheEntry(
            bpm: bpm,
            waveform: existing?.waveform ?? [],
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version
        )
        dirty = true
        Task { await flushSoon() }
    }

    func putWaveform(url: URL, waveform: [Float]) {
        guard let f = fileKey(for: url) else { return }
        let existing = map[f.key]
        map[f.key] = AnalysisCacheEntry(
            bpm: existing?.bpm ?? 0,
            waveform: waveform,
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version
        )
        dirty = true
        Task { await flushSoon() }
    }

    func flushNow() {
        guard dirty else { return }
        dirty = false
        flushPending = false
        let snapshot = map
        let url = fileURL
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func flushSoon() async {
        guard !flushPending else { return }
        flushPending = true
        try? await Task.sleep(for: .milliseconds(1500))
        flushPending = false
        guard dirty else { return }
        dirty = false
        let snapshot = map
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
