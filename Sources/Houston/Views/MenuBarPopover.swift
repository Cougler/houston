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
    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// The status item's window — clicks there are the toggle itself, so
    /// the click-away monitor must leave them alone or every toggle would
    /// close-then-reopen.
    private weak var statusWindow: NSWindow?
    /// Screen coords the panel hangs from: top edge stays pinned here and
    /// height changes grow downward.
    private var topY: CGFloat = 0
    private var centerX: CGFloat = 0

    /// A borderless panel, not `NSPopover` — the popover's anchor arrow
    /// can't be removed with public API, and the panel also lets the
    /// height animate to fit each page's content.
    func toggle(relativeTo button: NSStatusBarButton) {
        if panel != nil {
            close()
            return
        }
        guard let buttonWindow = button.window else { return }
        // A fresh scan so the list is current the moment it appears, not
        // one tick stale.
        DevServerStore.shared.refresh()

        let anchor = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        topY = anchor.minY - 6
        centerX = anchor.midX
        statusWindow = buttonWindow

        let host = NSHostingController(
            rootView: MenuBarServersView(
                onDismiss: { [weak self] in self?.close() },
                onHeightChange: { [weak self] height in self?.resize(to: height) }
            )
        )
        // The SwiftUI root fixes its own size and reports height changes
        // through onHeightChange; the hosting controller stays out of it.
        host.sizingOptions = []

        let panel = KeyablePanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        self.panel = panel
        resize(to: MenuBarServersView.initialHeight)
        panel.orderFrontRegardless()

        // Click-away, since a plain panel has no `.transient` behaviour of
        // its own: any click in another app (global) or in another of our
        // windows (local) closes it.
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in Task { @MainActor in self?.close() } }
        ) { monitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self, event.window !== self.panel,
               event.window !== self.statusWindow {
                self.close()
            }
            return event
        }
        if let local { monitors.append(local) }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Top edge pinned under the menubar, growing downward; animated once
    /// visible so page swaps glide instead of jumping.
    private func resize(to height: CGFloat) {
        guard let panel else { return }
        let width = MenuBarServersView.size.width
        var x = centerX - width / 2
        if let screen = panel.screen ?? NSScreen.main {
            x = min(
                max(x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - width - 8
            )
        }
        let frame = NSRect(x: x, y: topY - height, width: width, height: height)
        if panel.isVisible {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

/// Borderless windows refuse key status by default, which would make the
/// server page's text fields (token, port) dead — opt back in.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Root of the popover: the servers list, drilling into the live or off
/// server page in place.
struct MenuBarServersView: View {
    /// Matches the window's right sheet width so the reused panels lay out
    /// identically. Height is just the pre-measurement placeholder — the
    /// panel fits its content between `minHeight` and `maxHeight`.
    static let size = NSSize(width: 364, height: 540)
    static let initialHeight: CGFloat = 320
    static let minHeight: CGFloat = 160
    static let maxHeight: CGFloat = 640

    @ObservedObject private var servers = DevServerStore.shared
    @ObservedObject private var share = ShareProxyStore.shared
    @ObservedObject private var relay = RelayTunnelStore.shared
    var onDismiss: () -> Void = {}
    /// Tells the panel the height this content wants (already clamped).
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// nil shows the list; a server/recent id shows its page.
    @State private var selectedID: String?
    @State private var hoveredID: String?
    /// Every project Houston knows (pinned + folder scans), for the
    /// Projects section under the servers.
    @State private var allProjects: [Project] = []
    /// path → detected dev command, for the ones that are web apps — what
    /// puts the start button on their row. Scanned once per popover open.
    @State private var devCommands: [String: DevCommandDetect.DefaultCommand] = [:]
    /// Natural height of the visible page's content, reported by the
    /// `heightReader` each page carries. The panel grows to fit it up to
    /// `maxHeight`; past that the inner ScrollView takes over.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Group {
            if let sid = selectedID {
                detail(sid)
            } else {
                listPage
            }
        }
        .frame(width: Self.size.width)
        .frame(height: clampedHeight, alignment: .top)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.buttonStroke, lineWidth: 1)
        )
        .onPreferenceChange(PopoverHeightKey.self) { height in
            contentHeight = height
            onHeightChange(clamp(height))
        }
        // Chrome differs per page, so a page swap re-reports even before
        // the new page's measurement lands (which then corrects it).
        .onChange(of: selectedID) { _, _ in onHeightChange(clampedHeight) }
    }

    /// Measured content plus the fixed chrome around it: the list page
    /// wraps its scroller in the header + paddings, a detail page only
    /// adds bottom padding.
    private var clampedHeight: CGFloat { clamp(contentHeight) }

    private func clamp(_ measured: CGFloat) -> CGFloat {
        let chrome: CGFloat = selectedID == nil ? 74 : 14
        return min(max(measured + chrome, Self.minHeight), Self.maxHeight)
    }

    /// Attached to each page's natural-height content (inside any
    /// ScrollView, so the measurement is the content's, not the viewport's).
    private var heightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PopoverHeightKey.self, value: geo.size.height)
        }
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
            if servers.devServers.isEmpty && servers.recents.isEmpty
                && listedProjects.isEmpty {
                VStack(spacing: 6) {
                    Text("No dev servers running")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Servers on ports 3000–9999 show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .background(heightReader)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(servers.devServers) { server in
                            liveRow(server)
                        }
                        if !servers.recents.isEmpty {
                            sectionHeader(
                                "RECENT",
                                topPadding: servers.devServers.isEmpty ? 0 : 14
                            )
                            ForEach(servers.recents) { recent in
                                recentRow(recent)
                            }
                        }
                        if !listedProjects.isEmpty {
                            sectionHeader(
                                "PROJECTS",
                                topPadding: servers.devServers.isEmpty
                                    && servers.recents.isEmpty ? 0 : 14
                            )
                            ForEach(listedProjects) { project in
                                projectRow(project)
                            }
                        }
                    }
                    .background(heightReader)
                }
            }
        }
        .padding(14)
        .onAppear(perform: loadProjects)
    }

    private func sectionHeader(_ title: String, topPadding: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.1)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
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

    /// Projects without a row above: a live server's cwd is already the
    /// Servers row, a recent's path already the Recent row.
    private var listedProjects: [Project] {
        let taken = Set(servers.devServers.compactMap(\.cwd))
            .union(servers.recents.map(\.projectPath))
        return allProjects.filter { !taken.contains($0.path) }
    }

    /// One scan per popover open: the project list plus which of them
    /// declare a dev server (package.json reads — off the main thread).
    private func loadProjects() {
        let settings = HoustonSettings.read()
        Task.detached(priority: .utility) {
            let projects = ProjectList.allProjects(settings: settings)
            let commands = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
                DevCommandDetect.detect(projectPath: project.path)
                    .map { (project.path, $0) }
            })
            await MainActor.run {
                allProjects = projects
                devCommands = commands
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        Button {
            openInWindow(project.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 13)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detected = devCommands[project.path] {
                    startButton(project: project, detected: detected)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredID == project.path ? Theme.rowHovered : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredID = project.path
            } else if hoveredID == project.path {
                hoveredID = nil
            }
        }
        .help(project.path)
    }

    /// Web apps only (a dev script was detected): one click starts the
    /// server. The window has to open — a pane's shell only boots once its
    /// view is mounted, so a background start would sit buffered forever.
    private func startButton(
        project: Project, detected: DevCommandDetect.DefaultCommand
    ) -> some View {
        Button {
            let terminals = TerminalSessionManager.shared
            terminals.pane(for: project.path)
            terminals.send(detected.command + "\n", to: project.path)
            openInWindow(project.path)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.dotActive)
                Text("Start")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().stroke(Theme.buttonStroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Runs \(detected.command) in the project's terminal")
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
            // ScrollView, not a fixed frame: the server page runs taller
            // than the popover once sharing sections expand, and a fixed
            // container clipped the header off the top.
            ScrollView {
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
                .background(heightReader)
            }
        } else if let recent = servers.recent(matching: sid) {
            ScrollView {
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
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .background(heightReader)
            }
        } else {
            VStack(spacing: 8) {
                Text("This server is no longer listening.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                LinkButton(title: "Back to servers", size: 12) { selectedID = nil }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .background(heightReader)
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

/// Carries each page's natural content height up to the root, where it
/// becomes the panel's height.
private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
