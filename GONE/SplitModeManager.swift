import SwiftUI
import AppKit
import Combine

// ── SplitModeManager — manages ClonePlayer (two windows + crossfader) ──────────
@MainActor
final class SplitModeManager: ObservableObject {
    static let shared = SplitModeManager()

    @Published var isActive = false
    @Published var isTransitioning = false   // true while activate/deactivate in flight — blocks re-entry
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
        guard !isActive, !isTransitioning else { return }
        isTransitioning = true
        self.primaryState = primaryState
        self.primaryWindow = primaryWindow

        snapWasEnabled = primaryState.snapEnabled
        if snapWasEnabled {
            WindowSnapManager.shared.disable(window: primaryWindow)
        }

        isActive = true

        let win = makeSecondWindow(primaryState: primaryState, relativeTo: primaryWindow)
        secondWindow = win
        positionWindows(primary: primaryWindow, secondary: win)

        let gap = CrossfaderGapWindow(manager: self, windowA: primaryWindow, windowB: win)
        gapWindow = gap
        installLifecycleObservers(primary: primaryWindow, secondary: win)

        updateCrossfade()

        gap.orderFront(nil)
        win.orderFront(nil)
        primaryWindow.orderFront(nil)

        // Hold isTransitioning for 300ms after activation.
        // The audioOpQueue enqueues setOutputDevice + audio state ops that must
        // complete before any deactivate() is safe. 300ms > typical device switch time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.isActive else { return }
            self.isTransitioning = false
        }
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
        guard isActive, !isTransitioning else { return }
        isTransitioning = true
        isActive = false

        // Step 1 — tear down observers and crossfader UI immediately.
        removeLifecycleObservers()
        crossfade = 0.5
        primaryState?.audioEngine.crossfadeGain = 1.0

        // Step 2 — sever all engine→UI callbacks before any teardown so no
        // audio-thread dispatch can write into a partially-deallocated state.
        AudioEngineNext.secondary.onProgress = nil
        AudioEngineNext.secondary.onFinished = nil
        AudioEngineNext.secondary.onSpectrum = nil
        AudioEngineNext.secondary.onError    = nil

        // Step 3 — mark stopped on main. Sets isUserPlaying=false so
        // handleEngineConfigurationChange won't restart playback. Must NOT call
        // playerNode.pause() here — Core Audio IO lock + audioOpQueue = deadlock.
        AudioEngineNext.secondary.markStopped()
        secondaryState?.stopAllMomentaryAudioModifiers()

        // Step 4 — close gap window (has its own observer + scroll monitor cleanup).
        gapWindow?.close()
        gapWindow = nil

        // Step 5 — capture strong refs so they survive the async close below,
        // then nil out manager properties immediately (decouples the manager).
        let pendingWindow = secondWindow
        let pendingState  = secondaryState
        secondWindow   = nil
        primaryWindow  = nil
        secondaryState = nil

        // Step 6 — restore snap synchronously while we still have a resolved window.
        if snapWasEnabled,
           let delegate = AppDelegate.shared,
           let win = delegate.resolvedMainWindow() {
            snapWasEnabled = false
            WindowSnapManager.shared.enable(window: win)
        } else {
            snapWasEnabled = false
        }

        // Step 7 — CRITICAL ORDER: stop engine first, THEN close window.
        // suppressConfigChange=true before enqueueing stop() so that setOutputDevice()
        // from a prior activate() cannot fire handleEngineConfigurationChange() →
        // ensureEngineRunning() concurrently with playerNode.stop() → EXC_BAD_ACCESS.
        // suppressConfigChange is also set on .shared (primary) to prevent it from reacting
        // to any AVAudioEngineConfigurationChange that the secondary teardown may emit on
        // a shared output device — such a reaction calls engine.start() + bufferQueue.sync
        // (disk I/O) on the main thread, freezing the UI and starving the primary render thread.
        AudioEngineNext.shared.suppressConfigChange = true
        AudioEngineNext.secondary.suppressConfigChange = true
        audioOpQueue.async { [weak self] in
            // No drain: bumpToken() already cancelled in-flight scheduling.
            // engine.stop() (below) is a full HAL disconnect and safely races with any
            // remaining scheduleBuffer calls on bufferQueue — no sync barrier needed.
            AudioEngineNext.secondary.stop(resetProgress: false)
            // Full engine shutdown: releases the shared hardware I/O slot so the secondary
            // render thread cannot starve the primary engine or trigger spurious config-changes.
            AudioEngineNext.secondary.stopEngine()
            AudioEngineNext.secondary.crossfadeGain = 1.0
            // Re-enable primary config-change handler now that secondary is fully off HAL.
            DispatchQueue.main.async {
                AudioEngineNext.shared.suppressConfigChange = false
            }
            // isTransitioning = false at T+1.8s — cancels all SwiftUI repeatForever/TimelineView
            // animations in the secondary window BEFORE close() releases the view hierarchy.
            // The 0.2s gap gives SwiftUI one render cycle to tear down animations cleanly,
            // preventing the EXC_BAD_ACCESS in objc_msgSend on a freed NSHostingController.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.isTransitioning = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                pendingWindow?.close()
                _ = pendingState       // keep state alive until after window close
            }
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
                    guard let self, self.isActive, !self.isTransitioning else { return }
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
        geometryVersion += 1

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
                    // Guard: skip if deactivate() already ran and nilled out secondaryState.
                    // This closes the race where a buffer completion dispatch was queued
                    // before onFinished = nil in deactivate(), then runs after the state
                    // is torn down — causing selectNextTrack → play → engine.start()
                    // concurrent with audioOpQueue stop() → EXC_BAD_ACCESS.
                    guard let s = state, s === SplitModeManager.shared.secondaryState else { return }
                    s.selectNextTrack()
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
        // Re-enable config-change handler before any audio ops so the secondary engine
        // can recover from graph resets normally once it's fully running again.
        AudioEngineNext.secondary.suppressConfigChange = false

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
