import SwiftUI
import AppKit

enum GWindowLevel {
    // Keep the player above normal app windows, but do not force it above
    // fullscreen Spaces. screenSaver-level windows can make the panel unstable
    // during launch/Space transitions on some macOS setups.
    static let player = NSWindow.Level.floating
    // Docked / peeking HUD: the minimal tab at the screen edge. Raised ABOVE
    // everything (incl. other apps' fullscreen Spaces) on purpose — it is a
    // low-interaction overlay, not a full window. Applied only while docked or
    // peeking by WindowSnapManager; reverted to .player on expand/disable.
    // screenSaverWindow + 1 (1001) — the pre-stabilization player level.
    static let dockedHUD = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let crossfader = NSWindow.Level(rawValue: player.rawValue - 1)
    static let floatingPanel = NSWindow.Level(rawValue: player.rawValue + 1)
    static let importPanel = NSWindow.Level(rawValue: player.rawValue + 2)
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
