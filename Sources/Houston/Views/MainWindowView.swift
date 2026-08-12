import AppKit
import GhosttyTheme
import SwiftUI

/// What the sidebar can have selected.
///
/// A plain `String?` selection was ambiguous: a server row's id is also a
/// `String`, so selecting a server once set the selection to `"<pid>:<port>"`
/// and Houston tried to open a shell in a directory of that name. Modelling the
/// two kinds of row as distinct cases makes that unrepresentable.
enum SidebarSelection: Hashable {
    /// A project directory — hosts a terminal (the project's first tab).
    case project(String)
    /// An extra terminal tab of a project, shown nested under its row.
    case shell(path: String, tab: UUID)
    /// A running dev server, by `DevServer.id`.
    case server(String)

    var projectPath: String? {
        switch self {
        case let .project(path): path
        case let .shell(path, _): path
        case .server: nil
        }
    }

    /// The specific tab to display; nil means the project's first.
    var tabID: UUID? {
        if case let .shell(_, tab) = self { return tab }
        return nil
    }
}

/// Houston's desktop window, laid out to the Figma design: a white sidebar
/// (Active / Servers / Shells / Projects, "Open Folder…" footer) beside a
/// white detail pane with a title header and the terminal.
///
/// Deliberately **not** `NavigationSplitView`: that owns the title bar, forces
/// `.toolbar` for actions, and dictates row metrics through `List`. Here the
/// window is `fullSizeContentView` with a hidden title, the split is hand
/// drawn, and the sidebar is `NSTableView`-backed — so every control is placed
/// by us, while keyboard navigation and accessibility stay native.
struct MainWindowView: View {
    @StateObject private var store = ActiveSessionStore()
    @StateObject private var servers = DevServerStore()
    @StateObject private var git = GitStatusStore()
    @StateObject private var statusFeed = StatusLineStore()
    @StateObject private var mcp = MCPStatusStore()
    @ObservedObject private var terminals = TerminalSessionManager.shared
    @State private var selection: SidebarSelection?
    /// Agent the header's split button launches; the chevron menu changes it.
    @State private var launchAgent: CodingAgent = .claude
    /// Skills overlay over the terminal. Only shown while an agent is running
    /// in the pane — a bare shell has nothing to apply a skill to.
    @State private var showSkills = false
    @State private var skills: [Skill] = []
    /// Git overlay over the terminal.
    @State private var showGit = false
    /// Uninstalled harness the user picked — drives the install prompt.
    @State private var pendingInstall: CodingAgent?
    /// Mirror of the settings file, for the footer gear's checkmarks.
    @State private var settings = HoustonSettings.read()
    /// Whether Houston's feed script is Claude's configured statusline.
    @State private var statusFeedInstalled = StatusLineFeed.state == .houston
    /// Consent dialog for taking over the Claude statusline.
    @State private var showStatusPrompt = false
    /// The automatic offer fires at most once per launch.
    @State private var statusPromptOffered = false
    /// Project folders currently collapsed, persisted in settings.
    @State private var collapsedFolders = Set(HoustonSettings.read().collapsedFolders)

    /// Clearance for the traffic lights, which float over the sidebar now that
    /// the title bar is transparent and full-size.
    private let trafficLightInset: CGFloat = 48

    /// Sidebar width, dragged by the divider below.
    @State private var sidebarWidth: CGFloat = Theme.sidebarWidth
    private let sidebarRange: ClosedRange<CGFloat> = 180...420

