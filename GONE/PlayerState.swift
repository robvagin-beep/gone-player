import Foundation
import Combine
import AppKit
import SwiftUI

struct PlaylistTabModel: Identifiable, Equatable {
    let id: UUID
    var title: String
    var trackIds: [UUID]
    var sortKey: PlayerState.SortKey = .number
    var sortDir: PlayerState.SortDir = .asc
}

final class PlayerState: ObservableObject {
    static let initialPlaylistTabId = UUID()

    // MARK: — Playback

    @Published var tracks: [Track] = []
    @Published var currentId: UUID?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var isImporting = false
    @Published var isDraggingInternally = false
    @Published var crossPaneDragTargetTabId: UUID? = nil
    @Published var crossPaneDragIsCopy = false

    // MARK: — Transport

    @Published var volume: Double = 72
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .all

    // MARK: — Pitch / Tempo

    @Published var pitch: Double = 0
    @Published var pitchRange: Int = 8
    @Published var masterTempo = true
    @Published var pitchBypassed = false

    @Published var bpmFilterOn = false
    @Published var bpmFilterLow: Double = 90
    @Published var bpmFilterHigh: Double = 120

    // MARK: — EQ / DSP

    @Published var eqOn = true
    @Published var eqBands: [Float] = Array(repeating: 0, count: 10)
    @Published var eqPreamp: Float = 0
    @Published var eqPreset = "Flat"
    @Published var hpfCutoff: Float = 0
    @Published var lpfCutoff: Float = 0
    @Published var reverbAmount: Float = 0
    @Published var reverbPreset: String = "Room"

    // MARK: — Panels

    @Published var eqOpen = false
    @Published var playlistOpen = false
    @Published var playlistPanelHeight: CGFloat = 244
    @Published var cueExportEnabled = false   // prefix filenames 001_, 002_… on drag-to-Finder
    @Published var alwaysOnTop = true
    @Published var snapEnabled = false
    @Published private(set) var snapState: SnapMode = .off
    @Published var snapTimerStart: Date? = nil
    var isSnapping = false  // blocks updateWindowSize during snap animation

    // MARK: — Playlist tabs

    @Published var playlistTabs: [PlaylistTabModel] = [
        PlaylistTabModel(id: PlayerState.initialPlaylistTabId, title: "Tab 1", trackIds: [])
    ]
    @Published var activePlaylistTabId: UUID = PlayerState.initialPlaylistTabId
    @Published var secondaryPlaylistTabId: UUID?
    @Published var splitPlaylistView = false

    // MARK: — Spectrum

    @Published var spectrumData: [Float] = Array(repeating: 0, count: 28)

    // MARK: — Internal flags (accessed across extensions)

    var isAnalyzingBPM = false
    var isComputingWaveforms = false
    @Published var analysisProgress: [UUID: Double] = [:]
    var isPresentingImportPanel = false

    // MARK: — Snap state

    private var snapSavedEqOpen = false
    private var snapSavedPlaylistOpen = false

    // MARK: — Collapse state (header double-click)

    var collapsedSavedEqOpen = false
    var collapsedSavedPlaylistOpen = false
    var playlistAutoOpened = false   // true when playlist was opened by import, not by user

    func prepareForSnap() {
        snapSavedEqOpen = eqOpen
        snapSavedPlaylistOpen = playlistOpen
        withAnimation(.easeOut(duration: 0.16)) {
            eqOpen = false
            playlistOpen = false
        }
    }

    func restoreFromSnap() {
        eqOpen = snapSavedEqOpen
        playlistOpen = snapSavedPlaylistOpen
    }

    func setSnapState(_ s: SnapMode) { snapState = s }

    // MARK: — Enums

    enum SnapMode { case off, waiting, docked, peeking, expanded }
    enum SortKey: String { case number, title, artist, bpm, duration }
    enum SortDir { case asc, desc }
    enum RepeatMode { case off, all, one }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: — Constants

    static let pitchRanges = [8, 16, 100]

    // MARK: — Core computed

    var current: Track? { tracks.first { $0.id == currentId } }

    var playingTabId: UUID? {
        guard let currentId else { return nil }
        return playlistTabs.first(where: { $0.trackIds.contains(currentId) })?.id
    }

    var sortedTracks: [Track] { sortedTracks(forPlaylistTabId: activePlaylistTabId) }
}
