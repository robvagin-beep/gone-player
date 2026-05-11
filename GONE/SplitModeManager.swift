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
    private var snapWasEnabled = false   // snap state before Clone Mode disabled it

    // Serial queue for all secondary-engine ops — guarantees stop() from deactivation
    // always completes before setOutputDevice() from the next activation (no Core Audio race)
    private let audioOpQueue = DispatchQueue(label: "gone.split.audio", qos: .userInitiated)

    private init() {}

    // MARK: — Activate / Deactivate

    func activate(primaryWindow: NSWindow, primaryState: PlayerState) {
        guard !isActive else { return }
        self.primaryState = primaryState

        // Snap and Clone Mode are incompatible — disable snap (expands window if docked).
        // Remember the state so deactivate() can restore it.
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
        crossfade = 0.5
        primaryState?.audioEngine.crossfadeGain = 1.0
        // Clear callbacks BEFORE any teardown — prevents audio thread retaining [weak state]
        // while main thread zeros it during dealloc
        AudioEngineNext.secondary.onProgress = nil
        AudioEngineNext.secondary.onFinished = nil
        AudioEngineNext.secondary.onSpectrum = nil
        // Mark the engine as stopped on main before SwiftUI window teardown.
        // This prevents handleEngineConfigurationChange (fired by setOutputDevice on audioOpQueue)
        // from restarting playback after windows are closed.
        // Must NOT call pause()/playerNode.pause() here — it contests Core Audio's IO lock
        // with the concurrent setOutputDevice on audioOpQueue, causing a deadlock/freeze.
        AudioEngineNext.secondary.markStopped()
        // Stop any XY-effect timers on the secondary state before releasing it
        secondaryState?.stopLFO()
        secondaryState?.stopSlicer()
        secondaryState?.stopBPMChop()
        secondaryState?.cancelXYSpring()
        gapWindow?.close()
        gapWindow = nil
        secondWindow?.close()
        secondWindow = nil
        secondaryState = nil
        // Restore snap if it was active before Clone Mode disabled it
        if snapWasEnabled,
           let delegate = NSApp.delegate as? AppDelegate,
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
        // Create secondary PlayerState, copy full visual state from primary
        let state = PlayerState(engine: .secondary)
        state.tracks              = primaryState.tracks
        state.playlistTabs        = primaryState.playlistTabs
        state.activePlaylistTabId = primaryState.activePlaylistTabId
        state.currentId           = primaryState.currentId
        state.playlistOpen        = primaryState.playlistOpen
        state.eqOpen              = primaryState.eqOpen
        state.playlistPanelHeight = primaryState.playlistPanelHeight
        state.volume              = primaryState.volume
        secondaryState = state

        // Wire secondary engine callbacks into secondaryState
        let eng = AudioEngineNext.secondary
        eng.onProgress = { [weak state] progress, time in
            DispatchQueue.main.async {
                state?.progress    = progress
                state?.currentTime = time
                state?.progressFeed.progress    = progress
                state?.progressFeed.currentTime = time
            }
        }
        eng.onFinished = { [weak state] in
            DispatchQueue.main.async { state?.selectNextTrack() }
        }
        eng.onSpectrum = { [weak state] data in
            state?.spectrumFeed.data = data
        }

        // Snapshot A's full audio state into B engine.
        // Enqueued on audioOpQueue so any pending stop() from a prior deactivation drains first.
        let primaryDeviceID = AudioEngineNext.shared.currentOutputDeviceID()
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
        // Clone player one level above main player (overlayWindow+1=103) so the crossfader
        // panel at overlayWindow-1 (101) is hidden under both player windows at their endpoints.
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                  .fullScreenDisallowsTiling, .managed, .ignoresCycle]
        win.hidesOnDeactivate = false

        return win
    }
}
