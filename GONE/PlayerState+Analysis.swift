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

    func cancelAnalysisTask(for trackId: UUID) {
        analysisTasksByTrack[trackId]?.cancel()
        analysisTasksByTrack.removeValue(forKey: trackId)
        analysisFeed.progress.removeValue(forKey: trackId)
    }

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

        cancelAnalysisTask(for: trackId)
        let task = Task.detached(priority: .userInitiated) { [self] in
            let bpm = await LibraryScanner().analyzeBPMDeep(
                url: track.url, floor: floor, ceiling: ceiling
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.analysisFeed.progress[trackId] = progress
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in self?.cancelAnalysisTask(for: trackId) }
                return
            }
            // The deep pass returns the raw period, frequently the lower octave
            // (125 BPM came back as 65 from the manual re-analyze button). Same
            // normalization rule as everywhere else: no one-beat-per-second values
            // in a dance-music player unless the user narrowed the range there.
            let normalized = LibraryScanner.normalizeDanceBPM(bpm, floor: floor, ceiling: ceiling)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.analysisTasksByTrack.removeValue(forKey: trackId)
                self.analysisFeed.progress.removeValue(forKey: trackId)
                guard let i = self.tracks.firstIndex(where: { $0.id == trackId }) else { return }
                var t = self.tracks[i]
                let bpm = normalized
                if bpm > 0 {
                    t.bpm = bpm
                    t.bpmAnalysisState = .analyzed
                    // BPM changed → existing offset is invalid against new beat duration.
                    // Zero confidence so WaveformView falls back to safe (uniform) grid
                    // until a combined analysis pass recomputes the offset.
                    t.beatGridOffset = 0
                    t.beatGridConfidence = 0
                } else {
                    t.bpmAnalysisState = .failed
                }
                self.tracks[i] = t
            }
        }
        analysisTasksByTrack[trackId] = task
    }

    // Triggers BPM + waveform for the current track, then schedules the rest.
    func scheduleCurrentTrackAnalysis() {
        guard let current = current, !current.isMissing else { return }
        let currentNeedsBeatGrid = current.bpm > 0
            && current.beatGridConfidence <= 0
            && current.bpmAnalysisState == .analyzed
        if currentNeedsBeatGrid,
           let idx = tracks.firstIndex(where: { $0.id == current.id }) {
            tracks[idx].bpmAnalysisState = .pending
        }

        let analysisState = tracks.first(where: { $0.id == current.id })?.bpmAnalysisState ?? current.bpmAnalysisState
        let needsStandaloneWaveform = current.waveform.isEmpty
            && analysisState != .pending
            && analysisState != .analyzing
        scheduleBPMAnalysis()
        if needsStandaloneWaveform {
            scheduleWaveformComputation(currentOnly: true)
        }
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
        // Mutate a local copy and assign once → single objectWillChange broadcast.
        let pendingIds = Set(pending.map(\.id))
        bpmBatchTask?.cancel()              // supersede any in-flight batch pass
        for id in pendingIds {
            analysisTasksByTrack[id]?.cancel()   // supersede deep per-track tasks for these ids
        }
        var updated = tracks
        for i in updated.indices where pendingIds.contains(updated[i].id) { updated[i].bpmAnalysisState = .analyzing }
        tracks = updated

        let task = Task.detached(priority: .userInitiated) { [self] in
            // Wait out any active import — competing AVAssetReaders freeze the UI.
            while await MainActor.run(body: { self.isImporting }) {
                guard !Task.isCancelled else {
                    await MainActor.run { self.finishBPMAnalysisTask(ids: pendingIds, reschedule: false) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else {
                await MainActor.run { self.finishBPMAnalysisTask(ids: pendingIds, reschedule: false) }
                return
            }

            // Lane 1: current track alone, high priority — user sees BPM + beat grid first.
            // No other analysis competes during this phase.
            let first = pending[0]
            await Self.analyzeBPMAndCommit(track: first, state: self)
            guard !Task.isCancelled else {
                await MainActor.run { self.finishBPMAnalysisTask(ids: pendingIds, reschedule: false) }
                return
            }

            // Brief pause: let playback settle before batch analysis competes for disk I/O.
            // At 2 concurrent AVAssetReaders, seek + playback stutter is measurable.
            // This 1.5s gap costs nothing perceptible but keeps the first beat lag-free.
            if pending.count > 1 {
                try? await Task.sleep(for: .milliseconds(1500))
            }
            guard !Task.isCancelled else {
                await MainActor.run { self.finishBPMAnalysisTask(ids: pendingIds, reschedule: false) }
                return
            }

            // Lane 2: background batch. Since analysis ACTUALLY runs off-main now (it
            // used to be silently main-pinned), concurrent AVAssetReaders genuinely
            // contend with playback chunk reads for disk I/O — playback chewed in
            // chunks. Throttle hard while music plays: 1 reader + a breather between
            // batches; full speed only when idle.
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                guard !Task.isCancelled else {
                    await MainActor.run { self.finishBPMAnalysisTask(ids: pendingIds, reschedule: false) }
                    return
                }
                let (priorityId, playing) = await MainActor.run {
                    (self.bpmPriorityId ?? self.currentId, self.isPlaying)
                }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.bpmPriorityId = nil }

                let conc = playing ? 1 : min(2, Self.analysisConcurrency)
                let batch = Array(queue.prefix(conc * 2))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(conc, q.count) {
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
                if playing {
                    try? await Task.sleep(for: .milliseconds(400))   // let the player's prefetch refill
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishBPMAnalysisTask(ids: pendingIds, reschedule: true)
            }
        }
        // One handle for the whole batch: cancelling a single track (cancelAnalysisTask) no longer
        // tears down the entire batch pass — only an explicit bpmBatchTask.cancel() does.
        bpmBatchTask = task
    }

    // nonisolated: with the project's MainActor-by-default isolation this method body —
    // including the awaited analyzer calls — ran ON the main thread. All PlayerState
    // access inside already goes through MainActor.run, so the body itself is main-free.
    nonisolated private static func analyzeBPMAndCommit(track: Track, state: PlayerState) async {
        guard !Task.isCancelled else { return }
        // Cache hit: skip decode + analysis entirely. Saves ~300-500 ms per track.
        if let hit = await AnalysisCache.shared.get(for: track.url),
           hit.bpm > 0,
           hit.beatGridConfidence > 0 {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                var t = state.tracks[idx]
                t.bpm = hit.bpm
                t.bpmAnalysisState = .analyzed
                t.beatGridOffset = hit.beatGridOffset
                t.beatGridConfidence = hit.beatGridConfidence
                if t.waveform.isEmpty, !hit.waveform.isEmpty {
                    t.waveform = hit.waveform
                }
                state.tracks[idx] = t
            }
            return
        }

        let floor   = await MainActor.run { state.bpmAnalysisFloor }
        let ceiling = await MainActor.run { state.bpmAnalysisCeiling }
        // Single decode: BPM + waveform + beat grid offset from one AVAssetReader pass.
        var (bpm, waveform, beatGridOffset, gridConfidence) = await LibraryScanner().analyzeBPMWithWaveform(
            url: track.url, floor: floor, ceiling: ceiling, waveformBars: 168
        ) { progress in
            Task { @MainActor [weak state] in
                state?.analysisFeed.progress[track.id] = progress
            }
        }
        guard !Task.isCancelled else { return }

        // Dance-floor sanity: in a DJ tool a first-pass result below 80 or above 145 BPM
        // is suspect — auto-verify with the deep full-track pass and let its verdict win.
        // Applies only on a wide/open detection range; a user-narrowed preset
        // (D&B 160-195, HIP-HOP 70-115) makes such values expected and skips this.
        if bpm > 0, floor < 80, ceiling > 160, bpm < 95 || bpm > 145 {
            let deep = await LibraryScanner().analyzeBPMDeep(url: track.url, floor: floor, ceiling: ceiling)
            guard !Task.isCancelled else { return }
            if deep > 0 {
                // The deep pass returns the raw period, often the lower octave (bench:
                // 127 came back as 63.4, 135 as 67.6) — normalize before comparing.
                let d = LibraryScanner.normalizeDanceBPM(deep, floor: floor, ceiling: ceiling)
                if abs(d - bpm) > 0.5 {
                    bpm = d
                    // The beat-grid phase was estimated for the discarded tempo — invalidate.
                    beatGridOffset = 0
                    gridConfidence = 0
                }
            }
        }

        if bpm > 0 {
            await AnalysisCache.shared.putBPMAndWaveform(url: track.url, bpm: bpm, waveform: waveform,
                                                         beatGridOffset: beatGridOffset, beatGridConfidence: gridConfidence)
        }
        await MainActor.run {
            state.analysisFeed.progress.removeValue(forKey: track.id)
            guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            var t = state.tracks[idx]
            if bpm > 0 {
                t.bpm = bpm
                t.bpmAnalysisState = .analyzed
                t.beatGridOffset = beatGridOffset
                t.beatGridConfidence = gridConfidence
                if t.waveform.isEmpty, !waveform.isEmpty {
                    t.waveform = waveform
                }
            } else {
                t.bpmAnalysisState = .failed
            }
            state.tracks[idx] = t
        }
    }

    private func finishBPMAnalysisTask(ids: Set<UUID>, reschedule: Bool) {
        isAnalyzingBPM = false
        bpmPriorityId = nil
        bpmBatchTask = nil
        for id in ids {
            analysisFeed.progress.removeValue(forKey: id)
        }
        guard reschedule else { return }
        let hasMore = tracks.contains { !$0.isMissing && $0.bpmAnalysisState == .pending }
        if hasMore { scheduleBPMAnalysis() }
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

        waveformTask = Task.detached(priority: .userInitiated) { [self] in
            // Lane 1: first track (current or head) — computed immediately.
            let first = pending[0]
            await Self.computeWaveformAndCommit(track: first, state: self)

            // Lane 2: background — priority-aware. Same playback-aware throttle as the
            // BPM batch: up to analysisConcurrency readers when idle, a single reader
            // plus a breather while music plays (real off-main decode contends with
            // the player's chunk reads for disk I/O).
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                guard !Task.isCancelled else { break }
                let (priorityId, playing) = await MainActor.run {
                    (self.waveformPriorityId ?? self.currentId, self.isPlaying)
                }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.waveformPriorityId = nil }

                let conc = playing ? 1 : Self.analysisConcurrency
                let batch = Array(queue.prefix(conc * 2))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(conc, q.count) {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                    while await group.next() != nil, !q.isEmpty {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                }
                if playing {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isComputingWaveforms = false
                self.waveformPriorityId = nil
                self.waveformTask = nil
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
            waveform = await LibraryScanner().computeWaveform(url: track.url, bars: 168)
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

    // Manual BPM override via tap tempo.
    // Rounds to 0.1 BPM; invalidates beat grid phase (confidence = 0) since
    // the tapped value has no offset information.
    func applyTappedBPM(_ bpm: Double, for trackId: UUID) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        var t = tracks[idx]
        t.bpm = (bpm * 10).rounded() / 10
        t.bpmAnalysisState = .analyzed
        t.beatGridConfidence = 0
        tracks[idx] = t
        if t.id == currentId { applyBPMFilter(to: t) }
    }
}
