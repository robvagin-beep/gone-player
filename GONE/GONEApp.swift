import SwiftUI
import AppKit
import MediaPlayer
import Combine

@main
struct GONEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The player UI lives in a FloatingPlayerPanel created by AppDelegate.
        // A true NSPanel (created .nonactivatingPanel) can overlay other apps'
        // fullscreen Spaces; a WindowGroup NSWindow with a patched styleMask cannot.
        // Settings is the only SwiftUI scene — it never shows a window on launch.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {}
            }
    }
}

// Reproduces the old WindowGroup placement: the fixed-size RootView is CENTERED in
// the hosting area. The display-scale math depends on this — scaleEffect shrinks the
// content around the view center, and updateWindowSize sizes the window to the scaled
// shell, so center-in-center makes the visual fill the window exactly. A top-leading
// placement made scaled content sit in the window's corner and the magnify spring
// jump/clip. Snapped windows keep full width, so no slice alignment is needed.
private struct HostingRoot: View {
    var body: some View {
        RootView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// Keeps the hosted SwiftUI view exactly the size of the window content area.
private final class HostingFillContainer: NSView {
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

// ── App Delegate — configures the chromeless window ──────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Static reference so code outside GONEApp (TransportView, PlaylistView etc.)
    // can reach the delegate without relying on NSApp.delegate cast, which breaks
    // with @NSApplicationDelegateAdaptor on some macOS/SwiftUI configurations.
    static private(set) weak var shared: AppDelegate?

    // Strong: AppDelegate owns the player state for the app's lifetime
    // (it used to be owned by a @StateObject in the WindowGroup scene).
    var playerState: PlayerState? {
        didSet {
            playerState?.loadPersistedSettings()
            bindAudioEngine()
            applyPlaybackSettings()
            // playerState is assigned after the panel is created and ordered front,
            // so resolvedMainWindow() is reliable from this point on.
            if mainWindow == nil || !(mainWindow?.isVisible ?? false) {
                mainWindow = bestAvailableWindow()
            }
            if let window = resolvedMainWindow() {
                applyPresencePolicy(to: window)
            }
            setupRemoteCommands()
            setupNowPlayingObservation()
            setupSettingsPersistence()
            if playerState?.magnifyEnabled == true { installMagnifyMonitor() }
            if playerState?.invisibleMode == true { installInvisibleMonitor() }
            // Snap is never armed automatically: snapEnabled always starts false
            // (not restored from UserDefaults) and is enabled per session via the bolt.
            if playerState?.restoreLastSession == true {
                Task { @MainActor [weak self] in
                    await self?.playerState?.restoreSession()
                }
            }
        }
    }
    private(set) weak var mainWindow: NSWindow?
    private var playerPanel: FloatingPlayerPanel?   // strong ref — keeps the primary panel alive
    private var eventMonitor: Any?
    private var isUserResizing = false
    private var nowPlayingCancellables = Set<AnyCancellable>()
    private var settingsCancellables = Set<AnyCancellable>()
    var windowAnchorMaxY: CGFloat = 0
    private var isCorrectingFrame = false
    private var magnifyTimer: Timer? = nil
    private var magnifyBaseFrame: CGRect = .zero
    private var invisibleTimer: Timer? = nil
    private var isGhosted = false
    private var lastMouseInsidePlayer = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // With Settings{} as the only SwiftUI scene, SwiftUI may downgrade the app's
        // activation policy during startup (no "real" windows from its point of view) —
        // in optimized Release launches this raced our panel bootstrap and the ordered
        // panel never reached the screen (process alive, zero WindowServer windows;
        // an NSLog "fixed" it by shifting timing). Pin the policy explicitly.
        NSApp.setActivationPolicy(.regular)
        installKeyMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        // Variant D bootstrap: build the panel directly, no WindowGroup placeholder,
        // no onAppear dependency, no alpha tricks (a 0-alpha "fade in later" once kept
        // the panel invisible forever — see commit 852d603).
        // PlayerState is created here and owned by AppDelegate; the panel hosts RootView
        // via NSHostingController — the exact construction the clone window already uses.
        // Deferred one main-loop tick: building the panel synchronously inside
        // didFinishLaunching raced app startup in RELEASE builds — the optimized start
        // was fast enough that the ordered panel intermittently never appeared (launch
        // via Finder/open showed zero windows; adding an NSLog "fixed" it by slowing
        // the path). One tick later NSApp/scene setup is complete and the order sticks.
        DispatchQueue.main.async { MainActor.assumeIsolated {
            let state = PlayerState()
            let panel = FloatingPlayerPanel(
                contentRect: NSRect(x: 0, y: 0, width: G.windowWidth + 8, height: 190)
            )
            // Window frame is owned by updateWindowSize + WindowSnapManager — the hosting
            // layer must NOT drive it. When NSHostingView IS the window's contentView,
            // NSHostingView.updateAnimatedWindowSize (from windowDidLayout) re-sizes the
            // window to the SwiftUI ideal size on every layout, fighting the snap
            // shrink-to-tab in an endless 21↔472 setFrame war (stack-traced 2026-06-10);
            // sizingOptions=[] does not disable that path. A plain NSView container in
            // between breaks the mechanism. topLeading alignment keeps the left content
            // slice (the peek tab) visible when the window is narrower than the content.
            let hosting = NSHostingView(rootView: HostingRoot().environmentObject(state))
            hosting.sizingOptions = []
            // HostingFillContainer pins hosting.frame = bounds in layout() — deterministic,
            // unlike autoresizing masks whose deltas from a zero-sized initial frame
            // produced garbage offsets (player showed a mid-content crop when docked).
            let container = HostingFillContainer()
            container.addSubview(hosting)
            panel.contentView = container
            self.playerPanel = panel
            self.configureWindow(panel)
            panel.makeKeyAndOrderFront(nil)
            self.playerState = state   // didSet runs full setup against the live panel
            // Belt and braces against any remaining startup ordering race: re-assert
            // the policy and the panel order once the launch dust settles. Idempotent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.setActivationPolicy(.regular)
                panel.orderFrontRegardless()
            }
        } }
    }

