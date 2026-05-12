import SwiftUI
import AppKit
import Combine

// ── SplitModeManager — manages ClonePlayer (two windows + crossfader) ──────────
@MainActor
final class SplitModeManager: ObservableObject {
    static let shared = SplitModeManager()

    @Published var isActive = false
    @Published var crossfade: Double = 0.5   // 0.0 = all A · 1.0 = all B
    @Published var geometryVersion: Int = 0  // incremented on window move/resize → triggers Canvas redraw

    private(set) var secondaryState: PlayerState?
    private var secondWindow: NSWindow?
    var secondaryWindow: NSWindow? { secondWindow }
    private var gapWindow: CrossfaderGapWindow?
    private weak var primaryState: PlayerState?
    private weak var primaryWindow: NSWindow?
    private var snapWasEnabled = false   // snap state before Clone Mode disabled it
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var stateObservers: Set<AnyCancellable> = []

    var bpmDelta: Double? {
        guard let a = primaryState?.current?.bpm,
              let b = secondaryState?.current?.bpm,
              a > 0,
              b > 0 else { return nil }
        return b - a
    }

    // Serial queue for all secondary-engine ops — guarantees stop() from deactivation
    // always completes before setOutputDevice() from the next activation (no Core Audio race)
    private let audioOpQueue = DispatchQueue(label: "gone.split.audio", qos: .userInitiated)

    private init() {}

    // MARK: — Activate / Deactivate

    func activate(primaryWindow: NSWindow, primaryState: PlayerState) {
        guard !isActive else { return }
        self.primaryState = primaryState
        self.primaryWindow = primaryWindow

        // Snap and Clone Mode are incompatible — disable snap (expands window if docked).
        // Remember the state so deactivate() can restore it.
        snapWasEnabled = primaryState.snapEnabled
        if snapWasEnabled {
            WindowSnapManager.shared.disable(window: primaryWindow)
        }

        isActive = true

        let win = makeSecondWindow(primaryState: primaryState, relativeTo: primaryWindow)
        secondWindow = win
        installStateObservers()

        positionWindows(primary: primaryWindow, secondary: win)

        let gap = CrossfaderGapWindow(manager: self, windowA: primaryWindow, windowB: win)
        gapWindow = gap
        installLifecycleObservers(primary: primaryWindow, secondary: win)

        updateCrossfade()

        // Order matters: gap window first (goes behind), then players on top
        gap.orderFront(nil)
        win.orderFront(nil)
        primaryWindow.orderFront(nil)
    }

