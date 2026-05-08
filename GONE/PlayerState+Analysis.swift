import Foundation

extension PlayerState {

    // How many tracks to analyze in parallel.
    // Leaves 2 cores for UI + audio; caps at 6 to avoid memory pressure from simultaneous AVAssetReaders.
    private var analysisConcurrency: Int {
        min(6, max(2, ProcessInfo.processInfo.processorCount - 2))
    }

    // Triggers BPM + waveform for the current track, then schedules the rest.
    func scheduleCurrentTrackAnalysis() {
        guard let current = current, !current.isMissing else { return }
        scheduleBPMAnalysis()
        scheduleWaveformComputation(currentOnly: true)
    }

    // MARK: — BPM analysis

    func scheduleBPMAnalysis() {
        guard !isAnalyzingBPM else { return }

        var pending = tracks.filter {
            !$0.isMissing && ($0.bpmAnalysisState == .pending || $0.bpmAnalysisState == .failed)
        }
        guard !pending.isEmpty else { return }

        // Current track analyzed first, alone
        if let currentId {
            pending.sort { a, _ in a.id == currentId }
        }

        isAnalyzingBPM = true
        let pendingIds = Set(pending.map(\.id))
        var t = tracks
        for i in t.indices where pendingIds.contains(t[i].id) { t[i].bpmAnalysisState = .analyzing }
        tracks = t

        Task.detached(priority: .utility) { [self] in
            // 1. Current track alone — user sees BPM immediately.
            //    Wait if an import is already underway to avoid competing AVAssetReaders.
            while await MainActor.run(body: { self.isImporting }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let first = pending[0]
            await Self.analyzeBPMAndCommit(track: first, state: self)

            // 2. Remaining tracks — sequential, one at a time.
            //    Re-check isImporting before each track so a late second import
            //    doesn't produce competing AVAssetReaders that can hang analysis.
            let queue = Array(pending.dropFirst())
            for track in queue {
                while await MainActor.run(body: { self.isImporting }) {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                let stillPending = await MainActor.run {
                    self.tracks.first(where: { $0.id == track.id })?.bpmAnalysisState == .analyzing
                }
                guard stillPending else { continue }
                await Self.analyzeBPMAndCommit(track: track, state: self)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isAnalyzingBPM = false
                self.scheduleBPMAnalysis()
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
        guard !isComputingWaveforms else { return }

        let pending: [Track]
        if currentOnly, let currentId {
            pending = tracks.filter { $0.id == currentId && !$0.isMissing && $0.waveform.isEmpty }
        } else {
            pending = tracks.filter { !$0.isMissing && $0.waveform.isEmpty }
        }
        guard !pending.isEmpty else { return }

        isComputingWaveforms = true
        let concurrency = analysisConcurrency

        Task.detached(priority: .utility) { [self] in
            // 1. First track (current or head of queue) — computed immediately
            let first = pending[0]
            await Self.computeWaveformAndCommit(track: first, state: self)

            // 2. Rest in parallel
            var queue = Array(pending.dropFirst())
            guard !queue.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.isComputingWaveforms = false
                    self?.scheduleWaveformComputation()
                }
                return
            }

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(concurrency, queue.count) {
                    let track = queue.removeFirst()
                    group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                }
                while await group.next() != nil, !queue.isEmpty {
                    let track = queue.removeFirst()
                    group.addTask { await Self.computeWaveformAndCommit(track: track, state: self) }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isComputingWaveforms = false
                self.scheduleWaveformComputation()
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
