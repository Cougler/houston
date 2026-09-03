import SwiftUI

/// The native status strip under the terminal, shown only while an agent
/// session runs. Left-justified status cluster — model (a menu — picking one
/// runs `/model` in the session), context, MCP health, peak/off-peak hours,
/// account rate-limit meters. The chart toggle collapses the cluster down to
/// the model. Mission controls live up in the header. Fed by
/// `StatusLineFeed` instead of an in-terminal status line.
struct StatusBarView: View {
    /// Nil until a claude session has produced a feed payload.
    let snapshot: StatusLineSnapshot?
    /// Collapse everything but the model (and the mission buttons).
    @Binding var collapsed: Bool
    /// MCP health for this project, when a check has run.
    let mcp: MCPStatusStore.Status?
    /// Server names whose OAuth flow is currently open in the browser.
    let mcpAuthInFlight: Set<String>
    /// Called with the `/model` argument when the user picks a model.
    let onSelectModel: (String) -> Void
    /// Types `/mcp` into the session — manual reconnects live there.
    let onManageMCP: () -> Void
    let onRefreshMCP: () -> Void
    /// Run `claude mcp login/logout <name>` for a server.
    let onAuthenticateMCP: (String) -> Void
    let onLogoutMCP: (String) -> Void
    /// Item keys the settings menu has switched off ("model", "context",
    /// "cost", "mcp", "peak", "limits").
    var hiddenItems: Set<String> = []
    /// Without a session the bar keeps its place but shows nothing — the
    /// layout never jumps when a session starts.
    var sessionRunning = false
    /// The running harness — its model catalog fills the switcher.
    var agent: CodingAgent? = nil
    /// The context meter's account-limits popover.
    @State private var showLimits = false

    /// The running harness's model catalog (see `CodingAgent.modelOptions`).
    private var models: [(label: String, arg: String)] {
        agent?.modelOptions ?? []
    }

    private func shows(_ key: String) -> Bool { !hiddenItems.contains(key) }