    private func positionWindows(primary: NSWindow, secondary: NSWindow) {
        let pf  = primary.frame
        let sf  = secondary.frame
        let scr = (primary.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame

        let rightX = pf.maxX + gapWidth
        if rightX + sf.width <= scr.maxX {
            // Enough room — clone goes right, primary stays
            secondary.setFrameOrigin(NSPoint(x: rightX, y: pf.minY))
        } else {
            // Not enough room — center both windows together on screen
            let totalW = pf.width + gapWidth + sf.width
            let startX = max(scr.minX, min(scr.midX - totalW / 2, scr.maxX - totalW))
            primary.setFrameOrigin(NSPoint(x: startX, y: pf.minY))
            secondary.setFrameOrigin(NSPoint(x: startX + pf.width + gapWidth, y: pf.minY))
        }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        removeLifecycleObservers()
        stateObservers.removeAll()
        crossfade = 0.5
        primaryState?.audioEngine.crossfadeGain = 1.0
        // Clear callbacks BEFORE any teardown — prevents audio thread retaining [weak state]
        // while main thread zeros it during dealloc
        AudioEngineNext.secondary.onProgress = nil
        AudioEngineNext.secondary.onFinished = nil
        AudioEngineNext.secondary.onSpectrum = nil
        AudioEngineNext.secondary.onError    = nil
        // Mark the engine as stopped on main before SwiftUI window teardown.
        // This prevents handleEngineConfigurationChange (fired by setOutputDevice on audioOpQueue)
        // from restarting playback after windows are closed.
        // Must NOT call pause()/playerNode.pause() here — it contests Core Audio's IO lock
        // with the concurrent setOutputDevice on audioOpQueue, causing a deadlock/freeze.
        AudioEngineNext.secondary.markStopped()
        // Stop any momentary audio modifiers on secondary before releasing it
        secondaryState?.stopAllMomentaryAudioModifiers()
        gapWindow?.close()
        gapWindow = nil
        secondWindow?.close()
        secondWindow = nil
        primaryWindow = nil
        secondaryState = nil
        // Restore snap if it was active before Clone Mode disabled it
        if snapWasEnabled,
           let delegate = AppDelegate.shared,
           let win = delegate.resolvedMainWindow() {
            snapWasEnabled = false
            WindowSnapManager.shared.enable(window: win)
        } else {
            snapWasEnabled = false
        }
        // Full stop + buffer flush off main thread; serialized with any subsequent
        // setOutputDevice() from the next activate() via audioOpQueue
        audioOpQueue.async {
            AudioEngineNext.secondary.stop(resetProgress: false)
            AudioEngineNext.secondary.crossfadeGain = 1.0
        }
    }

    private func installLifecycleObservers(primary: NSWindow, secondary: NSWindow) {
        removeLifecycleObservers()
        let center = NotificationCenter.default
        for window in [primary, secondary] {
            let token = center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.deactivate()
                }
            }
            lifecycleObservers.append(token)
        }
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.forEach(center.removeObserver)
        lifecycleObservers.removeAll()
    }

    private func installStateObservers() {
        stateObservers.removeAll()
        guard let primary = primaryState, let secondary = secondaryState else { return }
        // Observe only BPM-relevant track changes on both players.
        // Subscribing to the full objectWillChange fires on every @Published mutation —
        // including during deactivation teardown — which can draw into a closing window.
        Publishers.CombineLatest(primary.$tracks, secondary.$tracks)
            .receive(on: RunLoop.main)
            .removeDuplicates { l, r in
                l.0.first(where: { $0.id == primary.currentId })?.bpm ==
                r.0.first(where: { $0.id == primary.currentId })?.bpm &&
                l.1.first(where: { $0.id == secondary.currentId })?.bpm ==
                r.1.first(where: { $0.id == secondary.currentId })?.bpm
            }
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &stateObservers)
    }

    // MARK: — Crossfade

    func setCrossfade(_ t: Double) {
        crossfade = min(1.0, max(0.0, t))
        updateCrossfade()
    }

    private func updateCrossfade() {
        let t = Float(crossfade)
        primaryState?.audioEngine.crossfadeGain  = cos(t * .pi / 2)
        AudioEngineNext.secondary.crossfadeGain  = cos((1.0 - t) * .pi / 2)
    }

    // MARK: — Window factory

    private let gapWidth: CGFloat = 60   // gap between the two player windows

    private func makeSecondWindow(primaryState: PlayerState, relativeTo primary: NSWindow) -> NSWindow {
        // Create secondary PlayerState, copy full visual + audio state from primary
        let state = PlayerState(engine: .secondary)
        // Playlist / navigation
        state.tracks              = primaryState.tracks
        state.playlistTabs        = primaryState.playlistTabs
        state.activePlaylistTabId = primaryState.activePlaylistTabId
        state.currentId           = primaryState.currentId
        state.playlistOpen        = primaryState.playlistOpen
        state.eqOpen              = primaryState.eqOpen
        state.playlistPanelHeight = primaryState.playlistPanelHeight
        // Transport
        state.volume              = primaryState.volume
        state.repeatMode          = primaryState.repeatMode
        state.shuffle             = primaryState.shuffle
        // Pitch / Tempo
        state.pitch               = primaryState.pitch
        state.pitchRange          = primaryState.pitchRange
        state.masterTempo         = primaryState.masterTempo
        state.pitchBypassed       = primaryState.pitchBypassed
        // EQ / DSP — mirrors what audioOpQueue sends to the engine
        state.eqOn                = primaryState.eqOn
        state.eqBands             = primaryState.eqBands
        state.eqPreamp            = primaryState.eqPreamp
        state.eqPreset            = primaryState.eqPreset
        state.hpfCutoff           = primaryState.hpfCutoff
        state.lpfCutoff           = primaryState.lpfCutoff
        state.reverbAmount        = primaryState.reverbAmount
        state.reverbPreset        = primaryState.reverbPreset
        // Debug — secondary onError is gated on debugMode; without this copy errors are silently dropped.
        state.debugMode           = primaryState.debugMode
        state.lastError           = primaryState.lastError
        secondaryState = state

        // Wire secondary engine callbacks into secondaryState
        let eng = AudioEngineNext.secondary
        eng.onProgress = { [weak state] progress, time in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                state?.progress    = progress
                state?.currentTime = time
                state?.progressFeed.update(progress: progress, currentTime: time)
                state?.enforceLoopIfNeeded(at: time)
            }
        }
        }
        eng.onFinished = { [weak state] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    state?.selectNextTrack()
                }
            }
        }
        eng.onSpectrum = { [weak state] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    state?.spectrumFeed.data = data
                }
            }
        }
        eng.onError = { [weak state] msg in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let s = state, s.debugMode else { return }
                    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    s.lastError = "[B/\(ts)] \(msg)"
                }
            }
        }

        // Snapshot A's full audio state into B engine.
        // Enqueued on audioOpQueue so any pending stop() from a prior deactivation drains first.
        let primaryDeviceID = primaryState.audioEngine.currentOutputDeviceID()
        let snapVol     = primaryState.volume
        let snapPitch   = primaryState.pitchBypassed ? 0.0 : primaryState.pitch
        let snapMT      = primaryState.masterTempo
        let snapPreamp  = primaryState.eqPreamp
        let snapBands   = primaryState.eqBands
        let snapEQOn    = primaryState.eqOn
        let snapReverb  = primaryState.eqOn ? primaryState.reverbAmount : 0
        let snapHPF     = primaryState.hpfCutoff
        let snapLPF     = primaryState.lpfCutoff
        audioOpQueue.async {
            AudioEngineNext.secondary.setOutputDevice(primaryDeviceID)
            AudioEngineNext.secondary.setVolume(snapVol)
            AudioEngineNext.secondary.setPitch(snapPitch, masterTempo: snapMT)
            AudioEngineNext.secondary.setEQ(preamp: snapPreamp, bands: snapBands)
            AudioEngineNext.secondary.setEQEnabled(snapEQOn)
            AudioEngineNext.secondary.setHPF(cutoff: snapHPF)
            AudioEngineNext.secondary.setLPF(cutoff: snapLPF)
            AudioEngineNext.secondary.setReverb(amount: snapReverb)
        }

        // ClonePlayerShell = same glass + drag handles + auto-resize, no primary window side-effects
        let content = ClonePlayerShell()
            .environmentObject(state)

        let hc = NSHostingController(rootView: content)

        // Match primary's current size exactly (panels already open)
        let initSize = primary.frame.size
        let win = NSWindow(
            contentRect: CGRect(origin: .zero, size: initSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hc
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isMovableByWindowBackground = false   // ClonePlayerShell has DragHandleNSView zones
        win.acceptsMouseMovedEvents = true
        win.appearance = NSAppearance(named: .darkAqua)
        // Clone player uses the same topmost level as the primary player.
        // Crossfader sits one level below both so window bodies hide its endpoints.
        win.level = GWindowLevel.player
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                  .fullScreenDisallowsTiling, .managed, .ignoresCycle]
        win.hidesOnDeactivate = false

        return win
    }
}
