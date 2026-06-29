import Foundation

// On-disk cache for BPM + waveform analysis results.
// Eliminates re-analysis on relaunch — second launch of the same library populates
// BPM column in <200 ms regardless of size.
//
// Keyed by (standardized path, file size, mtime) so external re-encodes invalidate.
// Stored as a single JSON file in Application Support/GONE/analysis-cache.json.
// Writes are coalesced — flushSoon debounces to 1.5s after the last mutation.

struct AnalysisCacheEntry: Codable {
    var bpm: Double
    var waveform: [Float]
    var beatGridOffset: Double
    var beatGridConfidence: Double
    var size: Int64
    var mtime: TimeInterval
    var analyzerVersion: Int
    var lastAccessed: Date?
}

actor AnalysisCache {
    static let shared = AnalysisCache()
    private static let version = 6  // v6: half-tempo threshold 0.60→0.82 (reduces double-BPM on slow electronic)
    private static let maxEntries = 20_000

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
            // Purge + LRU-cap run as the actor's first job — init is nonisolated and can't call
            // isolated methods synchronously. Housekeeping a beat late is harmless: lookups are
            // awaited and queue behind this job; a stale entry for a missing file fails its own
            // file-existence check anyway.
            Task { await self.purgeAndCapAfterLoad() }
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
        var touched = entry
        touched.lastAccessed = Date()
        map[f.key] = touched
        dirty = true
        Task { await flushSoon() }
        return touched
    }

    func putBPMAndWaveform(url: URL, bpm: Double, waveform: [Float],
                           beatGridOffset: Double = 0, beatGridConfidence: Double = 0) {
        guard let f = fileKey(for: url) else { return }
        map[f.key] = AnalysisCacheEntry(
            bpm: bpm, waveform: waveform,
            beatGridOffset: beatGridOffset,
            beatGridConfidence: beatGridConfidence,
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version,
            lastAccessed: Date()
        )
        enforceLRUCap()
        dirty = true
        Task { await flushSoon() }
    }

    func putBPM(url: URL, bpm: Double) {
        guard let f = fileKey(for: url) else { return }
        let existing = map[f.key]
        map[f.key] = AnalysisCacheEntry(
            bpm: bpm,
            waveform: existing?.waveform ?? [],
            beatGridOffset: existing?.beatGridOffset ?? 0,
            beatGridConfidence: existing?.beatGridConfidence ?? 0,
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version,
            lastAccessed: Date()
        )
        enforceLRUCap()
        dirty = true
        Task { await flushSoon() }
    }

    func putWaveform(url: URL, waveform: [Float]) {
        guard let f = fileKey(for: url) else { return }
        let existing = map[f.key]
        map[f.key] = AnalysisCacheEntry(
            bpm: existing?.bpm ?? 0,
            waveform: waveform,
            beatGridOffset: existing?.beatGridOffset ?? 0,
            beatGridConfidence: existing?.beatGridConfidence ?? 0,
            size: f.size, mtime: f.mtime,
            analyzerVersion: Self.version,
            lastAccessed: Date()
        )
        enforceLRUCap()
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
        // Serialized inside actor so two flushSoon completions cannot race on the file.
        // JSON encode + atomic write briefly blocks the actor but guarantees write ordering.
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func purgeMissingFiles() {
        let before = map.count
        map = map.filter { FileManager.default.fileExists(atPath: $0.key) }
        if map.count != before { dirty = true }
    }

    private func enforceLRUCap() {
        guard map.count > Self.maxEntries else { return }
        let overflow = map.count - Self.maxEntries
        let victims = map
            .sorted {
                ($0.value.lastAccessed ?? Date(timeIntervalSince1970: $0.value.mtime)) <
                ($1.value.lastAccessed ?? Date(timeIntervalSince1970: $1.value.mtime))
            }
            .prefix(overflow)
            .map(\.key)
        for key in victims { map.removeValue(forKey: key) }
        dirty = true
    }

    private func purgeAndCapAfterLoad() async {
        purgeMissingFiles()
        enforceLRUCap()
        if dirty { await flushSoon() }
    }
}
