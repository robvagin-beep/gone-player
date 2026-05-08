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
    weak var playerState: PlayerState? {
        didSet {
            applyPlaybackSettings()
            if let window = resolvedMainWindow() {
                applyPresencePolicy(to: window)
            }
            setupRemoteCommands()
            setupNowPlayingObservation()
        }
    }
    private(set) weak var mainWindow: NSWindow?
    private var eventMonitor: Any?
    private var isUserResizing = false
    private var nowPlayingCancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bindAudioEngine()
        installKeyMonitor()
        // Run after SwiftUI finishes its own window setup
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            self.configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        mainWindow = window
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        applyPresencePolicy(to: window)
        window.setContentSize(NSSize(width: G.windowWidth + 8, height: 190))
        window.center()
    }

    func resolvedMainWindow() -> NSWindow? {
        if let mainWindow, mainWindow.isVisible, !mainWindow.isMiniaturized {
            return mainWindow
        }
        if let candidate = bestAvailableWindow() {
            mainWindow = candidate
            return candidate
        }
        return nil
    }

    private func bestAvailableWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.isVisible, !keyWindow.isMiniaturized {
            return keyWindow
        }
        if let mainAppWindow = NSApp.mainWindow, mainAppWindow.isVisible, !mainAppWindow.isMiniaturized {
            return mainAppWindow
        }
        if let visible = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return visible
        }
        return NSApp.windows.first
    }

    private func restoredWindowOrigin(for window: NSWindow) -> NSPoint? {
        guard UserDefaults.standard.object(forKey: "windowOriginX") != nil else { return nil }
        let x = UserDefaults.standard.double(forKey: "windowOriginX")
        let y = UserDefaults.standard.double(forKey: "windowOriginY")
        let size = window.frame.size
        // Find a screen that contains at least 80px of the window horizontally
        guard let screen = NSScreen.screens.first(where: { s in
            x + size.width > s.frame.minX + 80 && x < s.frame.maxX - 80
        }) ?? NSScreen.main else { return nil }
        return NSPoint(
            x: max(screen.frame.minX, min(screen.frame.maxX - size.width, x)),
            y: max(screen.frame.minY, min(screen.frame.maxY - size.height, y))
        )
    }

    private func applyPresencePolicy(to window: NSWindow) {
        let alwaysOnTop = playerState?.alwaysOnTop ?? true
        let snapActive  = playerState?.snapEnabled ?? false
        // Snap panel must float on every Space even if alwaysOnTop is off —
        // the whole point of the docked widget is that it follows the user everywhere.
        window.level = (alwaysOnTop || snapActive) ? .floating : .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
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
        guard playerState.snapEnabled != enabled || playerState.snapState == .off || playerState.snapState == .waiting else { return }

        guard let window = resolvedMainWindow() ?? bestAvailableWindow() ?? WindowSnapManager.shared.currentWindow else { return }
        mainWindow = window

        if enabled {
            WindowSnapManager.shared.enable(window: window)
        } else {
            WindowSnapManager.shared.disable(window: window)
        }
        applyPresencePolicy(to: window)
    }

    private func bindAudioEngine() {
        let engine = AudioEngineNext.shared
        engine.onProgress = { [weak self] progress, time in
            self?.playerState?.progress = progress
            self?.playerState?.currentTime = time
        }
        engine.onSpectrum = { [weak self] data in
            self?.playerState?.spectrumData = data
        }
        engine.onFinished = { [weak self] in
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
        applyPlaybackSettings()
    }

    private func applyPlaybackSettings() {
        guard let state = playerState else { return }

        let engine = AudioEngineNext.shared
        engine.setVolume(state.volume)
        engine.setPitch(state.pitch, masterTempo: state.masterTempo)
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

            switch event.keyCode {
            case 49: // space
                state.togglePlayback()
                return nil
            case 123: // left arrow
                state.selectPreviousTrack()
                return nil
            case 124: // right arrow
                state.selectNextTrack()
                return nil
            case 126: // up arrow → pitch +step
                let step = Double(state.pitchRange) / 16.0
                state.pitch = min(Double(state.pitchRange), ((state.pitch + step) * 10).rounded() / 10)
                AudioEngineNext.shared.setPitch(state.pitch, masterTempo: state.masterTempo)
                return nil
            case 125: // down arrow → pitch −step
                let step = Double(state.pitchRange) / 16.0
                state.pitch = max(-Double(state.pitchRange), ((state.pitch - step) * 10).rounded() / 10)
                AudioEngineNext.shared.setPitch(state.pitch, masterTempo: state.masterTempo)
                return nil
            default:
                return event
            }
        }
    }

    private func shouldHandleKeyboardEvent(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow != nil {
            return false
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false
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
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
        ]
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        saveWindowPosition()
    }

    private func saveWindowPosition() {
        guard let window = mainWindow,
              playerState?.snapEnabled != true else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: "windowOriginX")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "windowOriginY")
    }
}
