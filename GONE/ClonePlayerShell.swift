import SwiftUI
import AppKit

// ── ClonePlayerShell — identical glass shell for the second player window ──────
// Replicates RootView's visual structure without window-management side-effects:
// - no updateWindowSize touching the primary window
// - no WindowSnapManager interaction
// - no file drop zone (user drags from primary's playlist instead)
struct ClonePlayerShell: View {
    @EnvironmentObject var state: PlayerState

    private let shellInsetX:      CGFloat = 6
    private let shellInsetTop:    CGFloat = 6
    private let shellInsetBottom: CGFloat = 6
    private let outerRadius:      CGFloat = G.rWindowOuter + 3

    // Window captured via NSViewRepresentable once the view is in the hierarchy
    @State private var myWindow: NSWindow?

    // Desired content size (mirrors RootView.playerContentSize / shellSize)
    private var contentSize: CGSize {
        let baseH = FullPlayerView.baseHeight
        let eqH: CGFloat   = !state.tracks.isEmpty && state.eqOpen   ? FullPlayerView.eqPanelHeight : 0
        let listH: CGFloat = !state.tracks.isEmpty && state.playlistOpen ? state.playlistPanelHeight : 0
        return CGSize(width: G.windowWidth, height: baseH + eqH + listH)
    }

    private var shellSize: CGSize {
        CGSize(
            width:  contentSize.width  + shellInsetX * 2,
            height: contentSize.height + shellInsetTop + shellInsetBottom
        )
    }

    var body: some View {
        ZStack(alignment: .top) {

            // ── Glass layer 1 — subtle white fill ─────────────────────────────
            RoundedRectangle(cornerRadius: outerRadius)
                .fill(Color.white.opacity(0.028))
                .blur(radius: 0.08)

            // ── Glass layer 2 — gradient + border ─────────────────────────────
            RoundedRectangle(cornerRadius: outerRadius)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.22), location: 0),
                            .init(color: .white.opacity(0.10), location: 0.18),
                            .init(color: .white.opacity(0.06), location: 0.5),
                            .init(color: .white.opacity(0.04), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: outerRadius)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: outerRadius)
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                        .mask(
                            LinearGradient(
                                colors: [.white, .white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .shadow(color: .black.opacity(0.36), radius: 10, x: 0, y: 1)
                .shadow(color: .black.opacity(0.18), radius: 3,  x: 0, y: 0)

            // ── Content ───────────────────────────────────────────────────────
            FullPlayerView()
                .frame(width: G.windowWidth)
                .padding(.horizontal, shellInsetX)
                .padding(.top,        shellInsetTop)
                .padding(.bottom,     shellInsetBottom)
                .frame(width: shellSize.width, height: shellSize.height, alignment: .top)

            // ── Drag handles — same zones as primary (moves THIS window) ──────
            WindowBorderDragOverlay(hasContent: !state.tracks.isEmpty)

            // ── Playlist resize handle ─────────────────────────────────────────
            if !state.tracks.isEmpty && state.playlistOpen {
                BottomResizeHandle(eqOpen: state.eqOpen, windowScale: 1.0) { newH in
                    state.playlistPanelHeight = max(160, min(700, newH)) // MIRROR: RootView.swift
                }
                .frame(height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: shellSize.width, height: shellSize.height, alignment: .top)
        .background(Color.clear)
        // Capture window reference once the view is in the hierarchy
        .background(
            WindowRefCapture { w in
                myWindow = w
                // Reconcile size at capture time: shellSize may have changed
                // while myWindow was still nil, so the .onChange never fired.
                resizeWindow(to: shellSize, window: w)
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        )
        // Auto-resize clone window when panels open/close
        .onChange(of: shellSize) { newSize in
            resizeWindow(to: newSize)
        }
        .onDisappear {
            myWindow = nil
        }
    }

    private func resizeWindow(to size: CGSize, window: NSWindow? = nil) {
        guard let w = window ?? myWindow else { return }
        let current = w.frame
        guard abs(current.height - size.height) > 0.5 ||
              abs(current.width  - size.width)  > 0.5 else { return }
        var f = current
        f.origin.y = current.maxY - size.height   // top-fixed, grows downward
        f.size = size
        // Clamp to screen. When content exceeds screen height, pin top on screen
        // and let bottom overflow rather than pushing the header off the top.
        if let screen = w.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            if f.size.height > vis.height {
                f.origin.y = vis.maxY - f.size.height
            } else {
                f.origin.y = max(vis.minY, min(vis.maxY - f.size.height, f.origin.y))
            }
        }
        w.setFrame(f, display: true, animate: true)
    }
}

// ── NSViewRepresentable that captures the containing NSWindow ─────────────────
private struct WindowRefCapture: NSViewRepresentable {
    let onCapture: (NSWindow) -> Void

    func makeNSView(context: Context) -> _CaptureView {
        _CaptureView(callback: onCapture)
    }
    func updateNSView(_ nsView: _CaptureView, context: Context) {
        nsView.callback = onCapture
    }

    final class _CaptureView: NSView {
        var callback: (NSWindow) -> Void

        init(callback: @escaping (NSWindow) -> Void) {
            self.callback = callback
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            callback(w)
        }
    }
}