    var body: some View {
        // Plain HStack, not `HSplitView`: NSSplitView-backed `HSplitView`
        // computed a *fitting* height instead of filling its parent, so the
        // whole UI collapsed into a band floating in dead space. A hand-drawn
        // divider is also the point — we own the layout.
        HStack(spacing: 0) {
            sidebarColumn
                .frame(width: sidebarWidth)
            splitDivider
            detailColumn
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        // The titlebar region is a safe area, so without this the whole
        // layout starts ~30pt down: the split divider stopped short of the
        // top and every sidebar section sat lower than designed. Ignoring it
        // runs the sidebar (and divider) to y=0 with the traffic lights
        // floating over the sidebar, as in the design.
        .ignoresSafeArea()
        .onAppear {
            store.start()
            servers.start()
            git.start()
            statusFeed.start()
            terminals.startAgentPolling()
            terminals.detectInstalledAgents()
            if let path = ProcessInfo.processInfo.environment["HOUSTON_TEST_PANE"] {
                Task { @MainActor in select(.project(path)) }
            }
        }
        .onChange(of: ownedSessions.map(\.cwd)) { _, _ in pruneSelectionIfStale() }
        .onChange(of: terminalPaths) { _, paths in git.watchRows(Set(paths)) }
        .onChange(of: selection) { _, newValue in
            showSkills = false
            showGit = false
            terminals.activeProjectPath = newValue?.projectPath
            terminals.activeTabID = newValue?.tabID
            git.watch(newValue?.projectPath)
        }
        // A nested shell closing (⇧⌘W, context menu) must not strand the
        // selection on a dead tab — fall back to the project's main terminal.
        .onChange(of: allTabIDs) { _, ids in
            guard case let .shell(path, tab) = selection, !ids.contains(tab) else { return }
            selection = terminals.hasPane(for: path) ? .project(path) : nil
        }
        // Keep the launch selection pointing at something that exists.
        .onChange(of: terminals.installedAgents) { _, installed in
            if !installed.contains(launchAgent), let first = installed.first {
                launchAgent = first
            }
        }
        // A claude session appearing is the moment the status bar becomes
        // relevant — offer the takeover once, unless previously declined.
        .onChange(of: terminals.agents) { _, agents in
            guard agents.values.contains(.claude),
                  !statusFeedInstalled,
                  !settings.statusLinePromptDeclined,
                  !statusPromptOffered else { return }
            statusPromptOffered = true
            showStatusPrompt = true
        }
        .alert("Show Claude's status in Houston?", isPresented: $showStatusPrompt) {
            Button("Enable") {
                statusFeedInstalled = StatusLineFeed.install()
            }
            Button("Not Now", role: .cancel) {
                updateSettings { $0.statusLinePromptDeclined = true }
            }
        } message: {
            Text(
                "Houston can show each Claude session's model, context and cost in a "
                + "native bar under the terminal — and blank out Claude's own status "
                + "line inside it.\n\nThis replaces the statusLine command in "
                + "~/.claude/settings.json. Your current one is backed up and can be "
                + "restored anytime from the sidebar's gear menu. Running sessions "
                + "switch over at their next response."
            )
        }
    }

    /// Draggable split handle. 1pt line, 6pt hit area.
    private var splitDivider: some View {
        Rectangle()
            .fill(Theme.borderSidebar)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let proposed = sidebarWidth + value.translation.width
                                sidebarWidth = min(
                                    max(proposed, sidebarRange.lowerBound),
                                    sidebarRange.upperBound
                                )
                            }
                    )
            )
    }

    // MARK: - Sidebar column

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: trafficLightInset)
            SidebarTable(
                entries: entries,
                selection: selectionBinding,
                heightForEntry: height(for:),
                content: { entry, hovered in row(for: entry, hovered: hovered) },
                contentKey: contentKey(for:hovered:),
                menuForEntry: menu(for:)
            )
            // NSViewRepresentable has no intrinsic content size, so without
            // this SwiftUI hands it ~zero height and the whole column collapses
            // to fit — the window looked like a small band floating in dead
            // space. `List` was greedy on its own; an NSView is not.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            sidebarFooter
        }
        .background(Theme.background)
    }

    /// Opens the directory picker and registers the choice. A folder that is
    /// itself a project (has `.git`, `package.json`, an `.xcodeproj`, …) is
    /// pinned as a single row; anything else becomes a parent group whose
    /// subdirectories are listed. One button, both intents — and a project
    /// can never be exploded into its `src`/`node_modules` innards.
    private func addFolder() {
        guard let picked = Actions.pickDirectory(
            title: "Add a folder",
            defaultPath: store.projectsDirs.first
        ) else { return }
        updateSettings {
            if ProjectList.isProject(picked) {
                if !$0.pinnedProjects.contains(picked) {
                    $0.pinnedProjects.append(picked)
                }
            } else if !$0.projectsDirs.contains(picked) {
                $0.projectsDirs.append(picked)
            }
        }
        store.settingsChanged()
    }

    /// Sidebar action rows ("New Terminal", "Open Folder…").
    private func runAction(_ key: String) {
        switch key {
        case "new-terminal": select(.project(NSHomeDirectory()))
        case "open-folder": addFolder()
        default: break
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            // Until a folder exists this affordance lives up in the Folders
            // section instead.
            if !store.projectsDirs.isEmpty || !store.pinnedProjects.isEmpty {
                Button {
                    addFolder()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Text("Add Folder...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            settingsMenu
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.borderFooter).frame(height: 1)
        }
    }

    // MARK: - Settings

    /// Footer gear: appearance (System/Light/Dark) and the terminal's theme,
    /// straight from ghostty's catalog.
    private var settingsMenu: some View {
        Menu {
            Picker("Appearance", selection: appearanceBinding) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.inline)

            Menu("Terminal Theme") {
                Picker("Terminal Theme", selection: terminalThemeBinding) {
                    Text("Houston").tag("")
                    ForEach(GhosttyThemeCatalog.allThemes) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            if statusFeedInstalled {
                Button("Disable Claude Status Bar") {
                    StatusLineFeed.restore()
                    statusFeedInstalled = false
                }
            } else {
                Button("Enable Claude Status Bar…") {
                    showStatusPrompt = true
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(Theme.heading)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance and terminal theme")
    }

    private var appearanceBinding: Binding<String> {
        Binding(
            get: { settings.appearance },
            set: { mode in
                updateSettings { $0.appearance = mode }
                NSApp.appearance = settings.nsAppearance
            }
        )
    }

    private var terminalThemeBinding: Binding<String> {
        Binding(
            get: { settings.terminalTheme },
            set: { name in
                updateSettings { $0.terminalTheme = name }
                terminals.applyTerminalTheme(named: name)
            }
        )
    }

    /// Read-modify-write so a stale in-memory copy never clobbers fields
    /// another path (or session) wrote meanwhile.
    private func updateSettings(_ mutate: (inout HoustonSettings) -> Void) {
        var s = HoustonSettings.read()
        mutate(&s)
        HoustonSettings.write(s)
        settings = s
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        VStack(spacing: 0) {
            // The empty state stands alone — no title bar over it.
            if selection != nil {
                topPanel
                Rectangle().fill(Theme.borderHeader).frame(height: 1)
            }
            detailContent
            if let snapshot = activeSnapshot, let path = selection?.projectPath {
                StatusBarView(
                    snapshot: snapshot,
                    mcp: mcp.statuses[path],
                    mcpAuthInFlight: mcp.authInFlight,
                    onSelectModel: { modelArg in
                        switchModel(to: modelArg, snapshot: snapshot)
                    },
                    onManageMCP: { sendToSnapshotPane("/mcp\n", snapshot: snapshot) },
                    onRefreshMCP: { mcp.refresh(path: path) },
                    onAuthenticateMCP: { mcp.login(server: $0, path: path) },
                    onLogoutMCP: { mcp.logout(server: $0, path: path) }
                )
                .onAppear { mcp.refreshIfStale(path: path) }
            }
        }
        .background(Theme.background)
    }

    /// The feed snapshot the status bar shows: the freshest one among the
    /// displayed tab's panes, gated on an agent actually running so a
    /// leftover dump can't outlive its session. Nil hides the bar.
    private var activeSnapshot: StatusLineSnapshot? {
        guard let path = selection?.projectPath,
              terminals.agents[path] != nil,
              let list = terminals.tabs[path] else { return nil }
        let tab = selection?.tabID.flatMap { id in list.first { $0.id == id } } ?? list.first
        return (tab?.panes ?? [])
            .compactMap { statusFeed.snapshots[$0.id.uuidString] }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Title + path on the left, actions on the right. Replaces
    /// `navigationTitle` + `.toolbar` entirely, so controls sit where we put
    /// them rather than where the system decides.
    private var topPanel: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPath)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            if let path = selection?.projectPath, terminals.hasPane(for: path) {
                headerActions(for: path)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func headerActions(for path: String) -> some View {
        // Branch button: live git state at a glance, panel on click.
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                showGit.toggle()
                showSkills = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text.opacity(0.75))
                Text(gitButtonTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let info = git.info, info.isRepo, !info.changes.isEmpty {
                    Circle()
                        .fill(Color(hex: 0xD97706))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome())
        .help("Git status")

        // Skills only exist inside an agent session, so the button appears
        // with the agent and leaves with it.
        if terminals.agents[path] != nil {
            Button {
                if !showSkills { skills = SkillsCatalog.load(projectPath: path) }
                withAnimation(.easeOut(duration: 0.18)) { showSkills.toggle() }
            } label: {
                Text("Skills")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .modifier(HeaderButtonChrome())
            .help("Apply a skill to this session")
        }

        // Split launch button: the menu picks the agent, play starts it.
        // Uninstalled harnesses are listed too — picking one offers to run
        // its install command instead of silently failing.
        launchButton(for: path)

        Button {
            closeTerminal(path)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.closeRed)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome())
        .help("End this shell and everything running in it")
    }

    private func launchButton(for path: String) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(CodingAgent.launchable, id: \.self) { agent in
                    if terminals.installedAgents.contains(agent) {
                        Button(agent.label) { launchAgent = agent }
                    } else {
                        Button {
                            pendingInstall = agent
                        } label: {
                            Label(agent.label, systemImage: "arrow.down.circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(launchAgent.shortLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Rectangle()
                .fill(Theme.buttonStroke)
                .frame(width: 1, height: 30)

            Button {
                if terminals.installedAgents.contains(launchAgent) {
                    terminals.start(launchAgent, in: path)
                } else {
                    pendingInstall = launchAgent
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run \(launchAgent.label) in this project's shell")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .modifier(HeaderButtonChrome())
        .alert(
            "Install \(pendingInstall?.label ?? "")?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            ),
            presenting: pendingInstall
        ) { agent in
            Button("Install") {
                launchAgent = agent
                terminals.install(agent, in: path)
            }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text(
                "\(agent.label) isn't installed. Houston will run:\n\n"
                + (agent.installCommand ?? "")
                + "\n\nin this project's shell."
            )
        }
    }

    private var gitButtonTitle: String {
        guard let info = git.info else { return "Git" }
        return info.isRepo ? info.branchLabel : "Git"
    }

    private var headerTitle: String {
        switch selection {
        case let .project(path), let .shell(path, _): name(of: path)
        case let .server(id):
            servers.devServers.first { $0.id == id }
                .map { $0.project ?? $0.command } ?? "Server"
        case .none: "Houston"
        }
    }

    private var headerSubtitle: String? {
        switch selection {
        case let .project(path), let .shell(path, _): path
        case let .server(id):
            servers.devServers.first { $0.id == id }
                .map { "localhost:" + String($0.port) }
        case .none: nil
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case let .project(path), let .shell(path, _):
            if terminals.hasPane(for: path) {
                ZStack(alignment: .topTrailing) {
                    TerminalHostView(path: path, tabID: selection?.tabID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Floats over the terminal; the agent-gate mirrors the
                    // button so the card leaves with the session.
                    if showSkills, terminals.agents[path] != nil {
                        SkillsPanel(skills: skills) { skill in
                            terminals.send("/\(skill.name) ", to: path)
                            withAnimation(.easeOut(duration: 0.18)) { showSkills = false }
                        }
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if showGit {
                        GitPanel(info: git.info, projectPath: path) {
                            terminals.send("git init\n", to: path)
                            git.refresh()
                        }
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No terminal open", systemImage: "terminal")
                } description: {
                    Text((path as NSString).lastPathComponent)
                } actions: {
                    Button("Open Terminal") { terminals.pane(for: path) }
                }
            }
        case let .server(id):
            if let server = servers.devServers.first(where: { $0.id == id }) {
                ServerDetailView(
                    server: server,
                    onOpenTerminal: {
                        guard let cwd = server.cwd else { return }
                        select(.project(cwd))
                    }
                )
            } else {
                ContentUnavailableView(
                    "Server stopped",
                    systemImage: "bolt.slash",
                    description: Text("This server is no longer listening.")
                )
            }
        case .none:
            EmptyStateView()
        }
    }

    // MARK: - Sidebar data

    /// Only sessions Houston hosts. A session running in Ghostty, VS Code, or a
    /// script is observable (its transcript is on disk) but not displayable —
    /// Houston doesn't hold its pty.
    private var ownedSessions: [ActiveSession] {
        store.sessions.filter(\.isHoustonOwned)
    }

    /// Every open terminal's project, alphabetical — one Terminals section.
    /// Whether a row is a bare shell or an agent session is told by its icon,
    /// so starting an agent swaps the icon in place instead of moving the row.
    private var terminalPaths: [String] {
        terminals.tabs.keys.sorted(by: byName)
    }

    /// Every live tab id, for pruning a selection whose tab closed.
    private var allTabIDs: Set<UUID> {
        Set(terminals.tabs.values.flatMap { $0.map(\.id) })
    }

    /// Projects that already have a shell or agent live in Active, not under
    /// their folder — and a pinned project keeps its own row rather than
    /// doubling up inside a group that happens to contain it.
    private func idlePaths(in group: ProjectGroup) -> [String] {
        let taken = Set(terminals.agents.keys)
            .union(terminals.tabs.keys)
            .union(store.pinnedProjects)
        return group.projects.map(\.path).filter { !taken.contains($0) }
    }

    private func byName(_ a: String, _ b: String) -> Bool {
        (a as NSString).lastPathComponent
            .localizedCaseInsensitiveCompare((b as NSString).lastPathComponent) == .orderedAscending
    }

    /// The flattened row list the table renders: Terminals, Servers, Projects.
    private var entries: [SidebarEntry] {
        var out: [SidebarEntry] = []
        out.append(.header("Active"))
        // Empty section: a spelled-out affordance instead of the header "+"
        // (which hides until a terminal exists).
        if terminalPaths.isEmpty {
            out.append(.action(key: "new-terminal", title: "New Terminal"))
        }
        for path in terminalPaths {
            out.append(.row(id: .project(path), title: name(of: path)))
            // Extra tabs nest under the project's row, numbered with it.
            for (index, tab) in (terminals.tabs[path] ?? []).enumerated().dropFirst() {
                out.append(.row(
                    id: .shell(path: path, tab: tab.id),
                    title: "\(name(of: path)) · \(index + 1)"
                ))
            }
        }
        if !servers.devServers.isEmpty {
            out.append(.header("Servers"))
            out += servers.devServers.map {
                .row(id: .server($0.id), title: $0.project ?? $0.command)
            }
        }
        // No folders configured yet: the section leads with its own "Open
        // Folder…" affordance; once one exists the action lives in the footer.
        let taken = Set(terminals.agents.keys).union(terminals.tabs.keys)
        let idlePinned = store.pinnedProjects.filter { !taken.contains($0) }
        if store.projectsDirs.isEmpty, store.pinnedProjects.isEmpty {
            out.append(.header("Projects"))
            out.append(.action(key: "open-folder", title: "Open Folder…"))
        } else if !store.projectGroups.isEmpty || !idlePinned.isEmpty {
            out.append(.header("Projects"))
            // Pinned single projects: their own rows, never expanded.
            out += idlePinned.map { .row(id: .project($0), title: name(of: $0)) }
            for group in store.projectGroups {
                out.append(.folder(path: group.path, name: group.name))
                if !collapsedFolders.contains(group.path) {
                    out += idlePaths(in: group).map {
                        .row(id: .project($0), title: name(of: $0))
                    }
                }
            }
        }
        return out
    }

    private func toggleFolder(_ path: String) {
        if collapsedFolders.contains(path) {
            collapsedFolders.remove(path)
        } else {
            collapsedFolders.insert(path)
        }
        updateSettings { $0.collapsedFolders = Array(collapsedFolders) }
    }

    private func name(of path: String) -> String {
        path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
    }

    /// Types into the exact pane the status snapshot came from — the feed
    /// keys payloads by pane id, so the command can't land in a sibling
    /// shell.
    private func sendToSnapshotPane(_ text: String, snapshot: StatusLineSnapshot) {
        guard let path = selection?.projectPath,
              let pane = (terminals.tabs[path] ?? [])
                  .flatMap(\.panes)
                  .first(where: { $0.id.uuidString == snapshot.paneID })
        else { return }
        pane.send(text)
    }

    private func switchModel(to arg: String, snapshot: StatusLineSnapshot) {
        sendToSnapshotPane("/model \(arg)\n", snapshot: snapshot)
    }

    /// The agent running in a *specific* nested shell, told by the statusline
    /// feed: a claude session writes a payload keyed by its pane's id, so a
    /// snapshot for one of the tab's panes means claude is initialized right
    /// there. Gated on the project-level scan so a leftover payload file
    /// can't badge a shell after every agent under the path has exited.
    private func shellAgent(path: String, tab tabID: UUID) -> CodingAgent? {
        guard terminals.agents[path] != nil,
              let tab = terminals.tabs[path]?.first(where: { $0.id == tabID }),
              tab.panes.contains(where: { statusFeed.snapshots[$0.id.uuidString] != nil })
        else { return nil }
        return .claude
    }

    /// The agent badge for a project's main row. The process scan is
    /// per-path, so once extra tabs exist it can't say *which* shell runs
    /// claude — attribute it to the main tab only if one of its panes has a
    /// feed snapshot, same as the nested rows. Non-claude agents write no
    /// feed, so they stay on the main row rather than vanishing.
    private func primaryAgent(path: String) -> CodingAgent? {
        guard let agent = terminals.agents[path] else { return nil }
        let list = terminals.tabs[path] ?? []
        guard agent == .claude, list.count > 1, let first = list.first else { return agent }
        let initialized = first.panes.contains {
            statusFeed.snapshots[$0.id.uuidString] != nil
        }
        return initialized ? .claude : nil
    }

    private func height(for entry: SidebarEntry) -> CGFloat {
        switch entry {
        case .header:
            // Tall enough for the Terminals header's 24pt "+" chip, with the
            // extra space above acting as the gap between sections.
            return 32
        case .folder, .action:
            return 26
        case let .row(id, _):
            if case .server = id { return 42 }
            if case .shell = id { return 28 }
            if case let .project(path) = id, !terminals.hasPane(for: path) { return 28 }
            return 32
        }
    }

    // MARK: - Sidebar rows

    @ViewBuilder
    private func row(for entry: SidebarEntry, hovered: Bool) -> some View {
        switch entry {
        case let .header(title):
            HStack(alignment: .center, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                Spacer(minLength: 0)
                // New-terminal menu: a split beside the current terminal, or
                // a fresh shell that belongs to no project (opens in `~`).
                // Hidden while no terminal is open — the section shows a
                // spelled-out "New Terminal" row instead.
                if title == "Active", !terminalPaths.isEmpty {
                    Menu {
                        // A second shell in the selected terminal's directory
                        // — its own nested row under that terminal.
                        if let path = selection?.projectPath, terminals.hasPane(for: path) {
                            Button("New shell in \(name(of: path))") {
                                if let tab = terminals.newTab(in: path) {
                                    select(.shell(path: path, tab: tab.id))
                                }
                            }
                        }
                        Button("New shell in home folder") {
                            select(.project(NSHomeDirectory()))
                        }
                    } label: {
                        HeaderPlusLabel()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New terminal")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.bottom, 2)

        case let .action(key, title):
            HStack(spacing: 8) {
                Image(systemName: key == "open-folder" ? "folder.badge.plus" : "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .modifier(RowChrome(hovered: hovered, selected: false))
            .onTapGesture { runAction(key) }

        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                Text(folderName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Disclosure state, far right.
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heading)
            }
            .modifier(RowChrome(hovered: hovered, selected: false))
            .onTapGesture { toggleFolder(path) }

        case let .row(id, title):
            switch id {
            case let .project(path):
                let active = terminals.hasPane(for: path)
                SidebarRow(
                    name: title,
                    agent: primaryAgent(path: path),
                    hasTerminal: active,
                    isProject: !active && ProjectKindCache.isProject(path),
                    gitStatus: git.rowStatuses[path] ?? .none,
                    hovered: hovered,
                    selected: selection == id
                )
            case let .shell(path, tabID):
                SidebarRow(
                    name: title,
                    agent: shellAgent(path: path, tab: tabID),
                    hasTerminal: true,
                    nested: true,
                    hovered: hovered,
                    selected: selection == id
                )
            case let .server(sid):
                if let server = servers.devServers.first(where: { $0.id == sid }) {
                    ServerRow(
                        server: server,
                        hovered: hovered,
                        selected: selection == id,
                        onOpen: { Actions.openExternal(server.url) }
                    )
                }
            }
        }
    }

    /// Everything `row(for:hovered:)` reads, flattened. Cheap to build and
    /// compare; keeps rows from being re-hosted on every poll.
    private func contentKey(for entry: SidebarEntry, hovered: Bool) -> String {
        switch entry {
        case let .header(title):
            // The Terminals header's "+" menu offers a shell in the selected
            // terminal's directory, so its content depends on the selection —
            // without this in the key the header is never re-hosted and the
            // menu keeps the selection it captured at launch (nil).
            if title == "Active" {
                let sel = selection?.projectPath
                    .flatMap { terminals.hasPane(for: $0) ? $0 : nil } ?? "-"
                return "h:\(title)|\(sel)|\(terminalPaths.isEmpty ? "-" : "t")"
            }
            return "h:\(title)"
        case let .action(key, _):
            return "a:\(key)|\(hovered ? "h" : "-")"
        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            return "f:\(folderName)|\(collapsed ? "c" : "-")|\(hovered ? "h" : "-")"
        case let .row(id, title):
            let selected = selection == id
            switch id {
            case let .project(path):
                return [
                    title,
                    terminals.hasPane(for: path) ? "t" : "-",
                    primaryAgent(path: path)?.label ?? "-",
                    ProjectKindCache.isProject(path) ? "p" : "-",
                    String(describing: git.rowStatuses[path] ?? .none),
                    selected ? "s" : "-",
                    hovered ? "h" : "-",
                ].joined(separator: "|")
            case let .shell(path, tab):
                let agent = shellAgent(path: path, tab: tab)?.label ?? "-"
                return "sh:\(title)|\(tab)|\(agent)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")"
            case let .server(sid):
                let port = servers.devServers.first { $0.id == sid }.map { String($0.port) } ?? "-"
                return "\(title)|\(port)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")"
            }
        }
    }

    // MARK: - Context menus

    private func menu(for entry: SidebarEntry) -> NSMenu? {
        if case let .folder(path, _) = entry {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                Actions.revealInFinder(path: path)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Sidebar") {
                updateSettings { $0.projectsDirs.removeAll { $0 == path } }
                store.settingsChanged()
            })
            return menu
        }
        guard let id = entry.selection else { return nil }
        let menu = NSMenu()
        switch id {
        case let .shell(path, tabID):
            menu.addItem(ClosureMenuItem("Close Terminal") {
                terminals.closeTab(path: path, tabID: tabID)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                Actions.revealInFinder(path: path)
            })
        case let .project(path):
            if terminals.hasPane(for: path) {
                menu.addItem(ClosureMenuItem("Start Claude") { terminals.start(.claude, in: path) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Close Terminal") { closeTerminal(path) })
            } else {
                menu.addItem(ClosureMenuItem("Open Terminal") { terminals.pane(for: path) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                Actions.revealInFinder(path: path)
            })
            if store.pinnedProjects.contains(path) {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Remove from Sidebar") {
                    updateSettings { $0.pinnedProjects.removeAll { $0 == path } }
                    store.settingsChanged()
                })
            }
        case let .server(sid):
            guard let server = servers.devServers.first(where: { $0.id == sid }) else { return nil }
            menu.addItem(ClosureMenuItem("Open in Browser") {
                Actions.openExternal(server.url)
            })
            if let cwd = server.cwd {
                menu.addItem(ClosureMenuItem("Open Terminal Here") {
                    terminals.pane(for: cwd)
                    selection = .project(cwd)
                })
                menu.addItem(ClosureMenuItem("Reveal in Finder") {
                    Actions.revealInFinder(path: cwd)
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Stop Server") { Actions.killPid(server.pid) })
        }
        return menu
    }

    // MARK: - Selection rules

    /// Selecting a project must open its pane *before* the selection renders:
    /// the pane used to be created in a deferred Task, so SwiftUI drew a
    /// frame of the "No terminal open" fallback between the click and the
    /// pane existing — a visible flash on every first open. Every selection
    /// path (table click, quick-open, "+", server jump) runs in an event
    /// context where creating the pane synchronously is safe.
    private func select(_ target: SidebarSelection?) {
        if case let .project(path) = target {
            terminals.pane(for: path)
        }
        selection = target
    }

    /// `$selection` for the table, routed through `select(_:)`.
    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { select($0) }
        )
    }

    /// Rows that may hold the selection, in sidebar display order: something
    /// is running in them.
    private var selectablePaths: [String] { terminalPaths }

    private func closeTerminal(_ path: String) {
        // Header X on a nested shell ends just that tab; the tab-prune
        // onChange moves the selection back to the project's main terminal.
        if case let .shell(shellPath, tabID) = selection, shellPath == path {
            terminals.closeTab(path: shellPath, tabID: tabID)
            return
        }
        let order = selectablePaths
        let index = order.firstIndex(of: path)
        let wasSelected = (selection == .project(path))

        terminals.closePane(for: path)

        guard wasSelected else { return }
        let remaining = order.filter { $0 != path }
        guard !remaining.isEmpty, let index else {
            selection = nil
            return
        }
        select(.project(remaining[min(index, remaining.count - 1)]))
    }

    /// A session ending on its own can strand the selection on a row that has
    /// dropped back to Projects.
    private func pruneSelectionIfStale() {
        guard let path = selection?.projectPath else { return }
        // Don't act on a partial picture — `ownedSessions` is empty before the
        // first poll completes, and pruning against that bounced the selection
        // to an unrelated project on launch.
        guard !ownedSessions.isEmpty else { return }
        guard !selectablePaths.contains(path) else { return }
        selection = selectablePaths.first.map { SidebarSelection.project($0) }
    }
}

// MARK: - Header button chrome

/// The design's header buttons: 30pt tall, #F3F3F3 fill, #E0E0E0 hairline,
/// 6pt radius. Also used by the empty state's quick-open buttons.
struct HeaderButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: 30)
            .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.buttonStroke, lineWidth: 1)
            )
    }
}

// MARK: - Rows

/// Shared background for sidebar rows: the design's 220pt pill (8pt radius,
/// 16pt inner padding) inset `Theme.rowInset` from the sidebar edges.
///
/// Selection *and* hover are drawn here rather than by the table. Source-list
/// selection styling would only cover half of it — `NSTableView` has no hover
/// concept at all — and drawing the two in different layers is exactly what
/// produced mismatched, doubled highlights before. One place, one geometry.
private struct RowChrome: ViewModifier {
    let hovered: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .padding(.horizontal, Theme.rowInset)
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if selected { return Theme.rowSelected }
        if hovered { return Theme.rowHovered }
        return .clear
    }
}

struct SidebarRow: View {
    let name: String
    var agent: CodingAgent? = nil
    var hasTerminal: Bool = false
    /// An extra terminal tab nested under its project's row: indented, no
    /// git dot (same repo as the parent), plain terminal glyph.
    var nested: Bool = false
    /// The row's directory is itself a project (has `.git`, a manifest, …)
    /// rather than a plain folder — idle project rows get a project glyph.
    var isProject: Bool = false
    var gitStatus: GitRowStatus = .none
    var hovered: Bool = false
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Active rows: git status dot on the left, session identity
            // (agent logo or terminal glyph) on the right. Idle rows lead
            // with a project glyph when they are projects, else indent.
            if hasTerminal, !nested {
                Circle()
                    .fill(gitColor)
                    .frame(width: 6, height: 6)
                    .help(gitHelp)
            } else if !hasTerminal, isProject {
                Image(systemName: "shippingbox")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
            }
            Text(name)
                .font(.system(size: nested ? 12 : 13))
                .foregroundStyle(nested ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hasTerminal {
                TerminalRowIcon(agent: agent, size: nested ? 13 : 16)
            }
        }
        .padding(.leading, nested ? 17 : (hasTerminal || isProject ? 0 : 17))
        .modifier(RowChrome(hovered: hovered, selected: selected))
    }

    private var gitColor: Color {
        switch gitStatus {
        case .none: Theme.dotShell
        case .dirty: Color(hex: 0xD97706)
        case .clean: Theme.dotActive
        }
    }

    private var gitHelp: String {
        switch gitStatus {
        case .none: "Not a git repository"
        case .dirty: "Uncommitted changes"
        case .clean: "Working tree clean"
        }
    }
}

struct ServerRow: View {
    let server: DevServer
    var hovered: Bool = false
    var selected: Bool = false
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.project ?? server.command)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                // String(...) not "\(port)" — interpolating an Int applies
                // locale digit grouping and renders "localhost:3,000".
                Text("localhost:" + String(server.port))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Quick open — the detail view's "Open in Browser" without the
            // detour. Appears on hover, when the pointer is already here.
            if hovered {
                OpenInBrowserButton(action: onOpen)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.vertical, 6)
        .modifier(RowChrome(hovered: hovered, selected: selected))
    }
}

/// The Terminals header's "+": quiet glyph that gets the row-hover fill
/// under the pointer.
private struct HeaderPlusLabel: View {
    @State private var hovered = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.heading)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// Small arrow button that brightens under its own hover.
private struct OpenInBrowserButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.heading)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open in Browser")
    }
}

/// `NSMenuItem` that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
