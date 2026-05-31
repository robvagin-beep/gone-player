import AppKit
import SwiftUI

// MARK: – Fullscreen Companion
//
// A non-activating NSPanel that mirrors the mini player and CAN render over other apps'
// native fullscreen Spaces — something a regular NSWindow cannot do, no matter its level.
// (See FloatingPlayerPanel: a panel created .nonactivatingPanel gets different Space-traversal
//  semantics than a window whose styleMask is patched after the fact.)
//
// Shown only while the player is docked/peeking AND the active Space is a fullscreen Space.
// On normal desktops the real docked tab follows via .canJoinAllSpaces (with hover-peek + drag),
// so the companion stays hidden there and we never show two tabs at once.
//
// Behaviour (matches the agreed "без якоря" design):
//   • 3 transport buttons drive the SAME PlayerState in place. The panel is non-activating,
//     so tapping them does NOT pull focus or switch Space — you keep watching fullscreen.
//   • A tap anywhere on the body activates GONE + expands the player. Activating a regular app
//     from inside another app's fullscreen Space makes macOS leave fullscreen and return to the
//     desktop where the player lives — i.e. "go home", without anchoring the real window.
@MainActor
final class FullscreenCompanionManager {
    static let shared = FullscreenCompanionManager()
    private init() {}

    weak var playerState: PlayerState?

    private var panel: FloatingPlayerPanel?
    private var spaceObs: NSObjectProtocol?
    private var armed = false

    private let panelWidth:  CGFloat = 96
    private let panelHeight: CGFloat = 156

    // MARK: Lifecycle (called by WindowSnapManager)

