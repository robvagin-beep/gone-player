import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowSnapManager {
    static let shared = WindowSnapManager()
    private init() {}

    typealias SnapState = PlayerState.SnapMode
    private(set) var snapState: SnapState = .off {
        didSet { playerState?.setSnapState(snapState) }
    }

    weak var playerState: PlayerState?

    // tabVisible, inactivityDelay, and anim durations are driven by PlayerState settings.
    // Fallbacks are the original hardcoded defaults.
    var tabVisible:      CGFloat { CGFloat(playerState?.snapTabWidth ?? 19) }
    private let peekVisible:     CGFloat = 90
    private let proximityZone:   CGFloat = 140
    var inactivityDelay: Double  { playerState?.snapInactivityDelay ?? 5.0 }
    private var animMul: Double  { playerState?.snapAnimSpeed ?? 1.0 }
    private var dockAnimDuration:   Double { 0.24 * animMul }
    private var peekAnimDuration:   Double { 0.18 * animMul }
    private var expandAnimDuration: Double { 0.24 * animMul }

    private var settingsCancellables = Set<AnyCancellable>()

    private var inactivityTimer:  Timer?
    private var proximityTimer:   Timer?
    private var slideTimer:       Timer?   // manual 60fps animation (NSAnimationContext unreliable off-screen)
    private var globalClickMon:   Any?
    private var activityMon:      Any?
    private var spaceChangeObs:   NSObjectProtocol?
    private var savedOrigin:      NSPoint?
    private var savedFrame:       NSRect?
    private var savedDockedY:     CGFloat?
    private var dockToken:        UInt64 = 0  // incremented per dock attempt; guards completion against rapid toggle
    private var savedWindowWidth: CGFloat?    // full width saved when shrinking to tabVisible at dock; nil outside snap lifecycle

    // Captured at enable(), used for the full lifecycle.
    private weak var snapWindow: NSWindow?

    // Frame lock — enforces snap X position even when SwiftUI calls setFrame internally.
    private var frameLockObserver: Any?
    private var frameLockX: CGFloat? = nil

    private var mainWindow: NSWindow? {
        AppDelegate.shared?.resolvedMainWindow()
    }
    var currentWindow: NSWindow? { snapWindow ?? mainWindow }

    // MARK: – Infrastructure

    private func clearInfrastructure() {
        settingsCancellables.removeAll()
        inactivityTimer?.invalidate(); inactivityTimer = nil
        proximityTimer?.invalidate();  proximityTimer  = nil
        slideTimer?.invalidate();      slideTimer = nil
        removeGlobalClickMonitor()
        removeActivityMonitor()
        removeSpaceChangeObserver()
        unlockFrame()
        savedWindowWidth = nil
        playerState?.isSnapping = false
    }

    // MARK: – Enable / Disable

    func enable(window: NSWindow) {
        guard playerState?.tracks.isEmpty != true else {
            playerState?.snapEnabled = false
            playerState?.snapTimerFeed.set(nil)
            snapState = .off
            return
        }
        clearInfrastructure()
        snapWindow   = window
        playerState?.snapEnabled = true
        savedOrigin  = window.frame.origin
        savedFrame   = window.frame
        savedDockedY = nil
        snapState = .waiting
        installActivityMonitor(window: window)
        installSpaceChangeObserver(window: window)
        startProximityTimer()
        // Inactivity countdown starts on first user action (via activity monitor),
        // not immediately — prevents snap firing right after launch or re-enable.

        // Live-bind settings: changes take effect immediately without requiring a disable/re-enable.
        if let ps = playerState {
            // Delay changed while countdown is running → reschedule from now.
            ps.$snapInactivityDelay
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self, self.inactivityTimer != nil,
                          let win = self.snapWindow ?? self.mainWindow else { return }
                    self.scheduleInactivityDock(window: win)
                }
                .store(in: &settingsCancellables)

            // Tab width changed while docked → reposition window to new edge offset.
            ps.$snapTabWidth
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self,
                          self.snapState == .docked || self.snapState == .peeking else { return }
                    self.constrainCurrentWindow()
                }
                .store(in: &settingsCancellables)
        }
    }

    func disable(window: NSWindow) {
        // In .expanded, restoreFromSnap() already ran inside expand() — calling it again here
        // would overwrite whatever the user changed manually in the expanded state.
        let needsRestore = snapState == .docked || snapState == .peeking
        // Restore to expanded presence level — drop the docked HUD elevation.
        window.level = GWindowLevel.player
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .managed, .ignoresCycle]
        // Cancel any in-flight dockToEdge completion — prevents a pending completion from
        // overwriting snapState/.docked and re-locking the frame after we've disabled snap.
        dockToken &+= 1
        let fullWidth = savedWindowWidth  // capture before clearInfrastructure nils it
        clearInfrastructure()
        // If we were docked at tabVisible width, restore full width before restoreFromSnap/animateTo.
        if let w = fullWidth, window.frame.width < w {
            let f = window.frame
            window.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: w, height: f.height), display: true)
        }
        playerState?.snapEnabled = false
        savedDockedY = nil
        playerState?.snapTimerFeed.set(nil)
        if needsRestore { playerState?.restoreFromSnap() }
        let target = savedOrigin ?? centeredOrigin(for: window)
        savedFrame  = nil
        snapWindow  = nil
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let window else { return }
            // Set snapState = .off here, after restoreFromSnap() has settled, so that
            // windowMoveAnchorUpdate cannot fire while the window is still at the docked
            // off-screen X position. Setting it now (just before animateTo) means the
            // first anchor update fires when the window is already at the target position.
            self.snapState = .off
            self.animateTo(window: window, origin: target)
        }
    }

    // MARK: – Frame Lock
    // Prevents any external setFrame (including SwiftUI's windowResizability pass)
    // from moving the window away from the docked X position.

    private func lockFrame(window: NSWindow, x: CGFloat) {
        unlockFrame()
        frameLockX = x
        frameLockObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            MainActor.assumeIsolated {
                guard let lockX = self.frameLockX else { return }
                if abs(window.frame.origin.x - lockX) > 0.5 {
                    window.setFrameOrigin(NSPoint(x: lockX, y: window.frame.origin.y))
                }
            }
        }
    }

    private func unlockFrame() {
        if let obs = frameLockObserver {
            NotificationCenter.default.removeObserver(obs)
            frameLockObserver = nil
        }
        frameLockX = nil
    }

    // MARK: – Inactivity

    private func scheduleInactivityDock(window: NSWindow) {
        // Settings panel counts as user activity — don't tick down while it's open
        guard SettingsPanel.shared.currentPanel?.isVisible != true else {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
            playerState?.snapTimerFeed.set(nil)
            return
        }
        inactivityTimer?.invalidate()
        playerState?.snapTimerFeed.set(Date())
        let timer = Timer(timeInterval: inactivityDelay, repeats: false) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let window,
                      self.snapState == .waiting || self.snapState == .expanded,
                      SettingsPanel.shared.currentPanel?.isVisible != true
                else { return }
                self.dockToEdge(window: window)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        inactivityTimer = timer
    }

    private func installActivityMonitor(window: NSWindow) {
        removeActivityMonitor()
        activityMon = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .scrollWheel, .keyDown, .mouseMoved]
        ) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                guard let self,
                      let window,
                      self.snapState == .waiting || self.snapState == .expanded,
                      !self.importPanelOpen
                else { return }
                if event.type == .mouseMoved {
                    guard window.frame.contains(NSEvent.mouseLocation) else { return }
                } else {
                    guard event.window == nil || event.window == window else { return }
                }
                self.scheduleInactivityDock(window: window)
            }
            return event
        }
    }

    private func removeActivityMonitor() {
        if let m = activityMon { NSEvent.removeMonitor(m); activityMon = nil }
    }

    // MARK: – Space Change Observer
    // The docked window extends beyond screen.maxX. The Space-transition compositor
    // can briefly reveal the off-screen body during swipes. Two defences:
    // (1) dockedHUD level puts the tab above the transition layer.
    // (2) This observer corrects any frame drift and kills visible artifacts
    //     the instant the transition completes.

    private func installSpaceChangeObserver(window: NSWindow) {
        removeSpaceChangeObserver()
        spaceChangeObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.handleSpaceChange(window: window)
            }
        }
    }

    private func removeSpaceChangeObserver() {
        if let obs = spaceChangeObs {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceChangeObs = nil
        }
    }

    private func handleSpaceChange(window: NSWindow) {
        guard snapState == .docked || snapState == .peeking || playerState?.isSnapping == true else { return }
        // Re-anchor only. The old 80ms alpha-flash hid a body artifact of the patched
        // NSWindow during Space transitions; the docked window is now a true panel
        // shrunk to tabVisible width, so there is no off-screen body to flash away.
        constrainSnapPosition(window: window)
    }

    // MARK: – State Transitions

    private func dockToEdge(window: NSWindow) {
        guard playerState?.tracks.isEmpty != true else {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
            playerState?.snapEnabled = false
            playerState?.snapTimerFeed.set(nil)
            snapState = .off
            return
        }
        guard let screen = screen(for: window) else { return }
        removeGlobalClickMonitor()

        let snapX = screen.frame.maxX - tabVisible

        // Slide starts first, panel collapse follows ~80ms later so the horizontal
        // motion is clearly perceived before the window shrinks.
        // isSnapping blocks updateWindowSize during slide so no Y-shift occurs.
        // snapState/.docked and lockFrame are set in completion so PeekPanelView appears
        // only once the window has reached the snap position.
        dockToken &+= 1
        let capturedToken = dockToken
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let screen = self.screen(for: window) else { return }
            // Capture savedFrame here (after isSnapping=true is about to be set) so that
            // any pending updateWindowSize that ran during the prior 1-tick gap is included.
            // This keeps savedFrame consistent with savedDockedY and prevents Y drift.
            self.savedFrame  = window.frame
            self.savedOrigin = window.frame.origin
            let y = self.savedDockedY ?? self.clampY(window.frame.origin.y, height: window.frame.height, screen: screen)
            self.savedDockedY = y
            self.playerState?.isSnapping = true
            self.slideOffScreen(window: window, to: NSPoint(x: snapX, y: y), duration: self.dockAnimDuration) { [weak self, weak window] in
                guard let self, let window, self.dockToken == capturedToken else { return }
                self.snapState = .docked
                self.lockFrame(window: window, x: snapX)
                // Keep isSnapping = true — guards updateWindowSize while window is at tabVisible width.
                // Shrink window to tabVisible so no content extends past screen.maxX → no Space bleed.
                self.savedWindowWidth = window.frame.width
                let f = window.frame
                window.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: self.tabVisible, height: f.height), display: true)
                // Docked tab is a low-interaction HUD → raise above everything (incl. fullscreen).
                window.level = GWindowLevel.dockedHUD
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                             .fullScreenDisallowsTiling, .transient, .ignoresCycle]
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                self?.playerState?.prepareForSnap()
            }
        }
    }

    // Smooth manual slide toward/away from the screen edge.
    // NSAnimationContext is unreliable for mostly-off-screen borderless windows:
    // the system skips or collapses the animation when the destination is beyond the display edge.
    // A 60fps timer with direct setFrameOrigin calls bypasses that constraint entirely.
    private func slideOffScreen(window: NSWindow, to origin: NSPoint, duration: Double, completion: (() -> Void)? = nil) {
        slideTimer?.invalidate()
        slideTimer = nil
        let startOrigin = window.frame.origin
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                let rawT = min(1.0, max(0.0, -startTime.timeIntervalSinceNow / duration))
                let eased = rawT < 0.5 ? 2 * rawT * rawT : -1 + (4 - 2 * rawT) * rawT
                let x = startOrigin.x + (origin.x - startOrigin.x) * CGFloat(eased)
                let y = startOrigin.y + (origin.y - startOrigin.y) * CGFloat(eased)
                window.setFrameOrigin(NSPoint(x: x, y: y))
                if rawT >= 1.0 {
                    window.setFrameOrigin(origin)
                    self.slideTimer?.invalidate()
                    self.slideTimer = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    // Same as slideOffScreen but interpolates the full frame (origin + size).
    // Used for expand — NSAnimationContext also fails when the window starts off-screen.
    // Easing: easeOut cubic — window bursts away from the edge and settles gently.
    private func slideFrameTo(window: NSWindow, frame target: NSRect, duration: Double, completion: (() -> Void)? = nil) {
        slideTimer?.invalidate()
        slideTimer = nil
        let startFrame = window.frame
        let startTime = Date()
        // Width/height are normally restored instantly before this is called (expand()),
        // so the animation is usually a pure move. setFrame(display: true) forces a full
        // SwiftUI layout + redraw every tick at 60fps on the main thread — only pay that
        // when the size actually animates.
        let sizeAnimates = abs(target.width  - startFrame.width)  > 0.5 ||
                           abs(target.height - startFrame.height) > 0.5
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                let rawT = min(1.0, max(0.0, -startTime.timeIntervalSinceNow / duration))
                let t = CGFloat(1.0 - pow(1.0 - rawT, 3.0))
                if sizeAnimates {
                    let newFrame = NSRect(
                        x:      startFrame.minX   + (target.minX   - startFrame.minX)   * t,
                        y:      startFrame.minY   + (target.minY   - startFrame.minY)   * t,
                        width:  startFrame.width  + (target.width  - startFrame.width)  * t,
                        height: startFrame.height + (target.height - startFrame.height) * t
                    )
                    window.setFrame(newFrame, display: true)
                } else {
                    window.setFrameOrigin(NSPoint(
                        x: startFrame.minX + (target.minX - startFrame.minX) * t,
                        y: startFrame.minY + (target.minY - startFrame.minY) * t
                    ))
                }
                if rawT >= 1.0 {
                    window.setFrame(target, display: true)
                    self.slideTimer?.invalidate()
                    self.slideTimer = nil
                    completion?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    // Used by proximity polling — no panel collapse, just position change.
    // Only slides horizontally; Y stays at current window position (respects user drag).
    private func slideTo(window: NSWindow, x: CGFloat) {
        slideOffScreen(window: window, to: NSPoint(x: x, y: window.frame.origin.y), duration: peekAnimDuration)
    }

    private func peek(window: NSWindow) {
        guard let screen = screen(for: window) else { return }
        // No withAnimation: the window slide (slideTo, 60fps timer) is the only motion. Animating
        // snapState-driven geometry here raced that timer, so the semi-transparent plate/border
        // lagged the window edge ("отстает"). peekContent keeps its own opacity .animation, so the
        // controls still fade in.
        snapState = .peeking  // set before the slide so the proximity poll can't re-trigger
        // Window width = just the peek panel (panel offset 6 + panelWidth 96 + corner bleed),
        // NOT the full player width. A full-width window keeps the entire player body hanging
        // past screen.maxX, and the Space-swipe compositor renders that off-screen body as a
        // floating fragment between desktops. Same principle as the docked tabVisible shrink.
        // The resize happens while the window sits at the screen edge → off-screen, invisible.
        let peekWindowWidth = peekVisible + 14
        if abs(window.frame.width - peekWindowWidth) > 0.5 {
            let f = window.frame
            window.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: peekWindowWidth, height: f.height), display: true)
        }
        slideTo(window: window, x: screen.frame.maxX - peekVisible)
    }

    private func dockFromProximity(window: NSWindow) {
        guard let screen = screen(for: window) else { return }
        let snapX = screen.frame.maxX - tabVisible
        let y = savedDockedY ?? clampY(window.frame.origin.y, height: window.frame.height, screen: screen)
        dockToken &+= 1
        let capturedToken = dockToken
        playerState?.isSnapping = true
        // Animate position only — avoids per-frame resize artifacts.
        // Shrink to tabVisible in completion when window is already at the screen edge (invisible).
        // Shorter duration than peek-in: off-screen slides are compositor-throttled,
        // so 0.12s looks crisper than 0.18s (macOS deprioritises going-off-screen windows).
        slideOffScreen(window: window, to: NSPoint(x: snapX, y: y), duration: 0.12 * animMul) { [weak self, weak window] in
            guard let self, let window, self.dockToken == capturedToken else { return }
            // No withAnimation — keep geometry instant, the slide is the motion (matches peek()).
            self.snapState = .docked
            // Window arrives from peek at peekWindowWidth, not full width — keep the widest
            // known width so expand() restores the real frame, never the peek sliver.
            self.savedWindowWidth = max(self.savedWindowWidth ?? 0, window.frame.width)
            let f = window.frame
            window.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: self.tabVisible, height: f.height), display: true)
            self.lockFrame(window: window, x: snapX)
            // Keep isSnapping = true — window stays at tabVisible width.
            // Docked tab is a low-interaction HUD → raise above everything (incl. fullscreen).
            window.level = GWindowLevel.dockedHUD
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .fullScreenDisallowsTiling, .transient, .ignoresCycle]
        }
    }

    func expand(window: NSWindow) {
        unlockFrame()  // allow window to move freely

        // Always return to the exact pre-dock frame. savedFrame is captured atomically
        // with savedDockedY (inside the dockToEdge async block), so they are consistent.
        // Using savedDockedY for Y caused upward drift: if updateWindowSize ran in the
        // 1-tick gap before isSnapping=true, savedDockedY got a higher Y than savedFrame.
        let targetFrame: NSRect
        if let saved = savedFrame {
            targetFrame = saved
        } else {
            let origin = centeredOrigin(for: window)
            let sz = NSSize(width: savedWindowWidth ?? window.frame.size.width, height: window.frame.size.height)
            targetFrame = NSRect(origin: origin, size: sz)
        }

        // Restore full width instantly before animating — window is still at screen edge so
        // the resize is invisible. Ensures slideFrameTo only animates position/height, not width,
        // which prevents macOS shadow/border compositor artifacts during the slide.
        if window.frame.width < targetFrame.width {
            let f = window.frame
            window.setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: targetFrame.width, height: f.height), display: false)
        }

        snapState = .expanded
        playerState?.isSnapping = true
        window.level = GWindowLevel.player
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .managed, .ignoresCycle]

        // Delay panel restore so the window travels away from the edge before content expands.
        // isSnapping blocks updateWindowSize, so the frame is controlled by slideFrameTo only.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.playerState?.restoreFromSnap()
        }

        slideFrameTo(window: window, frame: targetFrame, duration: expandAnimDuration) { [weak self, weak window] in
            guard let self else { return }
            self.playerState?.isSnapping = false
            if let window, !self.importPanelOpen {
                self.installGlobalClickMonitor(window: window)
                self.scheduleInactivityDock(window: window)
            }
        }
    }

    func constrainSnapPosition(window: NSWindow?) {
        guard let window, let screen = screen(for: window),
              snapState == .peeking || snapState == .docked else { return }
        let newY = clampY(window.frame.origin.y, height: window.frame.height, screen: screen)
        savedDockedY = newY
        let snapX = snapState == .peeking
            ? screen.frame.maxX - peekVisible
            : screen.frame.maxX - tabVisible
        if snapState == .docked {
            frameLockX = snapX
            // Enforce tabVisible width — prevents full-width body flash during Space transition.
            // Only corrects width; height stays as-is.
            if abs(window.frame.width - tabVisible) > 0.5 {
                window.setFrame(
                    NSRect(x: snapX, y: newY, width: tabVisible, height: window.frame.height),
                    display: false
                )
                return
            }
        }
        window.setFrameOrigin(NSPoint(x: snapX, y: newY))
    }

    func expandCurrentWindow() {
        guard let window = snapWindow ?? mainWindow else { return }
        expand(window: window)
    }

    func snapNow() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        playerState?.snapTimerFeed.set(nil)
        guard snapState == .waiting || snapState == .expanded,
              let window = snapWindow ?? mainWindow else { return }
        dockToEdge(window: window)
    }

    func constrainCurrentWindow() {
        constrainSnapPosition(window: snapWindow ?? mainWindow)
    }

    func dragSnappedWindowVertically(window: NSWindow?, startOrigin: NSPoint, startMouse: NSPoint, currentMouse: NSPoint) {
        guard let window,
              let screen = screen(for: window),
              snapState == .docked || snapState == .peeking else { return }

        let snapX = snapState == .peeking
            ? screen.frame.maxX - peekVisible
            : screen.frame.maxX - tabVisible
        let newY = clampY(startOrigin.y + currentMouse.y - startMouse.y, height: window.frame.height, screen: screen)
        savedDockedY = newY
        frameLockX = snapX
        window.setFrameOrigin(NSPoint(x: snapX, y: newY))
    }

    private(set) var importPanelOpen = false
    var isDragging = false

    func cancelSlide() {
        slideTimer?.invalidate()
        slideTimer = nil
    }

    func pauseForImport() {
        importPanelOpen = true
        inactivityTimer?.invalidate(); inactivityTimer = nil
        removeGlobalClickMonitor()
    }

    func resumeAfterImport() {
        importPanelOpen = false
        guard snapState == .waiting || snapState == .expanded,
              let window = snapWindow ?? mainWindow else { return }
        installGlobalClickMonitor(window: window)
        scheduleInactivityDock(window: window)
    }

    // MARK: – Proximity

    private func startProximityTimer() {
        proximityTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func pollProximity() {
        guard !isDragging,
              snapState == .docked || snapState == .peeking,
              let window = snapWindow ?? mainWindow,
              let screen = screen(for: window)
        else { return }

        let dist = screen.frame.maxX - NSEvent.mouseLocation.x
        if snapState == .docked,  dist <= proximityZone {
            unlockFrame()  // allow peek slide
            peek(window: window)
        }
        if snapState == .peeking, dist > proximityZone {
            dockFromProximity(window: window)  // applies lockFrame internally after animation
        }
    }

    // MARK: – Click Monitors

    private func installGlobalClickMonitor(window: NSWindow) {
        removeGlobalClickMonitor()
        globalClickMon = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] _ in
            Task { @MainActor [weak self] in
                guard let self, let window, !self.importPanelOpen else { return }
                self.removeGlobalClickMonitor()
                self.dockToEdge(window: window)
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let m = globalClickMon { NSEvent.removeMonitor(m); globalClickMon = nil }
    }

    // MARK: – Helpers

    private func animateTo(window: NSWindow, origin: NSPoint, duration: Double = 0.28, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrameOrigin(origin)
        } completionHandler: {
            completion?()
        }
    }

    private func animateFrameTo(window: NSWindow, frame: NSRect, duration: Double = 0.28, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion?()
        }
    }

    private func screen(for window: NSWindow) -> NSScreen? { window.screen ?? NSScreen.main }

    private func clampY(_ y: CGFloat, height: CGFloat, screen: NSScreen) -> CGFloat {
        max(screen.frame.minY, min(screen.frame.maxY - height, y))
    }

    private func centeredOrigin(for window: NSWindow) -> NSPoint {
        guard let screen = screen(for: window) else { return .zero }
        let sf = screen.visibleFrame
        return NSPoint(
            x: sf.midX - window.frame.width / 2,
            y: sf.midY - window.frame.height / 2
        )
    }
}
