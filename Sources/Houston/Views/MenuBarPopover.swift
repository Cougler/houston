import AppKit
import SwiftUI

/// The menubar popover: the Servers page and its children without opening
/// the window — a scoped-down return of the Electron era's menubar UI.
/// Left-clicking the status item toggles it; the window moved to the
/// popover's header button and the right-click menu.
///
/// Deliberately built on the same stores and pages as the window's server
/// sheet (`ServerPanel` / `OffServerPanel` in pushed-page mode via
/// `onBack`), so this never becomes a second UI over the same data — the
/// popover is another door to the one implementation.
@MainActor
final class MenuBarPopover: NSObject {
    static let shared = MenuBarPopover()
    private var popover: NSPopover?

    func toggle(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            self.popover = nil
            return
        }
        // A fresh scan so the list is current the moment it appears, not
        // one tick stale.
        DevServerStore.shared.refresh()

        let pop = NSPopover()
        pop.behavior = .transient
        let host = NSHostingController(
            rootView: MenuBarServersView(onDismiss: { [weak pop] in
                pop?.performClose(nil)
            })
        )
        // The SwiftUI root fixes its own size; letting the hosting
        // controller negotiate too makes the popover jump on content swaps.
        host.sizingOptions = []
        pop.contentViewController = host
        pop.contentSize = MenuBarServersView.size
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/// Root of the popover: the servers list, drilling into the live or off
/// server page in place.
struct MenuBarServersView: View {
    /// Matches the window's right sheet width so the reused panels lay out
    /// identically.
    static let size = NSSize(width: 364, height: 540)

    @ObservedObject private var servers = DevServerStore.shared
    @ObservedObject private var share = ShareProxyStore.shared
    @ObservedObject private var relay = RelayTunnelStore.shared
    var onDismiss: () -> Void = {}

    /// nil shows the list; a server/recent id shows its page.
    @State private var selectedID: String?
    @State private var hoveredID: String?

    var body: some View {
        Group {
            if let sid = selectedID {
                detail(sid)
            } else {
                listPage
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.background)
    }

    // MARK: - List

    private var listPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Servers")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                ControlIconButton(
                    systemName: "macwindow",
                    help: "Open Houston",
                    bare: true,
                    circleSize: 32,
                    action: {
                        onDismiss()
                        MainWindowController.present()
                    }
                )
            }
            if servers.devServers.isEmpty && servers.recents.isEmpty {
                VStack(spacing: 6) {
                    Text("No dev servers running")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Servers on ports 3000–9999 show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(servers.devServers) { server in
                            liveRow(server)
                        }
                        if !servers.recents.isEmpty {
                            Text("RECENT")
                                .font(.system(size: 11, weight: .semibold))
                                .kerning(1.1)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, servers.devServers.isEmpty ? 0 : 14)
                                .padding(.bottom, 4)
                            ForEach(servers.recents) { recent in
                                recentRow(recent)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func liveRow(_ server: DevServer) -> some View {
        Button {
            selectedID = server.id
        } label: {
            ServerRow(
                server: server,
                health: servers.health[server.id],
                hovered: hoveredID == server.id
            )
            .overlay(alignment: .trailing) {
                if isLive(server) {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(Theme.textPositive)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().stroke(Theme.textPositive, lineWidth: 1))
                        .padding(.trailing, 10)
                        .help("Shared live on the web")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredID = server.id
            } else if hoveredID == server.id {
                hoveredID = nil
            }
        }
    }

    private func recentRow(_ recent: RecentServer) -> some View {
        Button {
            selectedID = recent.id
        } label: {
            ServerRow(recent: recent, hovered: hoveredID == recent.id)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredID = recent.id
            } else if hoveredID == recent.id {
                hoveredID = nil
            }
        }
    }

    /// The relay reports this project's public link online.
    private func isLive(_ server: DevServer) -> Bool {
        let label = ShareProxyStore.label(for: server.project ?? server.command)
        if case .online = relay.states[label] { return true }
        return false
    }

    // MARK: - Detail

    /// Same id resolution as the window's server sheet: live id first, then
    /// through the recent entry it maps to — the page morphs live↔off in
    /// place as the server stops or comes back.
    @ViewBuilder
    private func detail(_ sid: String) -> some View {
        if let server = liveServer(for: sid) {
            ServerPanel(
                server: server,
                share: share,
                relay: relay,
                health: servers.health[server.id],
                onOpenTerminal: { openInWindow(server.cwd) },
                onBack: { selectedID = nil }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
        } else if let recent = servers.recent(matching: sid) {
            VStack(alignment: .leading, spacing: 0) {
                OffServerPanel(
                    recent: recent,
                    busyPorts: Dictionary(
                        servers.devServers.map { ($0.port, $0.project ?? $0.command) },
                        uniquingKeysWith: { a, _ in a }
                    ),
                    onBack: { selectedID = nil },
                    onStart: { command in
                        let terminals = TerminalSessionManager.shared
                        terminals.pane(for: recent.projectPath)
                        terminals.send(command + "\n", to: recent.projectPath)
                        openInWindow(recent.projectPath)
                    }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        } else {
            VStack(spacing: 8) {
                Text("This server is no longer listening.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                LinkButton(title: "Back to servers", size: 12) { selectedID = nil }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func liveServer(for sid: String) -> DevServer? {
        servers.devServers.first { $0.id == sid }
            ?? servers.recent(matching: sid).flatMap { recent in
                servers.devServers.first { $0.cwd == recent.projectPath }
            }
    }

    /// Routes to the project's terminal in the main window — the popover
    /// hosts no terminal, so "open" always means the window.
    private func openInWindow(_ path: String?) {
        onDismiss()
        MainWindowController.present()
        if let path {
            NotificationCenter.default.post(
                name: .houstonOpenProject,
                object: nil,
                userInfo: ["path": path]
            )
        }
    }
}
