import AppKit
import SwiftUI

/// Design tokens. Retheme 2026-09-22: values follow shadcn's zinc design
/// system (surfaces/borders/muted text on the Tailwind zinc scale, light =
/// white-on-zinc, dark = zinc-950), with Houston's brand rose surviving as
/// the accent (`buttonActive*`, `ctaFill`, `link`). Every token is a
/// dynamic color, so switching the app appearance restyles everything live.
enum Theme {

    // MARK: - Surfaces (shadcn: background / card / muted)

    /// Window / detail background — shadcn `background`.
    static let background = Color(light: 0xFFFFFF, dark: 0x09090B)
    /// The sidebar panel (and the chat composer, which matches it) —
    /// shadcn's sidebar surface: zinc-50 on light, zinc-900 on dark, so
    /// the column reads as its own surface either way.
    static let sidebarFill = Color(light: 0xFAFAFA, dark: 0x18181B)
    /// The sidebar's top tiles — shadcn `muted` (zinc-100 / zinc-800);
    /// active lifts a step (white / zinc-700).
    static let tileFill = Color(light: 0xF4F4F5, dark: 0x27272A)
    static let tileActive = Color(light: 0xFFFFFF, dark: 0x3F3F46)
    /// The empty state's sky AND the chat page (2026-09-21, one content
    /// surface) — the plain background, so content reads a step apart
    /// from the zinc side panels in both modes.
    static let emptyStateBackground = Color(light: 0xFFFFFF, dark: 0x09090B)
    /// Text sitting directly on the sky (empty state, onboarding chrome) —
    /// tracks the appearance along with it.
    static let skyText = Color(light: 0x09090B, dark: 0xFAFAFA)
    static let skyTextSecondary = Color(light: 0x71717A, dark: 0xA1A1AA)
    /// Floating cards (skills panel, rail flyouts) — shadcn `card` /
    /// `popover`: white on light, zinc-900 on dark (a card on zinc-950
    /// needs the step plus the border to separate).
    static let panelFill = Color(light: 0xFFFFFF, dark: 0x18181B)
    /// The git panel / sheet surface: zinc-50 in light, the deep
    /// background in dark.
    static let gitPanelFill = Color(light: 0xFAFAFA, dark: 0x09090B)
    /// The viewer-code row attached under the live-link field: barely off
    /// the drawer background so the row reads as recessed, not as a
    /// second field.
    static let attachedWellFill = Color(light: 0xF4F4F5, dark: 0x18181B)
    /// The faded helmet on the empty state — a whisper, not a shape.
    static let watermark = Color(light: 0xF4F4F5, dark: 0x27272A)

    // MARK: - Text (shadcn: foreground / muted-foreground)

    static let text = Color(light: 0x09090B, dark: 0xFAFAFA)
    /// Server row subtitle — shadcn `muted-foreground`.
    static let textSecondary = Color(light: 0x71717A, dark: 0xA1A1AA)
    /// Section headings — same muted-foreground; hierarchy comes from
    /// weight and kerning, not another gray.
    static let heading = Color(light: 0x71717A, dark: 0xA1A1AA)
    /// Path line under the header title.
    static let textPath = Color(light: 0x71717A, dark: 0xA1A1AA)

    // MARK: - Borders (shadcn `border`: zinc-200 / zinc-800)

    /// Sidebar → detail split line.
    static let borderSidebar = Color(light: NSColor(hex: 0xE4E4E7), dark: NSColor(hex: 0x27272A))
    /// Header underline.
    static let borderHeader = Color(light: NSColor(hex: 0xE4E4E7), dark: NSColor(hex: 0x27272A))
    /// Sidebar footer top line.
    static let borderFooter = Color(light: NSColor(hex: 0xE4E4E7), dark: NSColor(hex: 0x27272A))
    /// Solar-system orbit rings on the empty state.
    static let orbitRing = Color(
        light: .black.withAlphaComponent(0.08),
        dark: NSColor(hex: 0x27272A).withAlphaComponent(0.6)
    )

    // MARK: - Controls

    /// Secondary button fill — shadcn `secondary` (zinc-100 / zinc-800).
    static let buttonFill = Color(light: 0xF4F4F5, dark: 0x27272A)
    /// Header button while its menu/panel is open: the brand rose accent —
    /// deliberately the one non-neutral in the chrome (shadcn's `accent`
    /// slot, in Houston's color).
    static let buttonActiveFill = Color(
        light: NSColor(hex: 0xAD7370).withAlphaComponent(0.12),
        dark: NSColor(hex: 0xC79491).withAlphaComponent(0.15)
    )
    static let buttonActiveStroke = Color(light: 0xAD7370, dark: 0xC79491)
    /// Input/control border — shadcn `input` (zinc-200 / zinc-700).
    static let buttonStroke = Color(light: 0xE4E4E7, dark: 0x3F3F46)
    /// Close button glyph — shadcn `destructive` red, both appearances.
    static let closeRed = Color(hex: 0xEF4444)

