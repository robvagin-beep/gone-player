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
        // == 0 strictly: 0 means "grid never attempted". -1 means "attempted, weak" —
        // re-triggering on -1 looped a full-track decode on every visit of such
        // tracks (playlist on repeat chewed the disk mid-playback, forever).
        let currentNeedsBeatGrid = current.bpm > 0
            && current.beatGridConfidence == 0
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

    // Express lane (see importURLs). Fully processes ONE track — metadata, then BPM, then
    // waveform — directly, bypassing the `while isImporting` gate in scheduleBPMAnalysis. The
    // track the user is about to hear gets its tempo + waveform BEFORE the bulk metadata pass,
    // which only feeds the list and the lowest-priority total playlist time. One track at a
    // time → no multi-reader UI freeze. analyzeBPMAndCommit/computeWaveformAndCommit set the
    // track to .analyzed / fill its waveform, so the later bulk passes skip it.
    func analyzeTrackExpress(id: UUID) async {
        guard let placeholder = tracks.first(where: { $0.id == id && !$0.isMissing }) else { return }

        // 1. Metadata for this single file (title / artist / duration / artwork / tag BPM).
        if let full = await LibraryScanner().readMetadata(url: placeholder.url, id: id) {
            if let idx = tracks.firstIndex(where: { $0.id == id }) {
                var updated = full
                updated.rating = tracks[idx].rating
                updated.flag   = tracks[idx].flag
                tracks[idx] = updated
            }
        }

        // 2. BPM (computed off-main; analyzeBPMAndCommit is nonisolated).
        guard let t1 = tracks.first(where: { $0.id == id }) else { return }
        await Self.analyzeBPMAndCommit(track: t1, state: self)

        // 3. Waveform.
        guard let t2 = tracks.first(where: { $0.id == id }), t2.waveform.isEmpty else { return }
        await Self.computeWaveformAndCommit(track: t2, state: self)
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
                // Coarser dosing the larger the library: every committed track triggers a
                // @Published tracks broadcast → a full playlist re-sort/re-diff (O(n log n)).
                // At per-track granularity that is O(n²·log n) and visibly drags at thousands
                // of tracks. Commit a whole chunk in ONE write — chunk grows with volume while
                // idle; stays small + responsive while playing.
                let chunkSize = playing ? 4 : (pending.count >= 1000 ? 64 : pending.count >= 300 ? 24 : 8)
                let chunk = Array(queue.prefix(chunkSize))
                queue = Array(queue.dropFirst(chunk.count))

                var outcomes: [BPMOutcome] = []
                await withTaskGroup(of: BPMOutcome?.self) { group in
                    var q = chunk
                    for _ in 0..<min(conc, q.count) {
                        let track = q.removeFirst()
                        group.addTask(priority: .utility) {
                            await Self.analyzeBPMCompute(track: track, state: self)
                        }
                    }
                    while let res = await group.next() {
                        if let res { outcomes.append(res) }
                        if !q.isEmpty {
                            let track = q.removeFirst()
                            group.addTask(priority: .utility) {
                                await Self.analyzeBPMCompute(track: track, state: self)
                            }
                        }
                    }
                }
                await Self.applyBPMOutcomes(outcomes, state: self)
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
    // One analyzed track's result, decoupled from the commit so a whole chunk can be written
    // to `state.tracks` in a single @Published broadcast (see applyBPMOutcomes / Lane 2).
    fileprivate struct BPMOutcome {
        let id: UUID
        let bpm: Double            // > 0 = success, 0 = failed
        let beatGridOffset: Double
        let beatGridConfidence: Double
        let waveform: [Float]
    }

    // Pure analysis — decode + dance-floor sanity + cache, NO state.tracks write.
    // Returns nil only when cancelled. Caller commits via applyBPMOutcomes.
    nonisolated private static func analyzeBPMCompute(track: Track, state: PlayerState) async -> BPMOutcome? {
        guard !Task.isCancelled else { return nil }
        // Cache hit: skip decode + analysis entirely. Saves ~300-500 ms per track.
        // confidence != 0 accepts BOTH strong grids (>0) and attempted-but-weak (-1):
        // rejecting weak-grid cache entries made such tracks re-decode the full file
        // on EVERY visit forever. Only confidence == 0 (legacy "never attempted") re-analyzes.
        if let hit = await AnalysisCache.shared.get(for: track.url),
           hit.bpm > 0,
           hit.beatGridConfidence != 0 {
            return BPMOutcome(id: track.id, bpm: hit.bpm, beatGridOffset: hit.beatGridOffset,
                              beatGridConfidence: hit.beatGridConfidence, waveform: hit.waveform)
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
        guard !Task.isCancelled else { return nil }

        // Dance-floor sanity: in a DJ tool a first-pass result below 80 or above 145 BPM
        // is suspect — auto-verify with the deep full-track pass and let its verdict win.
        // Applies only on a wide/open detection range; a user-narrowed preset
        // (D&B 160-195, HIP-HOP 70-115) makes such values expected and skips this.
        if bpm > 0, floor < 80, ceiling > 160, bpm < 95 || bpm > 145 {
            let deep = await LibraryScanner().analyzeBPMDeep(url: track.url, floor: floor, ceiling: ceiling)
            guard !Task.isCancelled else { return nil }
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

        // Sentinel: confidence -1 = "grid attempted, too weak to trust". 0 is reserved
        // for "never attempted" — re-triggers grid analysis on track load, so a raw 0
        // here would loop the full decode forever on weak material.
        let storedConfidence = gridConfidence > 0 ? gridConfidence : -1
        if bpm > 0 {
            await AnalysisCache.shared.putBPMAndWaveform(url: track.url, bpm: bpm, waveform: waveform,
                                                         beatGridOffset: beatGridOffset, beatGridConfidence: storedConfidence)
        }
        return BPMOutcome(id: track.id, bpm: bpm, beatGridOffset: beatGridOffset,
                          beatGridConfidence: storedConfidence, waveform: waveform)
    }

    // Apply a batch of analyzed results in ONE state.tracks write → one @Published broadcast
    // for the whole chunk instead of one per track (the O(n²·log n) scale killer). Builds an
    // id→index map once so lookups are O(1) within the batch.
    nonisolated private static func applyBPMOutcomes(_ outcomes: [BPMOutcome], state: PlayerState) async {
        guard !outcomes.isEmpty else { return }
        await MainActor.run {
            var t = state.tracks
            var index = [UUID: Int](minimumCapacity: t.count)
            for (i, tr) in t.enumerated() { index[tr.id] = i }
            for o in outcomes {
                state.analysisFeed.progress.removeValue(forKey: o.id)
                guard let idx = index[o.id] else { continue }
                if o.bpm > 0 {
                    t[idx].bpm = o.bpm
                    t[idx].bpmAnalysisState = .analyzed
                    t[idx].beatGridOffset = o.beatGridOffset
                    t[idx].beatGridConfidence = o.beatGridConfidence
                    if t[idx].waveform.isEmpty, !o.waveform.isEmpty { t[idx].waveform = o.waveform }
                } else {
                    t[idx].bpmAnalysisState = .failed
                }
            }
            state.tracks = t   // single broadcast for the whole chunk
        }
    }

    nonisolated private static func analyzeBPMAndCommit(track: Track, state: PlayerState) async {
        if let outcome = await analyzeBPMCompute(track: track, state: state) {
            await applyBPMOutcomes([outcome], state: state)
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
                // Coarser dosing the larger the library — same scale fix as BPM: commit a whole
                // chunk in ONE state.tracks write instead of one broadcast (→ playlist re-sort)
                // per track. Chunk grows with volume while idle, stays small while playing.
                let chunkSize = playing ? 4 : (pending.count >= 1000 ? 64 : pending.count >= 300 ? 24 : 8)
                let chunk = Array(queue.prefix(chunkSize))
                queue = Array(queue.dropFirst(chunk.count))

                var outcomes: [(id: UUID, waveform: [Float])] = []
                await withTaskGroup(of: (id: UUID, waveform: [Float])?.self) { group in
                    var q = chunk
                    for _ in 0..<min(conc, q.count) {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveform(track: track, state: self) }
                    }
                    while let res = await group.next() {
                        if let res { outcomes.append(res) }
                        if !q.isEmpty {
                            let track = q.removeFirst()
                            group.addTask { await Self.computeWaveform(track: track, state: self) }
                        }
                    }
                }
                await Self.applyWaveformOutcomes(outcomes, state: self)
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

    // Pure waveform compute — decode + cache, NO state.tracks write. Returns the bars to
    // commit (a flat low floor on failure). Caller commits via applyWaveformOutcomes.
    private static func computeWaveform(track: Track, state: PlayerState) async -> (id: UUID, waveform: [Float])? {
        // Cache hit: skip full-track decode entirely.
        if let hit = await AnalysisCache.shared.get(for: track.url), !hit.waveform.isEmpty {
            return (track.id, hit.waveform)
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
        return (track.id, committed)
    }

    // Apply a chunk of waveforms in ONE state.tracks write → one broadcast for the whole chunk.
    private static func applyWaveformOutcomes(_ outcomes: [(id: UUID, waveform: [Float])], state: PlayerState) async {
        guard !outcomes.isEmpty else { return }
        await MainActor.run {
            var t = state.tracks
            var index = [UUID: Int](minimumCapacity: t.count)
            for (i, tr) in t.enumerated() { index[tr.id] = i }
            for o in outcomes {
                guard let idx = index[o.id], t[idx].waveform.isEmpty else { continue }
                t[idx].waveform = o.waveform
            }
            state.tracks = t
        }
    }

    private static func computeWaveformAndCommit(track: Track, state: PlayerState) async {
        if let outcome = await computeWaveform(track: track, state: state) {
            await applyWaveformOutcomes([outcome], state: state)
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
