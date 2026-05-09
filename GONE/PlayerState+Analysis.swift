import Foundation

extension PlayerState {

    // MARK: — Public entry points

    func reanalyzeBPM(for trackId: UUID) {
        guard let idx = tracks.firstIndex(where: { $0.id == trackId }) else { return }
        tracks[idx].bpmAnalysisState = .pending
        scheduleBPMAnalysis()
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
            !$0.isMissing && ($0.bpmAnalysisState == .pending || $0.bpmAnalysisState == .failed)
        }
        guard !pending.isEmpty else { return }

        // Current track always goes first.
        if let currentId { pending.sort { a, _ in a.id == currentId } }

        isAnalyzingBPM = true
        bpmPriorityId = nil

        // Mark all as .analyzing upfront so progress bars appear immediately.
        let pendingIds = Set(pending.map(\.id))
        var t = tracks
        for i in t.indices where pendingIds.contains(t[i].id) { t[i].bpmAnalysisState = .analyzing }
        tracks = t

        Task.detached(priority: .utility) { [self] in
            // Wait out any active import — competing AVAssetReaders freeze the UI.
            while await MainActor.run(body: { self.isImporting }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            // Lane 1: current track alone — user sees BPM immediately.
            let first = pending[0]
            await Self.analyzeBPMAndCommit(track: first, state: self)

            // Lane 2: background batches — priority-aware.
            // Between batches, check if currentId changed and reorder queue.
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                // Priority reorder: move newly selected current track to front.
                let priorityId = await MainActor.run { self.bpmPriorityId ?? self.currentId }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.bpmPriorityId = nil }

                let batch = Array(queue.prefix(4))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(2, q.count) {
                        let track = q.removeFirst()
                        group.addTask { await Self.analyzeBPMAndCommit(track: track, state: self) }
                    }
                    while await group.next() != nil, !q.isEmpty {
                        let track = q.removeFirst()
                        group.addTask { await Self.analyzeBPMAndCommit(track: track, state: self) }
                    }
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAnalyzingBPM = false
                self.bpmPriorityId = nil
                let hasMore = self.tracks.contains {
                    !$0.isMissing && ($0.bpmAnalysisState == .pending || $0.bpmAnalysisState == .failed)
                }
                if hasMore { self.scheduleBPMAnalysis() }
            }
        }
    }

    private static func analyzeBPMAndCommit(track: Track, state: PlayerState) async {
        let bpm = await LibraryScanner().analyzeBPM(url: track.url) { progress in
            Task { @MainActor [weak state] in
                state?.analysisProgress[track.id] = progress
            }
        }
        await MainActor.run {
            state.analysisProgress.removeValue(forKey: track.id)
            guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }) else { return }
            var u = state.tracks
            if bpm > 0 { u[idx].bpm = bpm; u[idx].bpmAnalysisState = .analyzed }
            else       { u[idx].bpmAnalysisState = .failed }
            state.tracks = u
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

        Task.detached(priority: .utility) { [self] in
            // Lane 1: first track (current or head) — computed immediately.
            let first = pending[0]
            await Self.computeWaveformAndCommit(track: first, state: self)

            // Lane 2: background batches — priority-aware.
            var queue = Array(pending.dropFirst())
            while !queue.isEmpty {
                let priorityId = await MainActor.run { self.waveformPriorityId ?? self.currentId }
                if let pid = priorityId,
                   let idx = queue.firstIndex(where: { $0.id == pid }) {
                    let promoted = queue.remove(at: idx)
                    queue.insert(promoted, at: 0)
                }
                await MainActor.run { self.waveformPriorityId = nil }

                let batch = Array(queue.prefix(4))
                queue = Array(queue.dropFirst(batch.count))

                await withTaskGroup(of: Void.self) { group in
                    var q = batch
                    for _ in 0..<min(2, q.count) {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                    while await group.next() != nil, !q.isEmpty {
                        let track = q.removeFirst()
                        group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                    }
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
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
        let waveform = await LibraryScanner().computeWaveform(url: track.url, bars: 84)
        await MainActor.run {
            guard let idx = state.tracks.firstIndex(where: { $0.id == track.id }),
                  state.tracks[idx].waveform.isEmpty else { return }
            state.tracks[idx].waveform = waveform
        }
    }
}
