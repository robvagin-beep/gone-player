import Foundation

extension PlayerState {

    // Concurrency cap for BPM + waveform analysis pipelines.
    // Decode is moderately I/O bound; running cores-2 leaves headroom for UI thread
    // and Swift cooperative pool. Floor at 2 so weaker machines still parallelize.
    nonisolated static let analysisConcurrency: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(2, min(8, cores - 2))
    }()

    // MARK: — Public entry points

    func reanalyzeBPM(for trackId: UUID) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        tracks[idx].bpmAnalysisState = .pending
        scheduleBPMAnalysis()
    }

    // Deep re-analysis: wider BPM range (30–280) + longer window + half-tempo correction.
    // Only triggered by explicit user action (clicking the BPM refresh badge).
    func reanalyzeBPMDeep(for trackId: UUID) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        let track = tracks[idx]
        guard !track.isMissing else { return }

        tracks[idx].bpmAnalysisState = .analyzing

        let floor   = bpmAnalysisFloor
        let ceiling = bpmAnalysisCeiling

        Task.detached(priority: .userInitiated) { [self] in
            let bpm = await LibraryScanner().analyzeBPMDeep(
                url: track.url, floor: floor, ceiling: ceiling
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.analysisFeed.progress[trackId] = progress
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.analysisFeed.progress.removeValue(forKey: trackId)
                guard let i = self.tracks.firstIndex(where: { $0.id == trackId }) else { return }
                if bpm > 0 {
                    self.tracks[i].bpm = bpm
                    self.tracks[i].bpmAnalysisState = .analyzed
                    // BPM changed → existing offset is invalid against new beat duration.
                    // Zero confidence so WaveformView falls back to safe (uniform) grid
                    // until a combined analysis pass recomputes the offset.
                    self.tracks[i].beatGridOffset = 0
                    self.tracks[i].beatGridConfidence = 0
                } else {
                    self.tracks[i].bpmAnalysisState = .failed
                }
            }
        }
    }

    // Triggers BPM + waveform for the current track, then schedules the rest.
    func scheduleCurrentTrackAnalysis() {
        guard let current = current, !current.isMissing else { return }
        scheduleBPMAnalysis()
        scheduleWaveformComputation(currentOnly: true)
    }

    // MARK: — BPM analysis

    func scheduleBPMAnalysis() {
        // If already running, signal priority for the new current track.
        // The running loop picks this up between batches (≤200 ms lag).
        if isAnalyzingBPM {
            bpmPriorityId = currentId
            return
        }

        var pending = tracks.filter {
            !$0.isMissing && $0.bpmAnalysisState == .pending
        }
        guard !pending.isEmpty else { return }

        // Current track always goes first.
        if let currentId { pending.sort { a, _ in a.id == currentId } }

        isAnalyzingBPM = true
        bpmPriorityId = nil

        // Mark all as .analyzing upfront so progress bars appear immediately.
        let pendingIds = Set(pending.map(\.id))
        for i in tracks.indices where pendingIds.contains(tracks[i].id) { tracks[i].bpmAnalysisState = .analyzing }

        Task.detached(priority: .userInitiated) { [self] in
            // Wait out any active import — competing AVAssetReaders freeze the UI.
            while await MainActor.run(body: { self.isImporting }) {
                try? await Task.sleep(for: .milliseconds(300))
            }

            // Lane 1: current track alone, high priority — user sees BPM + beat grid first.
            // No other analysis competes during this phase.
            let first = pending[0]
            await Self.analyzeBPMAndCommit(track: first, state: self)

            // Brief pause: let playback settle before batch analysis competes for disk I/O.
            // At 2 concurrent AVAssetReaders, seek + playback stutter is measurable.
            // This 1.5s gap costs nothing perceptible but keeps the first beat lag-free.
            if pending.count > 1 {
                try? await Task.sleep(for: .milliseconds(1500))
            }

            // Lane 2: background batch — capped at 2 concurrent to avoid I/O contention
            // with ongoing playback. Priority lowered to .utility so the OS scheduler
            // deprioritizes analysis reads vs audio engine writes.
            let batchConcurrency = min(2, Self.analysisConcurrency)
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                let priorityId = await MainActor.run { self.bpmPriorityId ?? self.currentId }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.bpmPriorityId = nil }

                let batch = Array(queue.prefix(batchConcurrency * 2))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(batchConcurrency, q.count) {
                        let track = q.removeFirst()
                        group.addTask(priority: .utility) {
                            await Self.analyzeBPMAndCommit(track: track, state: self)
                        }
                    }
                    while await group.next() != nil, !q.isEmpty {
                        let track = q.removeFirst()
                        group.addTask(priority: .utility) {
                            await Self.analyzeBPMAndCommit(track: track, state: self)
                        }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAnalyzingBPM = false
                self.bpmPriorityId = nil
                let hasMore = self.tracks.contains {
                    !$0.isMissing && $0.bpmAnalysisState == .pending
                }
                if hasMore { self.scheduleBPMAnalysis() }
            }
        }
    }

    private static func analyzeBPMAndCommit(track: Track, state: PlayerState) async {
        // Cache hit: skip decode + analysis entirely. Saves ~300-500 ms per track.
        if let hit = await AnalysisCache.shared.get(for: track.url), hit.bpm > 0 {
            await MainActor.run {
                guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                state.tracks[idx].bpm = hit.bpm
                state.tracks[idx].bpmAnalysisState = .analyzed
                if state.tracks[idx].waveform.isEmpty, !hit.waveform.isEmpty {
                    state.tracks[idx].waveform = hit.waveform
                }
            }
            return
        }

        let floor   = await MainActor.run { state.bpmAnalysisFloor }
        let ceiling = await MainActor.run { state.bpmAnalysisCeiling }
        // Single decode: BPM + waveform + beat grid offset from one AVAssetReader pass.
        let (bpm, waveform, beatGridOffset, gridConfidence) = await LibraryScanner().analyzeBPMWithWaveform(
            url: track.url, floor: floor, ceiling: ceiling, waveformBars: 84
        ) { progress in
            Task { @MainActor [weak state] in
                state?.analysisFeed.progress[track.id] = progress
            }
        }
        if bpm > 0 {
            await AnalysisCache.shared.putBPMAndWaveform(url: track.url, bpm: bpm, waveform: waveform)
        }
        await MainActor.run {
            state.analysisFeed.progress.removeValue(forKey: track.id)
            guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            if bpm > 0 {
                state.tracks[idx].bpm = bpm
                state.tracks[idx].bpmAnalysisState = .analyzed
                state.tracks[idx].beatGridOffset = beatGridOffset
                state.tracks[idx].beatGridConfidence = gridConfidence
                if state.tracks[idx].waveform.isEmpty, !waveform.isEmpty {
                    state.tracks[idx].waveform = waveform
                }
            } else {
                state.tracks[idx].bpmAnalysisState = .failed
            }
        }
    }

    // MARK: — Waveform computation

    func scheduleWaveformComputation(currentOnly: Bool = false) {
        // If already running and current-only request comes in, signal priority.
        if isComputingWaveforms {
            if currentOnly { waveformPriorityId = currentId }
            return
        }

        let pending: [Track]
        if currentOnly, let currentId {
            pending = tracks.filter { $0.id == currentId && !$0.isMissing && $0.waveform.isEmpty }
        } else {
            pending = tracks.filter { !$0.isMissing && $0.waveform.isEmpty }
        }
        guard !pending.isEmpty else { return }

        isComputingWaveforms = true
        waveformPriorityId = nil

        Task.detached(priority: .userInitiated) { [self] in
            // Lane 1: first track (current or head) — computed immediately.
            let first = pending[0]
            await Self.computeWaveformAndCommit(track: first, state: self)

            // Lane 2: background — priority-aware, no artificial batching wall.
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                let priorityId = await MainActor.run { self.waveformPriorityId ?? self.currentId }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.waveformPriorityId = nil }

                let batch = Array(queue.prefix(Self.analysisConcurrency * 2))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(Self.analysisConcurrency, q.count) {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                    while await group.next() != nil, !q.isEmpty {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isComputingWaveforms = false
                self.waveformPriorityId = nil
                let hasMore = self.tracks.contains { !$0.isMissing && $0.waveform.isEmpty }
                if hasMore { self.scheduleWaveformComputation() }
            }
        }
    }

    private static func computeWaveformAndCommit(track: Track, state: PlayerState) async {
        // Cache hit: skip full-track decode entirely.
        if let hit = await AnalysisCache.shared.get(for: track.url), !hit.waveform.isEmpty {
            await MainActor.run {
                guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }),
                      state.tracks[idx].waveform.isEmpty else { return }
                state.tracks[idx].waveform = hit.waveform
            }
            return
        }

        // AVAssetReader doesn't support concurrent reads on the same file.
        // BPM analysis may be reading the same URL simultaneously — retry with backoff.
        var waveform: [Float] = []
        for attempt in 0..<3 {
            waveform = await LibraryScanner().computeWaveform(url: track.url, bars: 84)
            if !waveform.isEmpty { break }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(1500)) }
        }
        if !waveform.isEmpty { await AnalysisCache.shared.putWaveform(url: track.url, waveform: waveform) }
        let committed = waveform.isEmpty ? Array(repeating: Float(0.04), count: 84) : waveform
        await MainActor.run {
            guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }),
                  state.tracks[idx].waveform.isEmpty else { return }
            state.tracks[idx].waveform = committed
        }
    }
}
