import AppKit
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
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
                    RoundedRectangle(cornerRadius: 5)
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
/// so it tints like an SF Symbol: two rounded units with power dashes,
/// stroked at the SVG's 1.5pt (scaled from its 24pt box).
struct ServerGlyph: View {
    var color: Color
    var size: CGFloat = 16

    var body: some View {
        ServerGlyphShape()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: 1.5 * size / 24,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
    }
}

private struct ServerGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var p = Path()
        for y: CGFloat in [4.5, 13.5] {
            p.addRoundedRect(
                in: CGRect(x: 3 * s, y: y * s, width: 18 * s, height: 6 * s),
                cornerSize: CGSize(width: 1.2 * s, height: 1.2 * s)
            )
            p.move(to: CGPoint(x: 6 * s, y: (y + 3) * s))
            p.addLine(to: CGPoint(x: 8 * s, y: (y + 3) * s))
        }
        return p
    }
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

    @MainActor private static func template(named name: String) -> NSImage? {
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
