import SwiftUI

// Design tokens matching the React handoff spec exactly

enum G {
    // ── Colors ────────────────────────────────────────────────────────────────
    static let bgWindow       = Color(hex: "#141414")
    static let bgPage         = Color(hex: "#0e0e0e")
    static let bgFloatingPanel = Color(hex: "#191919")
    static let bgPanelEQ      = Color.black.opacity(0.18)
    static let bgPanelPL      = Color.black.opacity(0.18)
    static let bgPitchRail    = Color.black.opacity(0.18)

    static let textPrimary    = Color.white
    static let textSecondary  = Color.white.opacity(0.78)
    static let textTertiary   = Color.white.opacity(0.55)
    static let textMuted      = Color.white.opacity(0.40)
    static let textFaint      = Color.white.opacity(0.28)
    static let textOnLight    = Color(hex: "#0d0d0d")

    static let accentPrimary  = Color.white.opacity(0.92)
    static let danger         = Color(hex: "#ff8a7a")
    static let warning        = Color(hex: "#d4a017")

    static let borderSubtle   = Color.white.opacity(0.06)
    static let borderDefault  = Color.white.opacity(0.08)
    static let borderStrong   = Color.white.opacity(0.14)

    static let hoverBg        = Color.white.opacity(0.04)
    static let currentBg      = Color(hex: "#4C4C4C")

    // ── Radii ─────────────────────────────────────────────────────────────────
    static let rWindowOuter:  CGFloat = 18
    static let rWindowInner:  CGFloat = 14
    static let rButtonPrimary: CGFloat = 10
    static let rButton:       CGFloat = 7
    static let rContextMenu:  CGFloat = 8
    static let rFloatingPanel: CGFloat = 10
    static let rPill:         CGFloat = 6
    static let rControl:      CGFloat = 5
    static let rBadge:        CGFloat = 4
    static let rFaderKnob:    CGFloat = 3
    static let rFaderKnobEQ:  CGFloat = 2
    static let rRow:          CGFloat = 3

    // ── Window widths ─────────────────────────────────────────────────────────
    static let windowWidth:   CGFloat = 460
    static let pitchRailWidth: CGFloat = 52

    // ── Fonts ─────────────────────────────────────────────────────────────────
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}
