import SwiftUI
import AppKit

// ── Tooltip bubble ────────────────────────────────────────────────────────────
struct GoneTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(G.mono(10, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.86))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "#222222"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
            )
    }
}

// ── Floating NSPanel — renders tooltip OUTSIDE the main player window ─────────
final class TooltipPanel {
    static let shared = TooltipPanel()
    private init() {}

    private var panel: NSPanel?
    private var hostController: NSHostingController<GoneTooltipBubble>?
    private var followTimer: Timer? = nil
    private var visibilityToken: UInt = 0

    @MainActor
    func show(text: String, near mouse: NSPoint) {
        visibilityToken &+= 1
        if let hc = hostController {
            hc.rootView = GoneTooltipBubble(text: text)
        } else {
            let hc = NSHostingController(rootView: GoneTooltipBubble(text: text))
            hostController = hc
        }
        guard let hc = hostController else { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask:   [.borderless, .nonactivatingPanel],
                backing:     .buffered,
                defer:       false
            )
            p.isOpaque           = false
            p.backgroundColor    = .clear
            p.hasShadow          = false
            p.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .ignoresCycle]
            p.hidesOnDeactivate  = false
            p.ignoresMouseEvents = true
            p.contentView        = hc.view
            panel = p
        }

        hc.view.layoutSubtreeIfNeeded()
        let size   = hc.view.fittingSize
        let origin = tooltipOrigin(size: size, mouse: mouse)

        panel!.setFrame(CGRect(origin: origin, size: size), display: false)
        if panel!.isVisible {
            panel!.alphaValue = 1
            panel!.orderFront(nil)
        } else {
            panel!.alphaValue = 0
            panel!.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel!.animator().alphaValue = 1
            }
        }

        startFollowing()
    }

    @MainActor
    func hide() {
        stopFollowing()
        guard let p = panel, p.isVisible else { return }
        visibilityToken &+= 1
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.visibilityToken == token else { return }
            self.panel?.orderOut(nil)
        })
    }

    // MARK: - Cursor following

    private func startFollowing() {
        followTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let size = panel.frame.size
                panel.setFrameOrigin(self.tooltipOrigin(size: size, mouse: NSEvent.mouseLocation))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
    }

    // MARK: - Positioning: right of cursor, 5px gap from cursor edge

    private func tooltipOrigin(size: CGSize, mouse: NSPoint) -> NSPoint {
        let x = mouse.x + 14   // cursor tip (~9px) + 5px gap
        let y = mouse.y - size.height / 2

        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let s = screen {
            return NSPoint(
                x: max(s.frame.minX + 6, min(s.frame.maxX - size.width - 6, x)),
                y: max(s.frame.minY + 6, min(s.frame.maxY - size.height - 6, y))
            )
        }
        return NSPoint(x: x, y: y)
    }
}

// ── Drag value bubble ─────────────────────────────────────────────────────────
struct DragValueBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(G.mono(11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.90))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: "#1e1e1e"))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
            )
    }
}

// ── Drag value panel — follows cursor, renders outside window ─────────────────
final class DragValuePanel {
    static let shared = DragValuePanel()
    private init() {}

    private var panel: NSPanel?
    private var hostController: NSHostingController<DragValueBubble>?

    @MainActor
    func show(text: String) {
        if let hc = hostController {
            hc.rootView = DragValueBubble(text: text)
        } else {
            let hc = NSHostingController(rootView: DragValueBubble(text: text))
            hostController = hc
        }
        guard let hc = hostController else { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque           = false
            p.backgroundColor    = .clear
            p.hasShadow          = false
            p.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .fullScreenDisallowsTiling, .ignoresCycle]
            p.hidesOnDeactivate  = false
            p.ignoresMouseEvents = true
            p.contentView        = hc.view
            panel = p
        }

        hc.view.layoutSubtreeIfNeeded()
        let size   = hc.view.fittingSize
        let mouse  = NSEvent.mouseLocation
        panel!.setFrame(CGRect(origin: origin(size: size, mouse: mouse), size: size), display: true)
        if !panel!.isVisible { panel!.orderFront(nil) }
    }

    @MainActor
    func hide() { panel?.orderOut(nil) }

    private func origin(size: CGSize, mouse: NSPoint) -> NSPoint {
        let x = mouse.x - size.width / 2   // horizontally centered on cursor
        let y = mouse.y + 20               // above cursor
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let s = screen {
            return NSPoint(
                x: max(s.frame.minX + 6, min(s.frame.maxX - size.width - 6, x)),
                y: max(s.frame.minY + 6, min(s.frame.maxY - size.height - 6, y))
            )
        }
        return NSPoint(x: x, y: y)
    }
}

// ── Modifier ──────────────────────────────────────────────────────────────────
private struct GoneTooltipModifier: ViewModifier {
    let text: String
    @State private var hoverTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hoverTask?.cancel()
                hoverTask = nil
                if inside {
                    guard NSEvent.pressedMouseButtons == 0 else { return }
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        guard !Task.isCancelled else { return }
                        TooltipPanel.shared.show(text: text, near: NSEvent.mouseLocation)
                    }
                } else {
                    TooltipPanel.shared.hide()
                }
            }
            // Cancel tooltip immediately when user clicks or starts dragging
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        hoverTask?.cancel()
                        hoverTask = nil
                        TooltipPanel.shared.hide()
                    }
            )
    }
}

extension View {
    func goneTooltip(_ text: String) -> some View {
        modifier(GoneTooltipModifier(text: text))
    }
}
