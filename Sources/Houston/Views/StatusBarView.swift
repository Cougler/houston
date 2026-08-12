import SwiftUI

/// The native status strip under the terminal: the focused claude session's
/// model (a menu — picking one runs `/model` in the session), context usage,
/// account rate-limit meters, lines changed and session cost, fed by
/// `StatusLineFeed` instead of an in-terminal status line.
struct StatusBarView: View {
    let snapshot: StatusLineSnapshot
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

    /// Menu label → `/model` argument.
    private static let models: [(label: String, arg: String)] = [
        ("Default", "default"),
        ("Fable 5", "fable"),
        ("Fable 5 · 1M", "fable[1m]"),
        ("Opus 5", "opus"),
        ("Sonnet 5", "sonnet"),
        ("Haiku 4.5", "haiku"),
    ]

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(Self.models, id: \.arg) { model in
                    Button(model.label) { onSelectModel(model.arg) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(snapshot.modelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch this session's model")

            if let fraction = snapshot.usedFraction {
                HStack(spacing: 6) {
                    ContextBar(
                        pct: fraction,
                        color: Theme.Context.color(for: fraction),
                        trackWidth: 72,
                        trackHeight: 4
                    )
                    Text(contextLabel(fraction))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .help("Context window used")
            }

            mcpMenu

            Spacer(minLength: 8)

            ForEach(snapshot.meters, id: \.key) { meter in
                HStack(spacing: 5) {
                    Text(meter.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    ContextBar(
                        pct: meter.pct / 100,
                        color: Self.meterColor(meter.pct),
                        trackWidth: 30,
                        trackHeight: 4
                    )
                    Text("\(Int(meter.pct))%")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .help("\(meter.label) rate limit used")
            }

            if snapshot.linesAdded > 0 || snapshot.linesRemoved > 0 {
                HStack(spacing: 4) {
                    Text("+\(snapshot.linesAdded)")
                        .foregroundStyle(Color(hex: 0x16A34A))
                    Text("−\(snapshot.linesRemoved)")
                        .foregroundStyle(Theme.closeRed)
                }
                .font(.system(size: 11, weight: .medium))
                .help("Lines added and removed this session")
            }

            if let cost = snapshot.costUSD, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Session cost")
            }
        }
        .lineLimit(1)
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 28)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.borderHeader).frame(height: 1)
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
                    .frame(width: 6, height: 6)
                Text("MCP")
                    .font(.system(size: 11, weight: .medium))
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
        guard let used = snapshot.usedTokens, let window = snapshot.windowSize else {
            return pct
        }
        return "\(formatTokens(used)) / \(formatTokens(window)) · \(pct)"
    }

    /// Rate limits run hotter than context before they hurt — green until
    /// 60%, orange until 85%.
    private static func meterColor(_ pct: Double) -> Color {
        if pct >= 85 { return .red }
        if pct >= 60 { return .orange }
        return .green
    }
}
