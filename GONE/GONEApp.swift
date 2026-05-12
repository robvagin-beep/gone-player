import SwiftUI
import AppKit
import MediaPlayer
import Combine

@main
struct GONEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = PlayerState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onAppear { appDelegate.playerState = state }
        }
        .windowResizability(.automatic)
        .defaultSize(width: G.windowWidth + 8, height: 190)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// ── App Delegate — configures the chromeless window ──────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Static reference so code outside GONEApp (TransportView, PlaylistView etc.)
    // can reach the delegate without relying on NSApp.delegate cast, which breaks
    // with @NSApplicationDelegateAdaptor on some macOS/SwiftUI configurations.
    static private(set) weak var shared: AppDelegate?

    weak var playerState: PlayerState? {
        didSet {
            playerState?.loadPersistedSettings()
            bindAudioEngine()
            applyPlaybackSettings()
            // By the time playerState is set, onAppear has fired → window definitely exists.
            // Cache it now so resolvedMainWindow() is reliable from this point on.
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
            // Two-stage snap restore: preference was loaded above; arm WindowSnapManager
            // on the next tick once the window is fully configured.
            if playerState?.snapEnabled == true {
                DispatchQueue.main.async { [weak self] in self?.setSnapEnabled(true) }
            }
        }
    }
    private(set) weak var mainWindow: NSWindow?
    private var eventMonitor: Any?
    private var isUserResizing = false
    private var nowPlayingCancellables = Set<AnyCancellable>()
    private var settingsCancellables = Set<AnyCancellable>()
    var windowAnchorMaxY: CGFloat = 0
    private var isCorrectingFrame = false
    private var magnifyTimer: Timer? = nil
    private var magnifyBaseFrame: CGRect = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        installKeyMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        // overlayWindow (102) sits above all app windows and fullscreen-app Spaces without
        // the DRM-surface conflicts that screenSaverWindow (1000) can cause in expanded state.
        NSApp.windows.forEach {
            $0.alphaValue = 0
            $0.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            $0.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .managed, .ignoresCycle]
            $0.hidesOnDeactivate = false
        }
        DispatchQueue.main.async {
            guard let window = self.bestAvailableWindow() else { return }
            window.alphaValue = 0          // safety net if window appeared after the sync call
            self.configureWindow(window)
            // One extra tick for SwiftUI layout to settle, then fade in
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration      = 0.20
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        mainWindow = window
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false  // DragHandleNSView handles all window movement
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        applyPresencePolicy(to: window)
        window.setContentSize(NSSize(width: G.windowWidth + 8, height: 190))
        window.center()
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
        let clone = SplitModeManager.shared.secondaryWindow
        return NSApp.windows.filter { !($0 is NSPanel) && $0 !== clone }
    }

    private func bestAvailableWindow() -> NSWindow? {
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
        // overlayWindow (102): above all app windows and fullscreen-app Spaces.
        // DRM-safe for the expanded state. WindowSnapManager raises to screenSaverWindow
        // (1000) while docked so the tab clears the Space-transition compositor layer.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        // .canJoinAllSpaces: enrolls window in every Space including new fullscreen Spaces.
        // .fullScreenAuxiliary: required alongside canJoinAllSpaces for fullscreen Spaces
        //   on macOS 11+ — both flags together are the load-bearing pair.
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
    }

    @MainActor
    func setAlwaysOnTop(_ enabled: Bool) {
        playerState?.alwaysOnTop = enabled
        if let window = resolvedMainWindow() {
            applyPresencePolicy(to: window)
        }
    }

    @MainActor
    func setSnapEnabled(_ enabled: Bool) {
        guard let playerState else { return }
        guard let window = resolvedMainWindow() ?? bestAvailableWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        mainWindow = window

        if enabled {
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
                self?.playerState?.progressFeed.progress = progress
                self?.playerState?.progressFeed.currentTime = time
                PlaybackProgressFeed.shared.progress = progress
                PlaybackProgressFeed.shared.currentTime = time
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
                SpectrumFeed.shared.data = data
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
        guard state.currentId != nil else { return }
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
        PlaybackProgressFeed.shared.$currentTime
            .removeDuplicates()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
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
            state.$snapEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$snapInactivityDelay.map { _ in () }.eraseToAnyPublisher(),
            state.$snapAnimSpeed.map { _ in () }.eraseToAnyPublisher(),
            state.$snapTabWidth.map { _ in () }.eraseToAnyPublisher(),
            state.$debugMode.map { _ in () }.eraseToAnyPublisher(),
            state.$alwaysOnTop.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifyEnabled.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifyProximity.map { _ in () }.eraseToAnyPublisher(),
            state.$magnifySpeed.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(settingsA + settingsB)
            .sink { debouncedSave.send() }
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
