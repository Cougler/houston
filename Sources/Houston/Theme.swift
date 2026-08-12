import AppKit
import SwiftUI

/// Design tokens. Light values come from the Figma design; dark values are
/// the same design translated to a #1E1E1E surface. Every token is a dynamic
/// color, so switching the app appearance restyles everything live.
enum Theme {

    // MARK: - Surfaces

    /// Window / sidebar / detail background.
    static let background = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    /// Floating cards (skills panel).
    static let panelFill = Color(light: 0xFFFFFF, dark: 0x262626)
    /// The faded helmet on the empty state.
    static let watermark = Color(light: 0xEBEBEB, dark: 0x323232)

    // MARK: - Text

    static let text = Color(light: 0x111111, dark: 0xE8E8E8)
    /// Server row subtitle.
    static let textSecondary = Color(light: 0x666666, dark: 0x9A9A9A)
    /// Section headings.
    static let heading = Color(light: 0x7A7A7A, dark: 0x8C8C8C)
    /// Path line under the header title.
    static let textPath = Color(light: 0x888888, dark: 0x828282)

    // MARK: - Borders

    /// Sidebar → detail split line.
    static let borderSidebar = Color(light: 0xEDEDED, dark: 0x2B2B2B)
    /// Header underline.
    static let borderHeader = Color(light: 0xF1F1F1, dark: 0x292929)
    /// Sidebar footer top line.
    static let borderFooter = Color(light: 0xEBEBEB, dark: 0x2B2B2B)

    // MARK: - Controls

    static let buttonFill = Color(light: 0xF3F3F3, dark: 0x2C2C2C)
    static let buttonStroke = Color(light: 0xE0E0E0, dark: 0x3D3D3D)
    /// Close button glyph — #FF685F in both appearances.
    static let closeRed = Color(hex: 0xFF685F)

    /// Selected / hovered sidebar row pills.
    static let rowSelected = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    })
    static let rowHovered = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.03)
    })

    /// Status dots — saturated enough to hold on both surfaces.
    static let dotActive = Color(hex: 0x00DD21)
    static let dotServer = Color(hex: 0x3B82F6)
    static let dotShell = Color(hex: 0xA6A6A6)

    // MARK: - Metrics

    /// Default sidebar width (user-draggable around it).
    static let sidebarWidth: CGFloat = 239
    /// Horizontal inset of a row pill from the sidebar edges. The design's
    /// 220pt-in-239pt pill (inset 9) read too padded in use; tightened to 5.
    static let rowInset: CGFloat = 5

    // MARK: - Context bar

    /// Context-bar colour by usage fraction. Currently unreferenced — the
    /// replicated design has no context UI yet — kept with `ContextBar` for
    /// when it returns.
    ///
    /// **Takes a fraction (0–1), not a percentage.** `ActiveSession
    /// .contextPercent` already returns 0.0–1.0; multiplying by 100 here makes
    /// every session read as "danger".
    enum Context {
        static let warnPct = 0.25
        static let dangerPct = 0.60

        static func color(for fraction: Double) -> Color {
            if fraction >= dangerPct { return .red }
            if fraction >= warnPct { return .orange }
            return .green
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// `Color(hex: 0x111111)` — a fixed color, same in both appearances.
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// A dynamic color that resolves per appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        })
    }
}
