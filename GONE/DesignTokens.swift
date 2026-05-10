import SwiftUI

// Design tokens matching the React handoff spec exactly

enum G {
    // ── Colors ────────────────────────────────────────────────────────────────
    static let bgWindow       = Color(hex: "#141414")
    static let bgPage         = Color(hex: "#0e0e0e")
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

// ── Color from hex string ─────────────────────────────────────────────────────
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// ── Art swatch gradient (deterministic per track id index) ────────────────────
func artGradient(for index: Int) -> LinearGradient {
    let palettes: [(String, String)] = [
        ("#1a3320", "#2d5a36"),
        ("#3a1a1a", "#6e2424"),
        ("#1a2a3a", "#2a4a6e"),
        ("#3a2a1a", "#7a4a1a"),
        ("#2a1a3a", "#4a2a6a"),
        ("#3a3a1a", "#7a6a1a"),
        ("#1a3a3a", "#1a6a6a"),
        ("#2a2a2a", "#4a4a4a"),
    ]
    let p = palettes[abs(index) % palettes.count]
    return LinearGradient(
        colors: [Color(hex: p.0), Color(hex: p.1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// ── Format seconds → "m:ss" ───────────────────────────────────────────────────
func fmtTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let s = min(Int(seconds), 359999)
    return String(format: "%02d:%02d", s / 60, s % 60)
}

// ── Cursor on hover (shared across all views) ─────────────────────────────────
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }

    // ── Gradient map tint ────────────────────────────────────────────────────
    // Applied to every UI layer. ARCHITECTURAL RULE:
    // Track cover artwork (real NSImage from file) must NEVER be a descendant
    // of a view that receives .gradientMap(). It must always be a SIBLING at
    // the same HStack/ZStack level, because .blendMode(.color) penetrates all
    // descendants and cannot be overridden from within a child view.
    // Placeholder artwork (grey music-note icon) IS tinted intentionally.
    // Every ArtSwatchView with real artwork is marked:
    //   // GRADIENT MAP: EXEMPT — artwork sibling, not descendant
    func gradientMap(hue: Double, saturation: Double) -> some View {
        overlay {
            if saturation > 0.5 {
                Color(hue: hue / 360, saturation: saturation / 100, brightness: 0.5)
                    .blendMode(.color)
                    .allowsHitTesting(false)
            }
        }
    }
}
