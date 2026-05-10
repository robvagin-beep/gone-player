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
    private var gapWindow: CrossfaderGapWindow?
    private weak var primaryState: PlayerState?

    // Serial queue for all secondary-engine ops — guarantees stop() from deactivation
    // always completes before setOutputDevice() from the next activation (no Core Audio race)
    private let audioOpQueue = DispatchQueue(label: "gone.split.audio", qos: .userInitiated)

    private init() {}

    // MARK: — Activate / Deactivate

    func activate(primaryWindow: NSWindow, primaryState: PlayerState) {
        guard !isActive else { return }
        self.primaryState = primaryState
        isActive = true

        let win = makeSecondWindow(primaryState: primaryState, relativeTo: primaryWindow)
        secondWindow = win

        let gap = CrossfaderGapWindow(manager: self, windowA: primaryWindow, windowB: win)
        gapWindow = gap

        updateCrossfade()

        // Order matters: gap window first (goes behind), then players on top
        gap.orderFront(nil)
        win.orderFront(nil)
        primaryWindow.orderFront(nil)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        crossfade = 0.5
        primaryState?.audioEngine.crossfadeGain = 1.0
        // Clear callbacks BEFORE releasing state — prevents ARC priority inversion where
        // the audio thread spins retaining [weak state] while main thread zeros it during dealloc
        AudioEngineNext.secondary.onProgress = nil
        AudioEngineNext.secondary.onFinished = nil
        AudioEngineNext.secondary.onSpectrum = nil
        gapWindow?.close()
        gapWindow = nil
        secondWindow?.close()
        secondWindow = nil
        secondaryState = nil
        // stop() calls bufferQueue.sync — run on audioOpQueue so any subsequent
        // setOutputDevice() from the next activate() is serialized after this completes
        audioOpQueue.async {
            AudioEngineNext.secondary.stop()
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

        // Mirror primary output device — enqueued on audioOpQueue so any pending stop()
        // from a previous deactivation always drains first (no concurrent Core Audio access)
        let primaryDeviceID = AudioEngineNext.shared.currentOutputDeviceID()
        audioOpQueue.async {
            AudioEngineNext.secondary.setOutputDevice(primaryDeviceID)
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
        // Explicit screenSaverWindow level — both players float above all other apps
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.hidesOnDeactivate = false

        // Place B to the right of A with gapWidth spacing
        let pf  = primary.frame
        let scr = (primary.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let newX = pf.maxX + gapWidth
        if newX + initSize.width <= scr.maxX {
            win.setFrameOrigin(NSPoint(x: newX, y: pf.minY))
        } else {
            // Not enough room on right — place to the left of primary
            let leftX = pf.minX - gapWidth - initSize.width
            win.setFrameOrigin(NSPoint(x: max(scr.minX, leftX), y: pf.minY))
        }
        return win
    }
}
