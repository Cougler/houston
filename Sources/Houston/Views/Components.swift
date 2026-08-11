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
