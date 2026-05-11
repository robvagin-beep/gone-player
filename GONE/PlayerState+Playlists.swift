import Foundation
import AppKit

extension PlayerState {

    // MARK: — Track queries

    func tracks(forPlaylistTabId tabId: UUID) -> [Track] {
        guard let tab = playlistTabs.first(where: { $0.id == tabId }) else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return tab.trackIds.compactMap { lookup[$0] }
    }

    func sortedTracks(forPlaylistTabId tabId: UUID) -> [Track] {
        guard let tab = playlistTabs.first(where: { $0.id == tabId }) else { return [] }
        let raw = tracks(forPlaylistTabId: tabId)
        switch tab.sortKey {
        case .number:
            return tab.sortDir == .asc ? raw : raw.reversed()
        default:
            return raw.sorted { a, b in
                switch tab.sortKey {
                case .title:    return tab.sortDir == .asc ? a.title < b.title       : a.title > b.title
                case .artist:   return tab.sortDir == .asc ? a.artist < b.artist     : a.artist > b.artist
                case .bpm:      return tab.sortDir == .asc ? a.bpm < b.bpm           : a.bpm > b.bpm
                case .duration: return tab.sortDir == .asc ? a.duration < b.duration : a.duration > b.duration
                case .number:   return false
                }
            }
        }
    }

    func toggleSort(_ key: SortKey, forTabId tabId: UUID) {
        guard let i = playlistTabs.firstIndex(where: { $0.id == tabId }) else { return }
        if playlistTabs[i].sortKey == key {
            playlistTabs[i].sortDir = playlistTabs[i].sortDir == .asc ? .desc : .asc
        } else {
            playlistTabs[i].sortKey = key
            playlistTabs[i].sortDir = .asc
        }
    }

    // MARK: — Tab management

    func createPlaylistTab() {
        let tab = PlaylistTabModel(id: UUID(), title: "Tab \(playlistTabs.count + 1)", trackIds: [])
        playlistTabs.append(tab)
        activePlaylistTabId = tab.id
        if secondaryPlaylistTabId == nil {
            secondaryPlaylistTabId = playlistTabs.first(where: { $0.id != tab.id })?.id
        }
        playlistOpen = true
    }

    func selectPlaylistTab(id: UUID) {
        guard playlistTabs.contains(where: { $0.id == id }) else { return }
        activePlaylistTabId = id
        ensureCurrentTrackVisible(in: id)
    }

    func closePlaylistTab(id: UUID) {
        guard playlistTabs.count > 1,
              let index = playlistTabs.firstIndex(where: { $0.id == id }) else { return }
        playlistTabs.remove(at: index)
        if activePlaylistTabId == id {
            let fallback = min(index, playlistTabs.count - 1)
            activePlaylistTabId = playlistTabs[fallback].id
            ensureCurrentTrackVisible(in: activePlaylistTabId)
        }
        if secondaryPlaylistTabId == id {
            secondaryPlaylistTabId = playlistTabs.first(where: { $0.id != activePlaylistTabId })?.id
        }
    }

    func selectSecondaryPlaylistTab(id: UUID) {
        guard playlistTabs.contains(where: { $0.id == id }), id != activePlaylistTabId else { return }
        secondaryPlaylistTabId = id
    }

    func reorderTrack(_ trackId: UUID, before targetTrackId: UUID, inTabId tabId: UUID) {
        guard trackId != targetTrackId,
              let tabIndex = playlistTabs.firstIndex(where: { $0.id == tabId }),
              let sourceIndex = playlistTabs[tabIndex].trackIds.firstIndex(of: trackId),
              let targetIndex = playlistTabs[tabIndex].trackIds.firstIndex(of: targetTrackId)
        else { return }
        if playlistTabs[tabIndex].sortKey != .number {
            playlistTabs[tabIndex].sortKey = .number
            playlistTabs[tabIndex].sortDir = .asc
        }
        var ids = playlistTabs[tabIndex].trackIds
        ids.remove(at: sourceIndex)
        ids.insert(trackId, at: sourceIndex < targetIndex ? targetIndex - 1 : targetIndex)
        playlistTabs[tabIndex].trackIds = ids
    }

    func reorderTrackToEnd(_ trackId: UUID, inTabId tabId: UUID) {
        guard let tabIndex = playlistTabs.firstIndex(where: { $0.id == tabId }),
              playlistTabs[tabIndex].trackIds.contains(trackId) else { return }
        if playlistTabs[tabIndex].sortKey != .number {
            playlistTabs[tabIndex].sortKey = .number
            playlistTabs[tabIndex].sortDir = .asc
        }
        playlistTabs[tabIndex].trackIds.removeAll { $0 == trackId }
        playlistTabs[tabIndex].trackIds.append(trackId)
    }