    /// Selected / hovered sidebar row pills.
    static let rowSelected = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    })
    /// THE hover fill, app-wide — NEUTRAL now (shadcn convention: hover
    /// is a whisper of ink, color is reserved for meaning). Every control
    /// that tints under the pointer uses this wash (or `controlHovered`
    /// when it sits on an already-washed surface).
    static let rowHovered = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.05)
    })
    /// A small inline control (icon/pill button) under the pointer while
    /// its ROW is also washed — the same ink, stepped up so it still reads
    /// on top of `rowHovered`.
    static let controlHovered = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.13)
            : NSColor.black.withAlphaComponent(0.10)
    })
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
    static let dotActive = Color(light: 0x15803D, dark: 0x22C55E)
    /// The sidebar status dot's idle state — a quiet gray, non-signal.
    static let dotIdle = Color(light: 0xA1A1AA, dark: 0x52525B)
    /// The chat view's user bubble — the brand rose (deepened; white text
    /// clears 4.5:1 in both modes — don't lighten without rechecking).
    static let chatUserFill = Color(light: 0x7E4340, dark: 0x8F5350)
    /// Assistant chat prose. Dark mode steps down from full foreground —
    /// full-brightness paragraphs glare at 16pt reading size; zinc-300
    /// still clears 10:1 on the chat background.
    static let chatProse = Color(light: 0x09090B, dark: 0xD4D4D8)
    /// Deepened in light mode: its only text use (diff hunk headers) sat at
    /// 3.1:1 with the fixed #3B82F6.
    static let dotServer = Color(light: 0x1D4ED8, dark: 0x3B82F6)
    static let dotShell = Color(hex: 0xA1A1AA)
    /// Degraded / warning status. The classic amber #D97706 read 2.7:1 on
    /// the light chrome; the light value deepens to clear 3:1 (non-text)
    /// and 4.5:1 when it colors small text.
    static let dotDegraded = Color(light: 0xB45309, dark: 0xD97706)

    /// Inline text links — the brand rose, now that the chrome is
    /// neutral zinc (light deepened until text clears 4.5:1 on white).
    static let link = Color(light: 0x7E4340, dark: 0xC79491)
    /// The switch's off-state track (zinc-200 / zinc-800); the knob is
    /// white in both states.
    static let switchTrack = Color(light: 0xE4E4E7, dark: 0x27272A)
    /// On-state track — green, per the server-card design (toggles read
    /// as "live"), deep enough that the white knob holds.
    static let switchTrackOn = Color(hex: 0x16A34A)
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
    static let textDanger = Color(light: 0xB91C1C, dark: 0xF87171)
    /// Green *text* (added-line counts, diff additions). The raw #16A34A
    /// sat at 2.8:1 on the light chrome; green-400 carries the dark side.
    static let textPositive = Color(light: 0x166534, dark: 0x4ADE80)
    /// Amber *text* ("not pushed"). Text-grade amber has to go brown —
    /// #D97706 can't reach 4.5:1 on the light chrome at any small size.
    static let textWarning = Color(light: 0x92400E, dark: 0xFBBF24)

    // MARK: - Metrics

    /// Default sidebar width (user-draggable around it).
    static let sidebarWidth: CGFloat = 239
    /// Horizontal inset of a row pill from the sidebar edges. The design's
    /// 220pt-in-239pt pill (inset 9) read too padded in use; tightened to 5,
    /// then 3 in the 2026-08 density pass.
    static let rowInset: CGFloat = 3

    // MARK: - Shape

    /// The three corner radii, app-wide. Every rounded rect picks one of
    /// these (or `Capsule`) — no ad-hoc radii, so nothing reads as coming
    /// from a different app.
    /// Small controls: chips, icon buttons, hover washes, menu rows.
    static let radiusControl: CGFloat = 6
    /// Content surfaces: fields, wells, grouped tints, bubbles.
    static let radiusSurface: CGFloat = 10
    /// Floating layers: flyouts, popovers, the composer, full sheets.
    static let radiusFloat: CGFloat = 12

    /// The one shadow, reserved for layers that genuinely float above the
    /// canvas (flyouts, popovers). In-flow content never casts one — space
    /// and tint do the separating.
    /// shadcn-grade: soft and close, not a glow.
    static let floatShadowColor = SwiftUI.Color.black.opacity(0.10)
    static let floatShadowRadius: CGFloat = 14
    static let floatShadowY: CGFloat = 4

    // MARK: - Spacing

    /// The spacing scale. Related things sit `xs`/`s` apart, groups get
    /// `l`/`xl`, and page margins use `xxl` — grouping by whitespace is
    /// what lets the chrome drop its boxes.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Type ramp

    /// UI text sizes. Hierarchy comes from weight and spacing, not size
    /// jumps; nothing readable dips below `metaSize`, and the only text
    /// smaller than that is the uppercase kerned section label.
    enum Fonts {
        /// Panel / section titles.
        static let title = Font.system(size: 13, weight: .semibold)
        /// Reading text: descriptions, list titles, transcript prose.
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        /// Secondary lines: subtitles, timestamps, counts.
        static let secondary = Font.system(size: 11)
        static let secondaryMedium = Font.system(size: 11, weight: .medium)
        /// Dense metadata — the floor for anything that must be read.
        static let meta = Font.system(size: 10)
        /// Uppercase section labels; pair with `.kerning(0.5)`.
        static let label = Font.system(size: 9, weight: .semibold)
        /// Paths, tokens, code fragments.
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)

        static let metaSize: CGFloat = 10
    }

    // MARK: - Motion

    /// The one UI transition: quick settle for hover washes, state flips,
    /// and reveals. Longer choreography (onboarding, artwork) keeps its
    /// own timing.
    static let quick = Animation.easeOut(duration: 0.15)

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
