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

    let audioEngine: AudioEngineNext

    init(engine: AudioEngineNext = .shared) {
        self.audioEngine = engine
    }

    // MARK: — Playback

    @Published var tracks: [Track] = []
    @Published var currentId: UUID?
    @Published var isPlaying = false
    var progress: Double = 0
    var currentTime: Double = 0
    let progressFeed  = PlaybackProgressFeed()
    let spectrumFeed  = SpectrumFeed()
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

    // MARK: — Hot Cues (session-only, 4 slots, reset on track change)
    @Published var hotCues: [Double?] = [nil, nil, nil, nil]

    // MARK: — Settings

    @Published var autoPlayOnImport: Bool = false
    @Published var autoOpenPlaylistOnImport: Bool = true
    @Published var confirmBeforeDelete: Bool = false
    @Published var hideMissingTracks: Bool = false
    @Published var autoBPMOnImport: Bool = true
    @Published var bpmAnalysisFloor: Double = 60
    @Published var bpmAnalysisCeiling: Double = 200
    @Published var gradientMapHue: Double = 0.0        // 0–360°
    @Published var gradientMapSaturation: Double = 0.0  // 0–100%
    @Published var windowScale: Double = 1.0            // visual display scale (0.5–1.0)
    @Published var defaultWatchFolder: String = ""
    @Published var bpmCacheEnabled: Bool = false
    @Published var bpmCacheFolder: String = ""
    @Published var snapEnabled = false
    @Published private(set) var snapState: SnapMode = .off
    @Published var snapTimerStart: Date? = nil
    var isSnapping = false  // blocks updateWindowSize during snap animation

    // MARK: — Magnify
    @Published var magnifyEnabled: Bool = false
    @Published var magnifyProximity: Double = 60.0   // px from window edge to trigger
    @Published var magnifySpeed: Double = 0.25        // spring response (lower = faster)
    var isMagnified: Bool = false
    var magnifyBaseScale: Double = 1.0

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
    enum RepeatMode: Int { case off = 0, all = 1, one = 2 }
    enum XYEffectAxis: String, CaseIterable {
        case filter      = "FLTR"
        case lowpass     = "LPF"
        case highpass    = "HPF"
        case bandpass    = "BPF"
        case reso        = "RESO"
        case lfo         = "LFO"
        case bpmChop     = "BPM"
        case slicer      = "GATE"
        case reverb      = "VERB"
        case filtVerb    = "FLTR+VRB"
        case simpleDelay = "DLY"
        case dubDelay    = "DUB"
        case lofi        = "LOFI"
        var next: XYEffectAxis { let a = Self.allCases; return a[(a.firstIndex(of: self)! + 1) % a.count] }
    }

    private var lfoTimer: Timer?
    var lfoPhase: Double = 0
    private var lfoUITick: Int = 0

    private var bpmChopTimer: Timer?
    var bpmChopUITick: Int = 0

    private var slicerTimer: Timer?

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
                self.audioEngine.setLPF(cutoff: cutoff)
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

                let snap = self.audioEngine.snapshot()
                let phase = (snap.currentTime * gateHz).truncatingRemainder(dividingBy: 1.0)
                let depth = Double(self.xyPoint.y)

                // Reverse-sawtooth: LPF sweeps open on each beat → "zoom" opening surge
                let cutoff = Float((1.0 - phase) * depth * 0.72)
                self.audioEngine.setLPF(cutoff: cutoff)

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
        audioEngine.setLPF(cutoff: 0)
    }

    func startSlicer() {
        guard slicerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.xyActive, self.xyEffectAxis == .slicer else {
                    self?.stopSlicer(); return
                }
                guard let bpm = self.current?.bpm, bpm > 0 else { return }

                let subdivIdx = Int(Double(self.xyPoint.x) * 3.99)  // 0–3
                let subdivMult = pow(2.0, Double(subdivIdx))          // 1, 2, 4, 8
                let gateHz = bpm / 60.0 * subdivMult

                let snap = self.audioEngine.snapshot()
                let phase = (snap.currentTime * gateHz).truncatingRemainder(dividingBy: 1.0)
                let depth = Float(self.xyPoint.y)

                // 50% duty: first half open, second half gated
                let volume: Float = phase < 0.5 ? 1.0 : max(0.02, 1.0 - depth)
                self.audioEngine.setGateVolume(volume)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slicerTimer = timer
    }

    func stopSlicer() {
        slicerTimer?.invalidate()
        slicerTimer = nil
        audioEngine.setGateVolume(1.0)
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

    // Set when user explicitly starts playback from a specific tab (double-click, context menu).
    // Cleared when that tab no longer contains the current track (tab closed, track moved).
    var playingTabOverride: UUID?

    var playingTabId: UUID? {
        guard let currentId else { return nil }
        // Prefer the explicit override — but only while it's still valid.
        if let override = playingTabOverride,
           playlistTabs.first(where: { $0.id == override })?.trackIds.contains(currentId) == true {
            return override
        }
        return playlistTabs.first(where: { $0.trackIds.contains(currentId) })?.id
    }

    var sortedTracks: [Track] { sortedTracks(forPlaylistTabId: activePlaylistTabId) }

    // MARK: — Settings persistence

    private static let ud = UserDefaults.standard

    func loadPersistedSettings() {
        let ud = Self.ud
        if ud.object(forKey: "volume")              != nil { volume              = ud.double(forKey: "volume") }
        if ud.object(forKey: "pitchRange")          != nil { pitchRange          = ud.integer(forKey: "pitchRange") }
        if ud.object(forKey: "masterTempo")         != nil { masterTempo         = ud.bool(forKey: "masterTempo") }
        if ud.object(forKey: "repeatMode")          != nil { repeatMode          = RepeatMode(rawValue: ud.integer(forKey: "repeatMode")) ?? .all }
        if ud.object(forKey: "windowScale")         != nil { windowScale         = ud.double(forKey: "windowScale") }
        if ud.object(forKey: "gradientMapHue")      != nil { gradientMapHue      = ud.double(forKey: "gradientMapHue") }
        if ud.object(forKey: "gradientMapSat")      != nil { gradientMapSaturation = ud.double(forKey: "gradientMapSat") }
        if ud.object(forKey: "autoBPMOnImport")     != nil { autoBPMOnImport     = ud.bool(forKey: "autoBPMOnImport") }
        if ud.object(forKey: "bpmFloor")            != nil { bpmAnalysisFloor    = ud.double(forKey: "bpmFloor") }
        if ud.object(forKey: "bpmCeiling")          != nil { bpmAnalysisCeiling  = ud.double(forKey: "bpmCeiling") }
        if ud.object(forKey: "autoPlay")            != nil { autoPlayOnImport    = ud.bool(forKey: "autoPlay") }
        if ud.object(forKey: "autoOpenPlaylist")    != nil { autoOpenPlaylistOnImport = ud.bool(forKey: "autoOpenPlaylist") }
        if ud.object(forKey: "confirmDelete")       != nil { confirmBeforeDelete  = ud.bool(forKey: "confirmDelete") }
        if ud.object(forKey: "hideMissing")         != nil { hideMissingTracks   = ud.bool(forKey: "hideMissing") }
        if ud.object(forKey: "alwaysOnTop")         != nil { alwaysOnTop         = ud.bool(forKey: "alwaysOnTop") }
        if ud.object(forKey: "magnifyEnabled")      != nil { magnifyEnabled      = ud.bool(forKey: "magnifyEnabled") }
        if ud.object(forKey: "magnifyProximity")    != nil { magnifyProximity    = ud.double(forKey: "magnifyProximity") }
        if ud.object(forKey: "magnifySpeed")        != nil { magnifySpeed        = ud.double(forKey: "magnifySpeed") }
    }

    func persistSettings() {
        let ud = Self.ud
        ud.set(volume,                  forKey: "volume")
        ud.set(pitchRange,              forKey: "pitchRange")
        ud.set(masterTempo,             forKey: "masterTempo")
        ud.set(repeatMode.rawValue,     forKey: "repeatMode")
        ud.set(windowScale,             forKey: "windowScale")
        ud.set(gradientMapHue,          forKey: "gradientMapHue")
        ud.set(gradientMapSaturation,   forKey: "gradientMapSat")
        ud.set(autoBPMOnImport,         forKey: "autoBPMOnImport")
        ud.set(bpmAnalysisFloor,        forKey: "bpmFloor")
        ud.set(bpmAnalysisCeiling,      forKey: "bpmCeiling")
        ud.set(autoPlayOnImport,        forKey: "autoPlay")
        ud.set(autoOpenPlaylistOnImport, forKey: "autoOpenPlaylist")
        ud.set(confirmBeforeDelete,     forKey: "confirmDelete")
        ud.set(hideMissingTracks,       forKey: "hideMissing")
        ud.set(snapEnabled,             forKey: "snapEnabled")
        ud.set(alwaysOnTop,             forKey: "alwaysOnTop")
        // Save base scale (not magnified override) so user preference is preserved
        ud.set(isMagnified ? magnifyBaseScale : windowScale, forKey: "windowScale")
        ud.set(magnifyEnabled,          forKey: "magnifyEnabled")
        ud.set(magnifyProximity,        forKey: "magnifyProximity")
        ud.set(magnifySpeed,            forKey: "magnifySpeed")
    }
}