    func reorderPlaylistTab(from tabId: UUID, before targetTabId: UUID) {
        guard tabId != targetTabId,
              let sourceIndex = playlistTabs.firstIndex(where: { $0.id == tabId }),
              let targetIndex = playlistTabs.firstIndex(where: { $0.id == targetTabId })
        else { return }
        let tab = playlistTabs.remove(at: sourceIndex)
        let insertAt = sourceIndex < targetIndex ? max(0, targetIndex - 1) : targetIndex
        playlistTabs.insert(tab, at: insertAt)
    }

    func toggleSplitPlaylistView() {
        if splitPlaylistView {
            splitPlaylistView = false
        } else {
            let secondaryExists = secondaryPlaylistTabId.flatMap { id in
                playlistTabs.first(where: { $0.id == id })
            } != nil
            if !secondaryExists {
                let tab = PlaylistTabModel(id: UUID(), title: "Finalists", trackIds: [])
                playlistTabs.append(tab)
                secondaryPlaylistTabId = tab.id
            }
            splitPlaylistView = true
        }
    }

    func copyTrack(_ trackId: UUID, to destinationTabId: UUID) {
        guard let di = playlistTabs.firstIndex(where: { $0.id == destinationTabId }) else { return }
        if !playlistTabs[di].trackIds.contains(trackId) {
            playlistTabs[di].trackIds.append(trackId)
        }
    }

    func moveTrack(_ trackId: UUID, from sourceTabId: UUID, to destinationTabId: UUID) {
        guard sourceTabId != destinationTabId,
              let si = playlistTabs.firstIndex(where: { $0.id == sourceTabId }),
              let di = playlistTabs.firstIndex(where: { $0.id == destinationTabId })
        else { return }
        playlistTabs[si].trackIds.removeAll { $0 == trackId }
        if !playlistTabs[di].trackIds.contains(trackId) {
            playlistTabs[di].trackIds.append(trackId)
        }
        // Playback continues uninterrupted — track still exists in the library,
        // it's just visible in a different tab now.
    }

    func moveTrackAt(_ trackId: UUID, from sourceTabId: UUID, to destinationTabId: UUID, insertionIndex: Int?) {
        guard sourceTabId != destinationTabId,
              let si = playlistTabs.firstIndex(where: { $0.id == sourceTabId }),
              let di = playlistTabs.firstIndex(where: { $0.id == destinationTabId })
        else { return }
        let destSorted = sortedTracks(forPlaylistTabId: destinationTabId)
        let beforeId: UUID? = insertionIndex.flatMap { $0 < destSorted.count ? destSorted[$0].id : nil }
        playlistTabs[si].trackIds.removeAll { $0 == trackId }
        guard !playlistTabs[di].trackIds.contains(trackId) else { return }
        playlistTabs[di].trackIds.append(trackId)
        if let beforeId { reorderTrack(trackId, before: beforeId, inTabId: destinationTabId) }
    }

    func copyTrackAt(_ trackId: UUID, to destinationTabId: UUID, insertionIndex: Int?) {
        guard let di = playlistTabs.firstIndex(where: { $0.id == destinationTabId }) else { return }
        guard !playlistTabs[di].trackIds.contains(trackId) else { return }
        let destSorted = sortedTracks(forPlaylistTabId: destinationTabId)
        let beforeId: UUID? = insertionIndex.flatMap { $0 < destSorted.count ? destSorted[$0].id : nil }
        playlistTabs[di].trackIds.append(trackId)
        if let beforeId { reorderTrack(trackId, before: beforeId, inTabId: destinationTabId) }
    }

    // MARK: — Import

