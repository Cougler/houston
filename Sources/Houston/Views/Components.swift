import SwiftUI

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
        guard let url = Bundle.module.resourceURL?
            .appendingPathComponent("icons/\(name).svg"),
            let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