    private func configureWindow(_ window: NSWindow) {
        // Visual/behavioral properties (borderless, clear, non-movable, darkAqua,
        // hidesOnDeactivate=false) are set in FloatingPlayerPanel.init.
        mainWindow = window
        applyPresencePolicy(to: window)
        window.setContentSize(NSSize(width: G.windowWidth + 8, height: 190))
        window.center()
        // center() can land on half points (odd screen/window widths) — snap to whole
        // points so 1px hairlines render crisp from the very first frame.
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x.rounded(),
                                      y: window.frame.origin.y.rounded()))
        windowAnchorMaxY = window.frame.maxY
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResizeCorrection(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowMoveAnchorUpdate(_:)),
            name: NSWindow.didMoveNotification, object: window
        )
    }

    @objc private func windowResizeCorrection(_ note: Notification) {
        guard !isCorrectingFrame else { return }
        guard let state = playerState, !state.isSnapping else { return }
        guard state.snapState == .off || state.snapState == .waiting || state.snapState == .expanded else { return }
        guard let win = note.object as? NSWindow else { return }
        let anchor = windowAnchorMaxY
        guard anchor > 0, abs(win.frame.maxY - anchor) > 0.5 else { return }
        isCorrectingFrame = true
        var f = win.frame
        f.origin.y = anchor - f.height  // keep top (maxY) fixed, grow downward
        win.setFrame(f, display: false)
        isCorrectingFrame = false
    }

    @objc private func windowMoveAnchorUpdate(_ note: Notification) {
        guard !isCorrectingFrame else { return }
        guard let state = playerState, !state.isSnapping else { return }
        guard state.snapState == .off || state.snapState == .waiting || state.snapState == .expanded else { return }
        guard let win = note.object as? NSWindow else { return }
        windowAnchorMaxY = win.frame.maxY
    }

    func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.isVisible, !mainWindow.isMiniaturized {
            return mainWindow
        }
        let found = bestAvailableWindow()
        if let found { mainWindow = found }
        return found
    }

    private func primaryPlayerWindows() -> [NSWindow] {
        // Primary is now a FloatingPlayerPanel itself; exclude the clone window.
        // Other NSPanels (crossfader, tooltips, settings) are not FloatingPlayerPanel.
        let clone = SplitModeManager.shared.secondaryWindow
        return NSApp.windows.filter { $0 is FloatingPlayerPanel && $0 !== clone }
    }

    private func bestAvailableWindow() -> NSWindow? {
        // The owned panel is authoritative — NSApp.windows scanning is the fallback.
        if let playerPanel { return playerPanel }
        let windows = primaryPlayerWindows()
        if let keyWindow = NSApp.keyWindow,
           windows.contains(where: { $0 === keyWindow && keyWindow.isVisible && !keyWindow.isMiniaturized }) {
            return keyWindow
        }
        if let mainAppWindow = NSApp.mainWindow,
           windows.contains(where: { $0 === mainAppWindow && mainAppWindow.isVisible && !mainAppWindow.isMiniaturized }) {
            return mainAppWindow
        }
        if let visible = windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return visible
        }
        return windows.first
    }

    private func applyPresencePolicy(to window: NSWindow) {
        // While docked/peeking, WindowSnapManager owns presence: the HUD tab is raised
        // ABOVE everything (incl. fullscreen Spaces). Don't stomp it back to .floating —
        // every caller (becomeActive, screen-param change, wake, …) must respect it.
        let snapState = WindowSnapManager.shared.snapState
        if snapState == .docked || snapState == .peeking {
            window.level = GWindowLevel.dockedHUD
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .fullScreenDisallowsTiling, .transient, .ignoresCycle]
            window.hidesOnDeactivate = false
            return
        }
        // Always above normal app windows — a killer feature, not a setting (the player
        // is small; losing it between windows is the failure mode, Invisible mode is
        // the way to make it unobtrusive). .floating, stable across Space transitions.
        window.level = GWindowLevel.player
        // .canJoinAllSpaces: enrolls window in every Space including new fullscreen Spaces.
        // .fullScreenAuxiliary: shows over other apps' fullscreen Spaces — works now that
        //   the primary is a true FloatingPlayerPanel (NSPanel), not a patched NSWindow.
        // .managed: window appears as a proper tile in Mission Control (not invisible).
        //   Toggled to .transient by WindowSnapManager when window is docked off-screen.
        // .fullScreenDisallowsTiling: never captured by Split View.
        // .ignoresCycle: excluded from ⌘` window ring.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .managed, .ignoresCycle]
        window.hidesOnDeactivate = false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let window = resolvedMainWindow() { applyPresencePolicy(to: window) }
        // Cmd+Tab / app switch: slide out from edge automatically
        let snap = WindowSnapManager.shared
        if snap.snapState == .docked || snap.snapState == .peeking {
            snap.expandCurrentWindow()
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if let window = resolvedMainWindow() { applyPresencePolicy(to: window) }
    }

    @objc private func systemDidWake() {
        if let window = resolvedMainWindow() { applyPresencePolicy(to: window) }
        // Re-sync the audio engine(s): after sleep the HAL device and the player node's sample
        // clock can be stale and resume playback in lumps. Deferred ~0.4s so the audio hardware
        // has settled before we restart the I/O unit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AudioEngineNext.shared.handleSystemWake()
            if SplitModeManager.shared.secondaryState != nil {
                AudioEngineNext.secondary.handleSystemWake()
            }
        }
    }

    @MainActor
    func setSnapEnabled(_ enabled: Bool) {
        guard let playerState else { return }
        guard let window = resolvedMainWindow() ?? bestAvailableWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        mainWindow = window

        if enabled {
            guard !playerState.tracks.isEmpty else {
                playerState.snapEnabled = false
                playerState.snapTimerFeed.set(nil)
                return
            }
            // Always re-arm — repairs stale runtime even if snapEnabled is already true.
            WindowSnapManager.shared.enable(window: window)
        } else {
            // Only disable if something is actually running.
            guard playerState.snapEnabled || playerState.snapState != .off else { return }
            WindowSnapManager.shared.disable(window: window)
        }
        applyPresencePolicy(to: window)
    }

    private func bindAudioEngine() {
        guard let state = playerState else { return }
        let engine = state.audioEngine
        engine.onProgress = { [weak self] progress, time in
            DispatchQueue.main.async { [weak self] in
                self?.playerState?.progress = progress
                self?.playerState?.currentTime = time
                self?.playerState?.progressFeed.update(progress: progress, currentTime: time)
                self?.playerState?.enforceLoopIfNeeded(at: time)
            }
        }
        engine.onError = { [weak self] msg in
            DispatchQueue.main.async { [weak self] in
                guard let s = self?.playerState, s.debugMode else { return }
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                s.lastError = "[\(timestamp)] \(msg)"
            }
        }
        engine.onSpectrum = { [weak self] data in
            DispatchQueue.main.async { [weak self] in
                self?.playerState?.spectrumFeed.data = data
            }
        }
        engine.onFinished = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let state = self?.playerState else { return }
                switch state.repeatMode {
                case .one:
                    engine.seek(ratio: 0)
                    engine.play()
                case .all:
                    state.selectNextTrack()
                case .off:
                    let list = state.sortedTracks(forPlaylistTabId: state.playingTabId ?? state.activePlaylistTabId)
                    let available = list.indices.filter { !list[$0].isMissing }
                    if let lastAvailable = available.last,
                       list.firstIndex(where: { $0.id == state.currentId }) == lastAvailable {
                        state.isPlaying = false
                    } else {
                        state.selectNextTrack()
                    }
                }
            }
        }
        applyPlaybackSettings()
    }

    private func applyPlaybackSettings() {
        guard let state = playerState else { return }

        let engine = state.audioEngine
        engine.setVolume(state.volume)
        engine.setPitch(state.pitchBypassed ? 0 : state.pitch, masterTempo: state.masterTempo)
        engine.setEQ(preamp: state.eqPreamp, bands: state.eqBands)
        engine.setEQEnabled(state.eqOn)
        engine.setReverb(amount: state.eqOn ? state.reverbAmount : 0)
    }

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let state = self.playerState,
                  self.shouldHandleKeyboardEvent(event)
            else { return event }

            // Route space/arrows/seek to whichever player window is currently key.
            // Hot cues 1–4 always go to primary, 5–8 always go to secondary.
            let isSecondaryKey = SplitModeManager.shared.isActive &&
                NSApp.keyWindow != nil &&
                NSApp.keyWindow === SplitModeManager.shared.secondaryWindow
            let activeState: PlayerState = isSecondaryKey
                ? (SplitModeManager.shared.secondaryState ?? state)
                : state

            if let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "[":
                    activeState.setLoopA(at: activeState.audioEngine.snapshot().currentTime)
                    return nil
                case "]":
                    activeState.setLoopB(at: activeState.audioEngine.snapshot().currentTime)
                    return nil
                case "\\":
                    activeState.clearLoop()
                    return nil
                default:
                    break
                }
            }

            switch event.keyCode {
            case 18, 19, 20, 21: // keys 1–4 → hot cues for primary player
                let index = Int(event.keyCode) - 18   // 18→0, 19→1, 20→2, 21→3
                handleHotCue(index: index, for: state)
                return nil
            case 23: // key 5 → secondary cue 1
                handleHotCue(index: 0, forSecondary: true)
                return nil
            case 22: // key 6 → secondary cue 2
                handleHotCue(index: 1, forSecondary: true)
                return nil
            case 26: // key 7 → secondary cue 3
                handleHotCue(index: 2, forSecondary: true)
                return nil
            case 28: // key 8 → secondary cue 4
                handleHotCue(index: 3, forSecondary: true)
                return nil
            case 49: // space → toggle playback on focused player
                activeState.togglePlayback()
                return nil
            case 123: // left arrow → seek −5 s on focused player
                if let track = activeState.current, track.duration > 0 {
                    let t = max(0, activeState.progressFeed.currentTime - 5.0)
                    activeState.audioEngine.seek(ratio: t / track.duration)
                }
                return nil
            case 124: // right arrow → seek +5 s on focused player
                if let track = activeState.current, track.duration > 0 {
                    let t = min(track.duration, activeState.progressFeed.currentTime + 5.0)
                    activeState.audioEngine.seek(ratio: t / track.duration)
                }
                return nil
            case 126: // up arrow → playlist cursor (if open) or pitch +step on focused player
                if activeState.playlistOpen {
                    return event  // playlist key monitor handles: move cursor only, no autoplay
                }
                let stepUp = Double(activeState.pitchRange) / 16.0
                activeState.pitch = min(Double(activeState.pitchRange), ((activeState.pitch + stepUp) * 10).rounded() / 10)
                activeState.audioEngine.setPitch(activeState.pitchBypassed ? 0 : activeState.pitch, masterTempo: activeState.masterTempo)
                return nil
            case 125: // down arrow → playlist cursor (if open) or pitch −step on focused player
                if activeState.playlistOpen {
                    return event  // playlist key monitor handles: move cursor only, no autoplay
                }
                let stepDown = Double(activeState.pitchRange) / 16.0
                activeState.pitch = max(-Double(activeState.pitchRange), ((activeState.pitch - stepDown) * 10).rounded() / 10)
                activeState.audioEngine.setPitch(activeState.pitchBypassed ? 0 : activeState.pitch, masterTempo: activeState.masterTempo)
                return nil
            default:
                return event
            }
        }
    }

    private func handleHotCue(index: Int, for state: PlayerState) {
        // isLoaded too: in the gap between currentId assignment and engine load,
        // a cue tap would silently store ratio 0 ("start of track").
        guard state.currentId != nil, state.audioEngine.snapshot().isLoaded else { return }
        if let cue = state.hotCues[index] {
            state.audioEngine.seek(ratio: cue)
        } else {
            // Use real-time frame position — state.progress is 24fps-quantized (up to 41ms stale).
            state.hotCues[index] = state.audioEngine.currentPlaybackRatio
        }
    }

    private func handleHotCue(index: Int, forSecondary: Bool) {
        guard forSecondary,
              SplitModeManager.shared.isActive,
              let sec = SplitModeManager.shared.secondaryState
        else { return }
        handleHotCue(index: index, for: sec)
    }

    private func shouldHandleKeyboardEvent(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil { return false }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false
        }

        if let state = playerState {
            if state.pendingDropURLs != nil { return false }
            if state.isDraggingInternally { return false }
        }

        return true
    }

    // MARK: – Media Keys / Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.nextTrackCommand.removeTarget(nil)
        cc.previousTrackCommand.removeTarget(nil)

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            guard let s = self?.playerState, !s.isPlaying else { return .noSuchContent }
            s.togglePlayback(); return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let s = self?.playerState, s.isPlaying else { return .noSuchContent }
            s.togglePlayback(); return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playerState?.togglePlayback(); return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.playerState?.selectNextTrack(); return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.playerState?.selectPreviousTrack(); return .success
        }
    }

    private func setupNowPlayingObservation() {
        nowPlayingCancellables.removeAll()
        guard let state = playerState else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        Publishers.CombineLatest(state.$currentId, state.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateNowPlayingInfo() }
            .store(in: &nowPlayingCancellables)
        state.progressFeed.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateNowPlayingTiming() }
            .store(in: &nowPlayingCancellables)
        Publishers.CombineLatest3(state.$pitch, state.$masterTempo, state.$pitchBypassed)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateNowPlayingTiming() }
            .store(in: &nowPlayingCancellables)
    }

    private func updateNowPlayingTiming() {
        guard let state = playerState, state.current != nil,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? state.audioEngine.snapshot().rate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateNowPlayingInfo() {
        guard let state = playerState, let track = state.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? "—" : track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.currentTime,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? state.audioEngine.snapshot().rate : 0.0,
        ]
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MUST stay false: the player lives in a FloatingPlayerPanel, and AppKit does not
    // count NSPanels as windows for this check. With `true`, closing ANY transient
    // regular window (NSOpenPanel after picking folders, a future about box, …) reads
    // as "last window closed" and cleanly terminates the app mid-import. Quit is ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        playerState?.saveSession()
        playerState?.persistSettings()
        // Flush any pending cache writes before process exits.
        // flushSoon debounces to 1.5s — synchronous flush here captures the last analysis session.
        let sema = DispatchSemaphore(value: 0)
        Task { await AnalysisCache.shared.flushNow(); sema.signal() }
        _ = sema.wait(timeout: .now() + 2.0)
    }

    private func setupSettingsPersistence() {
        settingsCancellables.removeAll()
        guard let state = playerState else { return }

        let debouncedSave = PassthroughSubject<Void, Never>()
        debouncedSave
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                // Skip save when magnify is temporarily overriding windowScale
                guard let self, let s = self.playerState, !s.isMagnified else { return }
                s.persistSettings()
            }
            .store(in: &settingsCancellables)

        let settingsA: [AnyPublisher<Void, Never>] = [
            state.$volume.map { _ in () }.eraseToAnyPublisher(),
            state.$windowScale.map { _ in () }.eraseToAnyPublisher(),
            state.$gradientMapHue.map { _ in () }.eraseToAnyPublisher(),
            state.$gradientMapSaturation.map { _ in () }.eraseToAnyPublisher(),
            state.$autoBPMOnImport.map { _ in () }.eraseToAnyPublisher(),
            state.$bpmAnalysisFloor.map { _ in () }.eraseToAnyPublisher(),
            state.$bpmAnalysisCeiling.map { _ in () }.eraseToAnyPublisher(),
            state.$masterTempo.map { _ in () }.eraseToAnyPublisher(),
            state.$repeatMode.map { _ in () }.eraseToAnyPublisher(),
            state.$autoPlayOnImport.map { _ in () }.eraseToAnyPublisher(),
            state.$autoOpenPlaylistOnImport.map { _ in () }.eraseToAnyPublisher(),
        ]
        let settingsB: [AnyPublisher<Void, Never>] = [
            state.$confirmBeforeDelete.map { _ in () }.eraseToAnyPublisher(),
            state.$hideMissingTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$followCurrentTrack.map { _ in () }.eraseToAnyPublisher(),
            state.$snapInactivityDelay.map { _ in () }.eraseToAnyPublisher(),
            state.$snapDockLeft.map { _ in () }.eraseToAnyPublisher(),
            state.$snapAnimSpeed.map { _ in () }.eraseToAnyPublisher(),
            state.$snapTabWidth.map { _ in () }.eraseToAnyPublisher(),
            state.$debugMode.map { _ in () }.eraseToAnyPublisher(),
            state.$invisibleMode.map { _ in () }.eraseToAnyPublisher(),
            state.$invisibleOpacity.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifyEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifyProximity.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifySpeed.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(settingsA + settingsB)
            .sink { debouncedSave.send() }
            .store(in: &settingsCancellables)

        // Invisible mode toggle: install/remove the ghost monitor, restore alpha on disable.
        state.$invisibleMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.lastMouseInsidePlayer = Date()   // grace period before first fade
                    self.installInvisibleMonitor()
                } else {
                    self.removeInvisibleMonitor()
                    if let w = self.resolvedMainWindow() { self.setPlayerGhosted(false, window: w) }
                }
            }
            .store(in: &settingsCancellables)

        // Magnify toggle: install/remove proximity monitor
        state.$magnifyEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.installMagnifyMonitor()
                } else {
                    self.removeMagnifyMonitor()
                    self.magnifyBaseFrame = .zero
                    if let s = self.playerState, s.isMagnified {
                        s.isMagnified = false
                        withAnimation(.spring(response: s.magnifySpeed, dampingFraction: 0.8)) {
                            s.windowScale = s.magnifyBaseScale
                        }
                    }
                }
            }
            .store(in: &settingsCancellables)
    }

    // MARK: — Invisible mode (ghost opacity, hover to reveal)

    // Ghost opacity comes from Settings (18–100%); 0.18 is the floor and the default.
    private var ghostAlpha: CGFloat { CGFloat(max(18, min(100, playerState?.invisibleOpacity ?? 18)) / 100) }
    private let ghostFadeOutDelay: TimeInterval = 0.7   // hysteresis — no flicker when skimming past

    private func installInvisibleMonitor() {
        removeInvisibleMonitor()
        let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInvisibleFade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        invisibleTimer = timer
    }

    private func removeInvisibleMonitor() {
        invisibleTimer?.invalidate()
        invisibleTimer = nil
    }

    // Force the player back to full opacity (used when Clone Mode starts while ghosted).
    func forceUnghostPlayer() {
        guard let window = resolvedMainWindow() else { return }
        setPlayerGhosted(false, window: window)
    }

    private func checkInvisibleFade() {
        guard let state = playerState, state.invisibleMode, !state.isSnapping,
              !SplitModeManager.shared.isActive,
              let window = resolvedMainWindow() else { return }
        // Docked/peeking presence belongs to WindowSnapManager — never ghost the tab.
        guard state.snapState == .off || state.snapState == .waiting || state.snapState == .expanded else {
            setPlayerGhosted(false, window: window)
            return
        }
        // Stay visible while the user is in Settings or dragging the window.
        if SettingsPanel.shared.currentPanel?.isVisible == true || WindowSnapManager.shared.isDragging {
            setPlayerGhosted(false, window: window)
            return
        }
        let inside = window.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        if inside {
            lastMouseInsidePlayer = Date()
            setPlayerGhosted(false, window: window)
        } else if Date().timeIntervalSince(lastMouseInsidePlayer) > ghostFadeOutDelay {
            setPlayerGhosted(true, window: window)
        }
    }

    private func setPlayerGhosted(_ ghosted: Bool, window: NSWindow) {
        let target: CGFloat = ghosted ? ghostAlpha : 1.0
        // Re-animate when the ghost level itself changed (opacity slider while ghosted).
        guard ghosted != isGhosted || abs(window.alphaValue - target) > 0.01 else { return }
        isGhosted = ghosted
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ghosted ? 0.45 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = target
        }
    }

    // MARK: — Magnify proximity monitor

    private func installMagnifyMonitor() {
        removeMagnifyMonitor()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.checkMagnifyProximity()
        }
        RunLoop.main.add(timer, forMode: .common)
        magnifyTimer = timer
    }

    private func removeMagnifyMonitor() {
        magnifyTimer?.invalidate()
        magnifyTimer = nil
    }

    private func checkMagnifyProximity() {
        guard let state = playerState, state.magnifyEnabled, !state.isSnapping else { return }
        guard state.snapState == .off || state.snapState == .waiting || state.snapState == .expanded else { return }
        guard let window = resolvedMainWindow() else { return }

        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        let dx = max(0, max(frame.minX - mouse.x, mouse.x - frame.maxX))
        let dy = max(0, max(frame.minY - mouse.y, mouse.y - frame.maxY))
        let distance = sqrt(dx * dx + dy * dy)

        if !state.isMagnified && distance < state.magnifyProximity
            && state.windowScale < 0.99 {
            // Only magnify when there's actually a scale increase to show
            state.isMagnified = true
            state.magnifyBaseScale = state.windowScale
            withAnimation(.spring(response: state.magnifySpeed, dampingFraction: 0.8)) {
                state.windowScale = 1.0
            }
        } else if state.isMagnified && distance > 15 {
            // Exit when cursor is >15px outside the current (enlarged) window frame
            state.isMagnified = false
            magnifyBaseFrame = .zero
            withAnimation(.spring(response: state.magnifySpeed, dampingFraction: 0.8)) {
                state.windowScale = state.magnifyBaseScale
            }
        }
    }
}