    func importURLs(_ urls: [URL], intoPlaylistTabId targetTabId: UUID? = nil) async {
        guard !urls.isEmpty else { return }
        let scanner = LibraryScanner()
        isImporting = true
        let destinationTabId = targetTabId ?? activePlaylistTabId

        let candidateURLs = await Task.detached(priority: .userInitiated) {
            await LibraryScanner().expandImportURLs(urls)
        }.value

        let existingByURL: [URL: UUID] = await MainActor.run { [weak self] in
            guard let self else { return [:] }
            var map: [URL: UUID] = [:]
            for t in self.tracks { map[t.url.standardized] = t.id }
            return map
        }

        let existingIds  = candidateURLs.compactMap { existingByURL[$0.standardized] }
        let newURLs      = candidateURLs.filter     { existingByURL[$0.standardized] == nil }
        let placeholders = newURLs.map { scanner.placeholderTrack(url: $0) }

        await MainActor.run {
            tracks.append(contentsOf: placeholders)
            let tabSet = Set(playlistTabs.first(where: { $0.id == destinationTabId })?.trackIds ?? [])
            let toAdd  = (existingIds + placeholders.map(\.id)).filter { !tabSet.contains($0) }
            appendToTab(toAdd, tabId: destinationTabId)

            if let first = placeholders.first(where: { !$0.isMissing }),
               destinationTabId == activePlaylistTabId,
               currentId == nil {
                currentId = first.id
                progress = 0; currentTime = 0; isPlaying = false
                audioEngine.load(first.url)
                if autoOpenPlaylistOnImport {
                    playlistOpen = true
                    playlistAutoOpened = true
                }
                if autoPlayOnImport { isPlaying = true; audioEngine.play() }
                scheduleCurrentTrackAnalysis()
            }
        }

        let batchSize = 4
        for batchStart in stride(from: 0, to: placeholders.count, by: batchSize) {
            let batch = Array(placeholders[batchStart..<min(batchStart + batchSize, placeholders.count)])
            // Collect all results for the batch concurrently, then apply in one tracks = … write
            var batchResults: [Track] = []
            await withTaskGroup(of: Track?.self) { group in
                for placeholder in batch {
                    group.addTask { await LibraryScanner().readMetadata(url: placeholder.url, id: placeholder.id) }
                }
                for await result in group {
                    guard let track = result else { continue }
                    batchResults.append(track)
                }
            }
            await MainActor.run { [batchResults] in
                var t = self.tracks
                var needsCurrentAnalysis = false
                for track in batchResults {
                    guard let idx = t.firstIndex(where: { $0.id == track.id }) else { continue }
                    var updated = track
                    updated.rating = t[idx].rating
                    updated.hasArtwork = track.hasArtwork || t[idx].hasArtwork
                    updated.waveform = t[idx].waveform
                    if t[idx].bpm > 0 { updated.bpm = t[idx].bpm }
                    if t[idx].bpmAnalysisState != .pending { updated.bpmAnalysisState = t[idx].bpmAnalysisState }
                    t[idx] = updated
                    if self.currentId == track.id { needsCurrentAnalysis = true }
                }
                self.tracks = t  // single objectWillChange for the whole batch
                if needsCurrentAnalysis { self.scheduleCurrentTrackAnalysis() }
                // BPM/waveform analysis intentionally NOT started per-batch —
                // starting analysis while reading metadata causes competing AVAssetReaders
                // that freeze the UI. Analysis is deferred until import finishes.
            }
        }

        await MainActor.run { isImporting = false }

        // Brief yield so SwiftUI can render the completed list before heavy analysis starts.
        try? await Task.sleep(nanoseconds: 150_000_000)

        await MainActor.run {
            if autoBPMOnImport { scheduleBPMAnalysis() }
            scheduleWaveformComputation()
        }
    }

    func presentImportPanel(intoTabId tabId: UUID? = nil) {
        guard !isPresentingImportPanel else { return }
        let snapMgr = WindowSnapManager.shared
        if snapMgr.snapState == .docked || snapMgr.snapState == .peeking {
            snapMgr.expandCurrentWindow()
        }
        snapMgr.pauseForImport()

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        isPresentingImportPanel = true

        // Raise the open panel above the player (screenSaverWindow = 1000) so it is
        // always fully visible. beginSheetModal attaches to the player window and ends
        // up behind it on same-level z-order; plain begin() + elevated level is reliable.
        let ssl = Int(CGWindowLevelForKey(.screenSaverWindow))
        panel.level = NSWindow.Level(rawValue: ssl + 2)

        let destinationTabId = tabId ?? activePlaylistTabId

        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            defer {
                self.isPresentingImportPanel = false
                WindowSnapManager.shared.resumeAfterImport()
            }
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self.importURLs(urls, intoPlaylistTabId: destinationTabId) }
        }

        panel.begin(completionHandler: handleSelection)
    }

    // MARK: — Private helpers

    private func appendToTab(_ ids: [UUID], tabId: UUID) {
        guard let tabIndex = playlistTabs.firstIndex(where: { $0.id == tabId }) else { return }
        playlistTabs[tabIndex].trackIds.append(contentsOf: ids)
    }

    func ensureCurrentTrackVisible(in tabId: UUID) {
        let visibleTracks = tracks(forPlaylistTabId: tabId)
        guard !visibleTracks.isEmpty else { return }
        // If the current track is still alive anywhere in the library, don't touch playback.
        if let currentId, tracks.contains(where: { $0.id == currentId && !$0.isMissing }) { return }
        guard let first = visibleTracks.first(where: { !$0.isMissing }) else { return }
        currentId = first.id
        progress = 0; currentTime = 0; isPlaying = false
        audioEngine.load(first.url)
        scheduleCurrentTrackAnalysis()
    }
}
