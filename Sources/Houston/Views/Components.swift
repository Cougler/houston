import AppKit
import CoreImage
import SwiftUI

/// An inline text link in the brand rose (`Theme.link`) — use instead of
/// `.buttonStyle(.link)`, whose system blue sat outside the palette. The
/// hover underline and hand cursor keep the "this is a link" affordance the
/// color change takes away.
struct LinkButton: View {
    let title: String
    var size: CGFloat = 12
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size))
                .foregroundStyle(Theme.link)
                .underline(hovered)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            // set(), not push()/pop() — a view that disappears mid-hover
            // (sheet closing) would leave a pushed cursor stranded.
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

/// A searchable, scrolling list for any menu too long for a native NSMenu
/// (the terminal theme catalog is ~485 entries): a search field pinned on
/// top, an optional Recents section while the query is empty, and a hard max
/// height so the list scrolls instead of running past the screen. Present it
/// from a `.popover`; native menus can't host a text field.
struct SearchableMenuList<Item: Identifiable, Row: View>: View {
    var items: [Item]
    var recents: [Item] = []
    var allTitle = "All"
    var matches: (Item, String) -> Bool
    var select: (Item) -> Void
    @ViewBuilder var row: (Item) -> Row

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { matches($0, q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty,
                       !recents.isEmpty {
                        sectionHeader("Recents")
                        ForEach(recents) { item in
                            MenuListRow(action: { select(item) }) { row(item) }
                        }
                        sectionHeader(allTitle)
                    }
                    if filtered.isEmpty {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(filtered) { item in
                        MenuListRow(action: { select(item) }) { row(item) }
                    }
                }
                .padding(6)
            }
            // The whole point: the list scrolls, the popover never grows
            // past a screenful.
            .frame(maxHeight: 340)
        }
        .frame(width: 248)
        .onAppear { searchFocused = true }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.heading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

/// One row of `SearchableMenuList` — quiet hover fill over caller content.
private struct MenuListRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A small circular icon button on the chip chrome: quiet at rest, the
/// shared hover wash under the pointer. THE hover-circle control — reach
/// for this instead of hand-rolling the ✕/+/chip pattern per view.
struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 20
    var iconSize: CGFloat = 10
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(
                    hovered ? Theme.controlHovered : Theme.controlChip
                ))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// A traditional dialog button: filled rose CTA when primary, quiet
/// chrome fill otherwise. Shared so every dialog's footer reads the same.
struct DialogButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? .white : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(
                    primary ? Theme.ctaFill : Theme.buttonFill
                ))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Copy-to-clipboard icon button that confirms: the doc glyph flips to a
/// green check for a beat after copying. Hover chrome matches
/// `ControlIconButton`'s quiet square.
struct CopyIconButton: View {
    let text: String
    var help: String = "Copy"

    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.3)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    copied ? Theme.dotActive : hovered ? Theme.text : Theme.textSecondary
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// Horizontal context-usage bar. The only piece kept from the old popover's
/// component set.
struct ContextBar: View {
    let pct: Double
    let color: Color
    var trackWidth: CGFloat = 72
    var trackHeight: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.22))
                .frame(width: trackWidth, height: trackHeight)
            Capsule()
                .fill(color)
                .frame(width: trackWidth * CGFloat(max(0, min(1, pct))), height: trackHeight)
                .animation(.easeOut(duration: 0.2), value: pct)
        }
        .frame(width: trackWidth, height: trackHeight)
    }
}

/// `<1k` exact, `<10k` one decimal, `<1M` rounded k, else M.
func formatTokens(_ n: Int) -> String {
    if n <= 0 { return "0" }
    if n < 1_000 { return "\(n)" }
    if n < 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    if n < 1_000_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
    return String(format: "%.1fM", Double(n) / 1_000_000)
}

/// Inline notice for panel sections — THE feedback pattern, app-wide: a
/// quiet color wash (no border), the signal icon and hue in the chrome,
/// title in the primary text color with the body at 60% so the color
/// stays out of the words. One shape for error, success, and warning, so
/// feedback reads the same everywhere.
struct InlineNotice: View {
    enum Kind {
        case error, success, warning

        var icon: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: Theme.textDanger
            case .success: Theme.textPositive
            case .warning: Theme.textWarning
            }
        }

        var wash: Color {
            switch self {
            case .error: Theme.closeRed.opacity(0.07)
            case .success: Theme.textPositive.opacity(0.08)
            case .warning: Theme.textWarning.opacity(0.08)
            }
        }
    }

    var kind: Kind = .error
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.text.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(kind.wash)
        )
    }
}

