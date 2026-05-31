import AppKit

/// NSPanel used for both primary and clone player windows.
///
/// Being a real NSPanel from construction (not an NSWindow with a patched styleMask)
/// is required for reliable fullscreen-Space overlay on macOS — the OS gives NSPanel
/// instances created with .nonactivatingPanel different Space-traversal semantics than
/// NSWindow instances whose styleMask is updated post-hoc.
final class FloatingPlayerPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
