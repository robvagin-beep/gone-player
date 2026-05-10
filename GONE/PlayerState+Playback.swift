import Foundation

extension PlayerState {

    // MARK: — Pitch

    var pitchedBpm: Double? {
        guard pitch != 0, let t = current else { return nil }
        return t.bpm * (1 + pitch / 100)
    }

    func cyclePitchRange() {
        let ranges = Self.pitchRanges
        let idx = ranges.firstIndex(of: pitchRange) ?? 0
        pitchRange = ranges[(idx + 1) % ranges.count]
        pitch = max(-Double(pitchRange), min(Double(pitchRange), pitch))
    }

    // MARK: — BPM Filter

    func applyBPMFilter(to track: Track) {
        guard !pitchBypassed else { return }
        guard bpmFilterOn, track.bpm > 0 else { return }
        let bpm = track.bpm
        let targetBPM: Double
        if bpm < bpmFilterLow {
            targetBPM = bpmFilterLow
        } else if bpm > bpmFilterHigh {
            targetBPM = bpmFilterHigh
        } else {
            pitch = 0
            audioEngine.setPitch(0, masterTempo: masterTempo)
            return
        }
        let newPitch = (targetBPM / bpm - 1.0) * 100.0
        pitch = (newPitch * 100).rounded() / 100
        audioEngine.setPitch(pitch, masterTempo: masterTempo)
    }

    // MARK: — Panel toggles

    func toggleAccordionPanels() {
        if eqOpen || playlistOpen {
            // Save exactly what is visible — always. The auto-open flag only controlled
            // whether import-opened playlist was treated as a preference, but that logic
            // caused EQ to reopen instead of playlist when both were open during auto-open.
            collapsedSavedEqOpen = eqOpen
            collapsedSavedPlaylistOpen = playlistOpen
            playlistAutoOpened = false
            eqOpen = false
            playlistOpen = false
        } else if collapsedSavedEqOpen || collapsedSavedPlaylistOpen {
            eqOpen = collapsedSavedEqOpen
            playlistOpen = collapsedSavedPlaylistOpen
        } else {
            playlistOpen = true
        }
    }

    // MARK: — Load / Play

    func load(id: UUID) {
        guard let track = tracks.first(where: { $0.id == id }), !track.isMissing else { return }
        currentId = id
        progress = 0; currentTime = 0; isPlaying = false
        hotCues = [nil, nil, nil, nil]
        progressFeed.reset()
        audioEngine.load(track.url)
        applyBPMFilter(to: track)
        scheduleCurrentTrackAnalysis()
    }

    func playTrack(id: UUID, fromTabId: UUID? = nil, autoplay: Bool = true) {
        guard let track = tracks.first(where: { $0.id == id }), !track.isMissing else { return }
        currentId = id
        if let fromTabId { playingTabOverride = fromTabId }
        progress = 0; currentTime = 0
        hotCues = [nil, nil, nil, nil]
        progressFeed.reset()
        isPlaying = autoplay
        audioEngine.load(track.url)
        applyBPMFilter(to: track)
        scheduleCurrentTrackAnalysis()
        if autoplay { audioEngine.play() }
    }

    func togglePlayback() {
        guard let current, !current.isMissing else {
            isPlaying = false
            audioEngine.pause()
            return
        }
        isPlaying.toggle()
        if isPlaying {
            if !audioEngine.snapshot().isLoaded {
                audioEngine.load(current.url)
            }
            audioEngine.play()
        } else {
            audioEngine.pause()
        }
    }

    // MARK: — Track navigation

    func selectPreviousTrack(autoplay: Bool = true) {
        let wasPlaying = isPlaying
        let list = sortedTracks(forPlaylistTabId: playingTabId ?? activePlaylistTabId)
        guard let idx = list.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIdx: Int
        if shuffle {
            let available = list.indices.filter { list[$0].id != currentId && !list[$0].isMissing }
            guard let pick = available.randomElement() else { return }
            nextIdx = pick
        } else {
            var i = (idx - 1 + list.count) % list.count
            while list[i].isMissing && i != idx { i = (i - 1 + list.count) % list.count }
            nextIdx = i
        }
        currentId = list[nextIdx].id
        progress = 0; currentTime = 0
        progressFeed.reset()
        guard let current else { return }
        guard !current.isMissing else { isPlaying = false; return }
        isPlaying = autoplay ? wasPlaying : false
        audioEngine.load(current.url)
        applyBPMFilter(to: current)
        scheduleCurrentTrackAnalysis()
        if wasPlaying && autoplay { audioEngine.play() }
    }

    func selectNextTrack(autoplay: Bool = true) {
        let wasPlaying = isPlaying
        let list = sortedTracks(forPlaylistTabId: playingTabId ?? activePlaylistTabId)
        guard let idx = list.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIdx: Int
        if shuffle {
            let available = list.indices.filter { list[$0].id != currentId && !list[$0].isMissing }
            guard let pick = available.randomElement() else { return }
            nextIdx = pick
        } else {
            var i = (idx + 1) % list.count
            while list[i].isMissing && i != idx { i = (i + 1) % list.count }
            nextIdx = i
        }
        currentId = list[nextIdx].id
        progress = 0; currentTime = 0
        progressFeed.reset()
        guard let current else { return }
        guard !current.isMissing else { isPlaying = false; return }
        isPlaying = autoplay ? wasPlaying : false
        audioEngine.load(current.url)
        applyBPMFilter(to: current)
        scheduleCurrentTrackAnalysis()
        if wasPlaying && autoplay { audioEngine.play() }
    }

    // MARK: — Library mutations

    func removeFromPlaylist(id: UUID, tabId: UUID) {
        guard let tabIndex = playlistTabs.firstIndex(where: { $0.id == tabId }) else { return }
        playlistTabs[tabIndex].trackIds.removeAll { $0 == id }
    }

    func deleteFromLibrary(id: UUID) {
        for index in playlistTabs.indices {
            playlistTabs[index].trackIds.removeAll { $0 == id }
        }
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = tracks[idx].id == currentId
        tracks.remove(at: idx)
        guard wasCurrent else { return }
        progress = 0; currentTime = 0
        progressFeed.reset()

        guard !tracks.isEmpty else {
            currentId = nil; isPlaying = false; progress = 0; currentTime = 0
            audioEngine.stop()
            return
        }
        let available = sortedTracks(forPlaylistTabId: playingTabId ?? activePlaylistTabId).filter { !$0.isMissing }
        if let next = available.first {
            currentId = next.id; progress = 0; currentTime = 0
            audioEngine.load(next.url)
            if isPlaying { audioEngine.play() }
        } else {
            currentId = nil; isPlaying = false; progress = 0; currentTime = 0
            audioEngine.stop()
        }
    }
}
