import AppKit
import SwiftUI

/// Design tokens. Light values come from the Figma design; dark values are
/// the same design translated to a #1E1E1E surface. Every token is a dynamic
/// color, so switching the app appearance restyles everything live.
enum Theme {

    // MARK: - Surfaces

    /// Window / sidebar / detail background.
    static let background = Color(light: 0xEBEBEB, dark: 0x1E1E1E)
    /// The empty state's sky — a step off the chrome in each direction:
    /// darker than the sidebar in light mode, lighter in dark mode.
    static let emptyStateBackground = Color(light: 0xE2E2E2, dark: 0x252525)
    /// Floating cards (skills panel, rail flyouts). Light mode matches the
    /// sidebar chrome; dark mode steps lighter to separate from it.
    static let panelFill = Color(light: 0xEBEBEB, dark: 0x262626)
    /// The git panel: chrome-colored in light mode like the other cards,
    /// darker than the UI in dark mode.
    static let gitPanelFill = Color(light: 0xEBEBEB, dark: 0x181818)
    /// The viewer-code row attached under the live-link field: barely off
    /// the drawer background (0x1E1E1E dark / 0xEBEBEB light) so the row
    /// reads as recessed, not as a second field.
    static let attachedWellFill = Color(light: 0xE7E7E7, dark: 0x1C1C1C)
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
    static let borderSidebar = Color(light: .black.withAlphaComponent(0.10), dark: NSColor(hex: 0x2B2B2B))
    /// Header underline.
    static let borderHeader = Color(light: .black.withAlphaComponent(0.10), dark: NSColor(hex: 0x292929))
    /// Sidebar footer top line.
    static let borderFooter = Color(light: .black.withAlphaComponent(0.10), dark: NSColor(hex: 0x2B2B2B))
    /// Solar-system orbit rings on the empty state.
    static let orbitRing = Color(
        light: .black.withAlphaComponent(0.10),
        dark: NSColor(hex: 0x323232).withAlphaComponent(0.5)
    )

    // MARK: - Controls

    static let buttonFill = Color(light: 0xF3F3F3, dark: 0x2C2C2C)
    /// Header button while its menu/panel is open: dusty-rose accent — the
    /// dark values are the design's; light is the same hue deepened to hold
    /// contrast on the light chrome.
    static let buttonActiveFill = Color(
        light: NSColor(hex: 0xAD7370).withAlphaComponent(0.12),
        dark: NSColor(hex: 0xC79491).withAlphaComponent(0.15)
    )
    static let buttonActiveStroke = Color(light: 0xAD7370, dark: 0xC79491)
    static let buttonStroke = Color(light: 0xE0E0E0, dark: 0x3D3D3D)
    /// Close button glyph — #FF685F in both appearances.
    static let closeRed = Color(hex: 0xFF685F)

    /// Selected / hovered sidebar row pills.
    static let rowSelected = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    })
    /// THE hover fill, app-wide: the link blue at 15%. Every control that
    /// tints under the pointer uses this wash (or `controlHovered` when it
    /// sits on an already-washed surface).
    static let rowHovered = link.opacity(0.15)
    /// A small inline control (icon/pill button) under the pointer while
    /// its ROW is also washed — the same blue, stepped up so it still reads
    /// on top of `rowHovered`.
    static let controlHovered = link.opacity(0.28)
    /// Resting chip behind always-chromed icon buttons (the sheet header's
    /// close circle, the tracked panel's menu chips) — neutral, NOT the
    /// hover wash; the wash layers on top under the pointer.
    static let controlChip = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.11)
    })

    /// Status dots — saturated enough to hold on both surfaces. The active
    /// green darkens in light mode: #00DD21 on white sat under 2:1 contrast,
    /// invisible to low-vision users; #15803D clears 3:1 (WCAG for non-text
    /// UI) while the dark surface keeps the bright signal color.
    static let dotActive = Color(light: 0x15803D, dark: 0x00DD21)
    /// Deepened in light mode: its only text use (diff hunk headers) sat at
    /// 3.1:1 with the fixed #3B82F6.
    static let dotServer = Color(light: 0x1D4ED8, dark: 0x3B82F6)
    static let dotShell = Color(hex: 0xA6A6A6)
    /// Degraded / warning status. The classic amber #D97706 read 2.7:1 on
    /// the light chrome; the light value deepens to clear 3:1 (non-text)
    /// and 4.5:1 when it colors small text.
    static let dotDegraded = Color(light: 0xB45309, dark: 0xD97706)

    /// Inline text links — the design's blues (Figma server page, node
    /// 511:7): #9EC9EF on the dark chrome, #628DB3 on the light.
    static let link = Color(light: 0x628DB3, dark: 0x9EC9EF)
    /// The server page's custom switch (Figma node 511:7): off-state track;
    /// the knob is white in both states.
    static let switchTrack = Color(light: 0xD9D9D9, dark: 0x141414)
    /// On-state track — a deeper blue than `link`, so the white knob holds.
    static let switchTrackOn = Color(hex: 0x266CCD)
    /// The server page's card hover — a whisper of ink, not the blue wash:
    /// 5% white on dark, 5% black on light.
    static let cardHovered = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.05)
            : NSColor.black.withAlphaComponent(0.05)
    })
    /// Filled CTA buttons carrying white text (onboarding's Take the Tour /
    /// Next). The brand rose deepened until white clears 4.5:1 in both modes:
    /// `link` is tuned for text *on* the chrome, and its dark value (#C79491,
    /// ~2:1 behind white) is far too light to sit under white text.
    static let ctaFill = Color(light: 0x7E4340, dark: 0x8F5350)
    /// Red *text* (deleted-line counts, destructive commands). `closeRed`
    /// stays for glyphs and fills, but as small text it read 2.4:1 on the
    /// light chrome.
    static let textDanger = Color(light: 0xB91C1C, dark: 0xFF685F)
    /// Green *text* (added-line counts, diff additions). The raw #16A34A
    /// sat at 2.8:1 on the light chrome; `dotActive`'s dark #00DD21 is a
    /// signal color, too loud as prose.
    static let textPositive = Color(light: 0x166534, dark: 0x34C759)
    /// Amber *text* ("not pushed"). Text-grade amber has to go brown —
    /// #D97706 can't reach 4.5:1 on the light chrome at any small size.
    static let textWarning = Color(light: 0x92400E, dark: 0xD97706)

    // MARK: - Metrics

    /// Default sidebar width (user-draggable around it).
    static let sidebarWidth: CGFloat = 239
    /// Horizontal inset of a row pill from the sidebar edges. The design's
    /// 220pt-in-239pt pill (inset 9) read too padded in use; tightened to 5,
    /// then 3 in the 2026-08 density pass.
    static let rowInset: CGFloat = 3

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
            return Theme.dotActive
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

    /// A dynamic color from full NSColor values, for tokens that need alpha.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        })
    }
}