    var body: some View {
        GeometryReader { geo in
            // Tight windows drop the detail text (tokens, countdown); the
            // tooltips keep it one hover away.
            let compact = geo.size.width < 620
            HStack(spacing: 0) {
                if !sessionRunning {
                    Spacer(minLength: 0)
                } else if collapsed {
                    if shows("model"), !models.isEmpty {
                        modelMenu
                    }
                    Spacer(minLength: 0)
                } else {
                    // Model + context travel as one group, as do the meters;
                    // flexible gaps spread the groups across the window.
                    if (shows("model") && !models.isEmpty)
                        || (shows("context") && snapshot?.usedFraction != nil) {
                        HStack(spacing: 14) {
                            if shows("model"), !models.isEmpty {
                                modelMenu
                            }
                            if shows("context"), let snapshot,
                               let fraction = snapshot.usedFraction {
                                contextDropdown(fraction, compact: compact, meters: snapshot.meters)
                            }
                            if shows("cost"), let cost = snapshot?.costUSD {
                                costReadout(cost)
                            }
                        }
                    }
                    if shows("mcp") {
                        Spacer(minLength: 12)
                        mcpMenu
                    }
                    if shows("peak") {
                        Spacer(minLength: 12)
                        PeakHoursPill(compact: compact)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .lineLimit(1)
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .frame(height: 26)
        .background(Theme.background)
        .padding(.bottom, 4)
    }

    /// The live model's own account meters — the per-model weekly caps
    /// (e.g. Fable's) whose label appears in the reported model name.
    /// Session and all-models stay in the context dropdown; this is the
    /// "how much of THIS model do I have left" readout, next to the
    /// control that switches away from it.
    private var currentModelMeters: [StatusLineSnapshot.Meter] {
        guard let snapshot else { return [] }
        return snapshot.meters.filter { meter in
            !["five_hour", "seven_day"].contains(meter.key)
                && snapshot.modelName.localizedCaseInsensitiveContains(meter.label)
        }
    }

    private var modelMenu: some View {
        Menu {
            // Plain Text renders as a disabled item — exactly right for a
            // readout row above the switch targets.
            ForEach(currentModelMeters, id: \.key) { meter in
                Text("\(meter.label) limit · \(Int(meter.pct))% used")
            }
            if !currentModelMeters.isEmpty { Divider() }
            ForEach(models, id: \.arg) { model in
                Button(model.label) { onSelectModel(model.arg) }
            }
        } label: {
            HStack(spacing: 4) {
                // Claude's feed reports the live model; other harnesses
                // publish nothing, so the menu is just "Model".
                Text(snapshot?.modelName ?? "Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch this session's model")
    }

    /// What this session's tokens would have cost at API prices — Claude's
    /// own running total from the feed payload.
    private func costReadout(_ cost: Double) -> some View {
        Text(cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost))
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .help("Session cost so far (API-equivalent)")
    }

    /// The context meter, doubling as the dropdown for the account limit
    /// meters (Session / All models / per-model) — they live in this popover
    /// now, not on the bar.
    private func contextDropdown(
        _ fraction: Double,
        compact: Bool,
        meters: [StatusLineSnapshot.Meter]
    ) -> some View {
        Button {
            showLimits.toggle()
        } label: {
            HStack(spacing: 6) {
                ContextBar(
                    pct: fraction,
                    color: Theme.Context.color(for: fraction),
                    trackWidth: compact ? 56 : 84,
                    trackHeight: 5
                )
                Text(compact
                    ? "\(Int((fraction * 100).rounded()))%"
                    : contextLabel(fraction))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                if shows("limits") {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!shows("limits"))
        .help(compact
            ? "\(contextLabel(fraction)) of the context window used"
            : "Context window used — click for account limits")
        .popover(isPresented: $showLimits, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Account Limits")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                if meters.isEmpty {
                    // Claude's payload carries rate_limits only once it has
                    // them — a fresh session shows this until its next
                    // response.
                    Text("No limit data from this session yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(meters, id: \.key) { meter in
                    HStack(spacing: 8) {
                        Text(meter.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text)
                            .frame(width: 80, alignment: .leading)
                        ContextBar(
                            pct: meter.pct / 100,
                            color: Self.meterColor(meter.pct),
                            trackWidth: 90,
                            trackHeight: 4
                        )
                        Text("\(Int(meter.pct))%")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .help("\(meter.label) rate limit used")
                }
            }
            .padding(14)
        }
    }

    // MARK: - MCP

    private var mcpMenu: some View {
        Menu {
            if let mcp, !mcp.servers.isEmpty {
                // Buttons, not Text — a plain Text inside a Menu renders as
                // a disabled item.
                ForEach(mcp.servers) { server in
                    mcpServerItem(server)
                }
                Divider()
            } else if mcp?.checking == true {
                Text("Checking servers…")
                Divider()
            } else if mcp != nil {
                Text("No MCP servers configured")
                Divider()
            }
            Button("Manage in Session (/mcp)") { onManageMCP() }
            Button(mcp?.checking == true ? "Checking…" : "Refresh Status") {
                onRefreshMCP()
            }
            .disabled(mcp?.checking == true)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(mcpDotColor)
                    .frame(width: 7, height: 7)
                Text("MCP")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mcpHelp)
    }

    /// One server row: needs-auth rows authenticate in one click (browser
    /// OAuth via `claude mcp login`), connected rows tuck Log Out behind a
    /// submenu so it can't be hit by accident, failed rows open /mcp — the
    /// only place a manual reconnect exists.
    @ViewBuilder
    private func mcpServerItem(_ server: MCPStatusStore.Server) -> some View {
        switch server.state {
        case .needsAuth:
            if mcpAuthInFlight.contains(server.name) {
                Button("⚠ \(server.name) — authenticating…") {}
                    .disabled(true)
            } else {
                Button("⚠ \(server.name) — Authenticate") {
                    onAuthenticateMCP(server.name)
                }
                .help("Opens the browser sign-in for \(server.name)")
            }
        case .connected:
            Menu("✓ \(server.name)") {
                Button("Log Out") { onLogoutMCP(server.name) }
            }
        case .failed:
            Button("✗ \(server.name) — Open /mcp") { onManageMCP() }
                .help(server.detail)
        case .unknown:
            Button("· \(server.name)") { onManageMCP() }
                .help(server.detail)
        }
    }

    private var mcpDotColor: Color {
        guard let mcp, !mcp.checking || !mcp.servers.isEmpty else { return Theme.dotShell }
        if mcp.servers.isEmpty { return Theme.dotShell }
        if mcp.servers.contains(where: { $0.state == .failed }) { return .red }
        if mcp.servers.contains(where: { $0.state == .needsAuth }) { return .orange }
        if mcp.servers.allSatisfy({ $0.state == .connected }) { return Theme.dotActive }
        return Theme.dotShell
    }

    private var mcpHelp: String {
        guard let mcp, !mcp.servers.isEmpty else { return "MCP servers" }
        let auth = mcp.servers.filter { $0.state == .needsAuth }.count
        let failed = mcp.servers.filter { $0.state == .failed }.count
        if auth == 0, failed == 0 { return "All MCP servers connected" }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) failed") }
        if auth > 0 { parts.append("\(auth) need authentication") }
        return "MCP: " + parts.joined(separator: ", ")
    }

    private static func mcpSymbol(_ state: MCPStatusStore.ServerState) -> String {
        switch state {
        case .connected: "✓"
        case .needsAuth: "⚠"
        case .failed: "✗"
        case .unknown: "·"
        }
    }

    private func contextLabel(_ fraction: Double) -> String {
        let pct = "\(Int((fraction * 100).rounded()))%"
        guard let used = snapshot?.usedTokens, let window = snapshot?.windowSize else {
            return pct
        }
        return "\(formatTokens(used)) / \(formatTokens(window)) · \(pct)"
    }

    /// Rate limits run hotter than context before they hurt — green until
    /// 60%, orange until 85%.
    private static func meterColor(_ pct: Double) -> Color {
        if pct >= 85 { return .red }
        if pct >= 60 { return .orange }
        return Theme.dotActive
    }
}

/// Peak / off-peak indicator, ported from the user's original statusline
/// script: peak is 09:00–18:00 local, with a countdown to the transition.
/// Wall-clock derived — the statusline payload carries no peak-hours data —
/// so a timeline keeps the countdown honest while the bar sits idle.
private struct PeakHoursPill: View {
    var compact: Bool = false
    private static let peakStart = 9
    private static let peakEnd = 18

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let info = Self.info(at: timeline.date)
            HStack(spacing: 4) {
                Text(info.icon)
                    .font(.system(size: 10))
                Text(info.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if !compact {
                    Text("· \(info.message)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPath)
                }
            }
            .help(
                (compact ? "\(info.message.capitalized) — p" : "P")
                + "eak hours are \(Self.peakStart):00–\(Self.peakEnd):00 local"
            )
        }
    }

    private static func info(at date: Date) -> (icon: String, label: String, message: String) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        if hour >= peakStart, hour < peakEnd {
            let left = (peakEnd - hour) * 60 - minute
            return ("☀️", "Peak", "off-peak in \(left / 60)h \(left % 60)m")
        }
        let hoursToPeak = hour < peakStart ? peakStart - hour : 24 - hour + peakStart
        let left = hoursToPeak * 60 - minute
        return ("🌙", "Off-peak", "peak in \(left / 60)h \(left % 60)m")
    }
}
