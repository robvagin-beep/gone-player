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
    @Published var showAnalyzingOverlay = false
    @Published var isDraggingInternally = false
    @Published var crossPaneDragTargetTabId: UUID? = nil
    @Published var crossPaneDragIsCopy = false
    @Published var crossPaneDragInsertionIdx: Int? = nil

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

    // MARK: — EQ XY Point
    @Published var xyPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var xyHoldMode = false
    @Published var xyActive = false
    @Published var xyEffectAxis: XYEffectAxis = .filter
    @Published var xyResonance: Float = 1.0  // LPF bandwidth for RESO axis (lower = more resonant)

    // MARK: — Panels

    @Published var eqOpen = false
    @Published var playlistOpen = false
    @Published var pendingDropURLs: [URL]? = nil   // non-nil = split chooser is active
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

    // MARK: — Internal flags (accessed across extensions)

    var isAnalyzingBPM = false
    var isComputingWaveforms = false
    @Published var analysisProgress: [UUID: Double] = [:]
    var bpmPriorityId: UUID? = nil
    var waveformPriorityId: UUID? = nil
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
    enum XYEffectAxis: String, CaseIterable {
        case filter   = "FLTR"
        case reverb   = "VERB"
        case reso     = "RESO"
        case filtVerb = "FLTR+VRB"
        case lfo      = "LFO"
        case bpmChop  = "BPM"
        var next: XYEffectAxis { let a = Self.allCases; return a[(a.firstIndex(of: self)! + 1) % a.count] }
    }

    private var lfoTimer: Timer?
    var lfoPhase: Double = 0
    private var lfoUITick: Int = 0

    private var bpmChopTimer: Timer?
    var bpmChopUITick: Int = 0

    private var xySpringTimer: Timer?
    private var xySpringFrom: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var xySpringStep: Int = 0

    func startLFO() {
        guard lfoTimer == nil else { return }  // idempotent — don't reset phase while running
        lfoPhase = 0
        lfoUITick = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.xyActive, self.xyEffectAxis == .lfo else {
                    self?.stopLFO(); return
                }
                let rate  = Double(self.xyPoint.x) * 7.9 + 0.1  // 0.1–8 Hz
                let depth = Double(self.xyPoint.y) * 0.45         // 0–45% LPF sweep
                self.lfoPhase += rate / 60.0 * 2 * .pi
                let cutoff = Float(max(0.01, min(0.99, 0.5 + sin(self.lfoPhase) * depth)))
                AudioEngineNext.shared.setLPF(cutoff: cutoff)
                // @Published write throttled to ~15fps — audio engine still gets every tick
                self.lfoUITick = (self.lfoUITick + 1) % 4
                if self.lfoUITick == 0 { self.lpfCutoff = cutoff }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lfoTimer = timer
    }

    func stopLFO() {
        lfoTimer?.invalidate()
        lfoTimer = nil
        lfoPhase = 0
        lfoUITick = 0
    }

    func startBPMChop() {
        guard bpmChopTimer == nil else { return }
        bpmChopUITick = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.xyActive, self.xyEffectAxis == .bpmChop else {
                    self?.stopBPMChop(); return
                }
                guard let bpm = self.current?.bpm, bpm > 0 else { return }

                let subdivIdx = Int(Double(self.xyPoint.x) * 3.99)  // 0–3
                let subdivMult = pow(2.0, Double(subdivIdx))          // 1, 2, 4, 8
                let gateHz = bpm / 60.0 * subdivMult

                let snap = AudioEngineNext.shared.snapshot()
                let phase = (snap.currentTime * gateHz).truncatingRemainder(dividingBy: 1.0)
                let depth = Double(self.xyPoint.y)

                // Reverse-sawtooth: LPF sweeps open on each beat → "zoom" opening surge
                let cutoff = Float((1.0 - phase) * depth * 0.72)
                AudioEngineNext.shared.setLPF(cutoff: cutoff)

                // UI throttle ~15fps
                self.bpmChopUITick = (self.bpmChopUITick + 1) % 4
                if self.bpmChopUITick == 0 { self.lpfCutoff = cutoff }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        bpmChopTimer = timer
    }

    func stopBPMChop() {
        bpmChopTimer?.invalidate()
        bpmChopTimer = nil
        bpmChopUITick = 0
        AudioEngineNext.shared.setLPF(cutoff: 0)
    }

    func startXYSpring(onComplete: (() -> Void)? = nil) {
        xySpringTimer?.invalidate()
        xySpringFrom = xyPoint
        xySpringStep = 0
        let steps = 22
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.xySpringStep += 1
                let t    = Double(self.xySpringStep) / Double(steps)
                let ease = 1.0 - pow(1.0 - t, 3.0)
                self.xyPoint = CGPoint(
                    x: self.xySpringFrom.x + (0.5 - self.xySpringFrom.x) * ease,
                    y: self.xySpringFrom.y + (0.5 - self.xySpringFrom.y) * ease
                )
                if self.xySpringStep >= steps {
                    self.xySpringTimer?.invalidate()
                    self.xySpringTimer = nil
                    self.xyPoint = CGPoint(x: 0.5, y: 0.5)
                    onComplete?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        xySpringTimer = timer
    }

    func cancelXYSpring() {
        xySpringTimer?.invalidate()
        xySpringTimer = nil
    }

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