/// The old name for the error notice; call sites migrate to `InlineNotice`.
func AlertBanner(title: String, message: String) -> InlineNotice {
    InlineNotice(kind: .error, title: title, message: message)
}

/// QR code for a share URL, shown from the Wi-Fi row's "View QR Code"
/// button so a phone can jump straight to the link.
struct QRCodePopover: View {
    let url: String

    var body: some View {
        VStack(spacing: 10) {
            if let image = Self.qrImage(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .accessibilityLabel("QR code for \(url)")
            } else {
                Text("Could not render a QR code.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(url.replacingOccurrences(of: "http://", with: ""))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
    }

    static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Small-caps marker for the public-link share tier that isn't built yet —
/// plain text, no chrome, per the Figma server page.
struct ComingSoonBadge: View {
    var body: some View {
        Text("COMING SOON")
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// The server-rack glyph from `Resources/icons/servers.svg`, drawn as a path
/// so it tints like an SF Symbol: two rounded units with a power dash
/// each, stroked at the SVG's 1pt (scaled from its 18pt box).
struct ServerGlyph: View {
    var color: Color
    var size: CGFloat = 16

    var body: some View {
        ServerGlyphShape()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: 1.1 * size / 18,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
    }
}

private struct ServerGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 18
        var p = Path()
        for y: CGFloat in [3.375, 10.125] {
            p.addRoundedRect(
                in: CGRect(x: 2.25 * s, y: y * s, width: 13.5 * s, height: 4.5 * s),
                cornerSize: CGSize(width: 0.8 * s, height: 0.9 * s)
            )
            p.move(to: CGPoint(x: 4.5 * s, y: (y + 2.25) * s))
            p.addLine(to: CGPoint(x: 6 * s, y: (y + 2.25) * s))
        }
        return p
    }
}

/// A linear right-sheet list row, shared by the SERVERS and TASKS pages:
/// 48pt tall, icon centered in a fixed 26pt leading slot, title over
/// subtitle, a full-width hairline underneath that hides beneath the
/// hover pill, and a trailing chevron that firms up on hover.
struct SheetListRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleTint: Color = Theme.text
    /// Amber attention dot beside the title.
    var dot: Bool = false
    let onTap: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(titleTint)
                            .lineLimit(1)
                        if dot {
                            Circle()
                                .fill(Theme.dotDegraded)
                                .frame(width: 5, height: 5)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                    .opacity(hovered ? 1 : 0.4)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            // The divider hides under the hover pill instead of cutting
            // through it.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.borderSidebar)
                    .frame(height: 1)
                    .opacity(hovered ? 0 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The caps section label above a sheet list's rows ("RUNNING",
/// "PROJECTS", …).
func sheetSectionLabel(_ title: String) -> some View {
    Text(title)
        .font(Theme.Fonts.label)
        .kerning(0.5)
        .foregroundStyle(Theme.heading)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
}

/// A bundled SVG icon (Resources/icons/<name>.svg) rendered as a template
/// image, so `foregroundStyle` tints it like an SF Symbol. NSImage decodes
/// SVG natively on macOS 11+; the black fills become the tint mask.
struct SVGIcon: View {
    let name: String
    var size: CGFloat = 14

    var body: some View {
        if let image = Self.template(named: name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    /// Full-color bundled art (the rail's app icon) — loaded as-is, no
    /// template masking, so its own colors survive.
    @MainActor static func flat(named name: String) -> NSImage? {
        if let hit = cache["flat:\(name)"] { return hit }
        let image = ["png", "svg"].lazy
            .compactMap { ext in
                Bundle.module.resourceURL
                    .map { $0.appendingPathComponent("icons/\(name).\(ext)") }
                    .flatMap { NSImage(contentsOf: $0) }
            }
            .first
        guard let image else { return nil }
        cache["flat:\(name)"] = image
        return image
    }

    // Exposed for non-square art (the sidebar's Houston wordmark).
    @MainActor static func template(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        // SVG first, PNG as the fallback (alpha-masked art templates the
        // same way).
        let image = ["svg", "png"].lazy
            .compactMap { ext in
                Bundle.module.resourceURL
                    .map { $0.appendingPathComponent("icons/\(name).\(ext)") }
                    .flatMap { NSImage(contentsOf: $0) }
            }
            .first
        guard let image else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