    /// Arm while docked/peeking: start watching Space changes and show the companion if we're
    /// already sitting on a fullscreen Space. Idempotent — re-arming just re-evaluates.
    func arm(state: PlayerState?) {
        guard let state else { return }
        playerState = state
        guard !armed else { evaluate(); return }
        armed = true
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    /// Disarm on expand / snap-off: hide the companion and stop watching.
    func disarm() {
        armed = false
        if let obs = spaceObs {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObs = nil
        }
        hide()
    }

    // MARK: Show / hide decision

    private func evaluate() {
        guard armed, playerState != nil, isFullscreenSpace() else { hide(); return }
        show()
    }

    /// Heuristic fullscreen-Space detection (no private API): on a fullscreen Space the menu bar
    /// is hidden and there is no Dock inset, so visibleFrame == frame. On a normal desktop the
    /// menu bar (and usually the Dock) inset visibleFrame. The `!NSApp.isActive` gate suppresses
    /// false positives while the user is actually interacting with GONE on its own desktop.
    private func isFullscreenSpace() -> Bool {
        guard !NSApp.isActive, let s = NSScreen.main else { return false }
        let menuBarHidden = (s.frame.height - s.visibleFrame.height) < 5
        let noDockInset   = abs(s.frame.minY - s.visibleFrame.minY) < 5
        return menuBarHidden && noDockInset
    }

    private func show() {
        let p = ensurePanel()
        positionPanel(p)
        p.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    // MARK: Panel construction

    private func ensurePanel() -> FloatingPlayerPanel {
        if let p = panel { return p }
        let p = FloatingPlayerPanel(contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        let content = CompanionTabView(onHome: { [weak self] in self?.goHome() })
            .environmentObject(playerState ?? PlayerState(engine: .shared))
        p.contentViewController = NSHostingController(rootView: content)
        // Above everything, on every Space incl. fullscreen — the panel is non-activating so it
        // never steals focus or forces a Space switch when it appears.
        p.level = GWindowLevel.dockedHUD
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        panel = p
        return p
    }

    private func positionPanel(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.maxX - panelWidth
        // Vertically align to the real docked tab's centre so it reads as the same tab; fall back
        // to screen centre when the docked frame is unavailable.
        let ref = WindowSnapManager.shared.currentWindow?.frame
        let centreY = (ref?.midY) ?? screen.frame.midY
        let y = max(screen.frame.minY, min(screen.frame.maxY - panelHeight, centreY - panelHeight / 2))
        p.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)
    }

    // MARK: Body tap → home

    private func goHome() {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        WindowSnapManager.shared.expandCurrentWindow()
    }
}

// MARK: – Companion view (mirrors the peek tab visual)

struct CompanionTabView: View {
    @EnvironmentObject var state: PlayerState
    let onHome: () -> Void

    @State private var prevHovered = false
    @State private var nextHovered = false

    var body: some View {
        ZStack {
            // Glass body — a tap anywhere that isn't a transport button takes you home.
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .fill(G.bgWindow)
                .overlay(peekTint)
                .overlay(
                    RoundedRectangle(cornerRadius: G.rWindowInner)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: G.rWindowInner)
                        .stroke(Color.black.opacity(0.6), lineWidth: 1)
                        .blur(radius: 0.2)
                )
                .contentShape(Rectangle())
                .onTapGesture { onHome() }

            VStack(spacing: 5) {
                artworkArea
                    .contentShape(Rectangle())
                    .onTapGesture { onHome() }

                MarqueeText(text: titleLine, fontSize: 8.5, colorOpacity: 0.92)
                    .frame(height: 11)
                    .contentShape(Rectangle())
                    .onTapGesture { onHome() }
                    .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)

                HStack(spacing: 0) {
                    Button { state.selectPreviousTrack() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(prevHovered ? 0.09 : 0))
                                .frame(width: 12, height: 24)
                                .animation(.easeInOut(duration: 0.12), value: prevHovered)
                            Image(systemName: "backward.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(G.textSecondary)
                        }
                        .frame(width: 20, height: 22)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))
                    .onHover { prevHovered = $0 }

                    Button {
                        guard let t = state.current, !t.isMissing else { return }
                        state.togglePlayback()
                    } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(G.textOnLight)
                            .frame(width: 24, height: 24)
                            .background(G.accentPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.88))

                    Button { state.selectNextTrack() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(nextHovered ? 0.09 : 0))
                                .frame(width: 12, height: 24)
                                .animation(.easeInOut(duration: 0.12), value: nextHovered)
                            Image(systemName: "forward.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(G.textSecondary)
                        }
                        .frame(width: 20, height: 22)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PeekSpringButton(scale: 0.78))
                    .onHover { nextHovered = $0 }
                }
                .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)

                if let bpm = currentBPM {
                    PeekBPMBar(label: bpm, progress: state.progressFeed.progress)
                        .frame(width: 54, height: 12)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { onHome() }
                        .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
                }
            }
            .frame(width: 78)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var peekTint: some View {
        if state.gradientMapSaturation > 0.5 {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hue: state.gradientMapHue / 360, saturation: state.gradientMapSaturation / 100, brightness: 0.22).opacity(0.44), location: 0.0),
                            .init(color: Color(hue: state.gradientMapHue / 360, saturation: state.gradientMapSaturation / 100, brightness: 0.10).opacity(0.22), location: 1.0),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var artworkArea: some View {
        if state.current?.hasArtwork == true {
            ArtSwatchView(
                index: trackIndex,
                size: 40,
                cornerRadius: 7,
                hasArtwork: true,
                trackId: state.current?.id,
                showsBrandPlaceholder: false
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                PixelSpectrumView(feed: state.spectrumFeed, isPlaying: state.isPlaying)
                    .padding(5)
            }
            .frame(width: 40, height: 40)
            .gradientMap(hue: state.gradientMapHue, saturation: state.gradientMapSaturation)
        }
    }

    private var trackIndex: Int {
        state.tracks.firstIndex(where: { $0.id == state.currentId }) ?? 0
    }

    private var currentBPM: String? {
        guard let t = state.current, t.bpm > 0 else { return nil }
        let bpm = state.pitch == 0 ? t.bpm : t.bpm * (1 + state.pitch / 100)
        return "\(Int(bpm.rounded())) BPM"
    }

    private var titleLine: String {
        guard let track = state.current else { return "—" }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return track.title }
        return "\(track.title) / \(artist)"
    }
}
