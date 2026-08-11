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
    /// A project directory — hosts a terminal.
    case project(String)
    /// A running dev server, by `DevServer.id`.
    case server(String)

    var projectPath: String? {
        if case let .project(path) = self { return path }
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
    /// Project folders currently collapsed, persisted in settings.
    @State private var collapsedFolders = Set(HoustonSettings.read().collapsedFolders)

    /// Clearance for the traffic lights, which float over the sidebar now that
    /// the title bar is transparent and full-size.
    private let trafficLightInset: CGFloat = 36

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
            terminals.startAgentPolling()
            terminals.detectInstalledAgents()
            if let path = ProcessInfo.processInfo.environment["HOUSTON_TEST_PANE"] {
                Task { @MainActor in select(.project(path)) }
            }
        }
        .onChange(of: ownedSessions.map(\.cwd)) { _, _ in pruneSelectionIfStale() }
        .onChange(of: selection) { _, newValue in
            showSkills = false
            showGit = false
            terminals.activeProjectPath = newValue?.projectPath
            git.watch(newValue?.projectPath)
        }
        // Keep the launch selection pointing at something that exists.
        .onChange(of: terminals.installedAgents) { _, installed in
            if !installed.contains(launchAgent), let first = installed.first {
                launchAgent = first
            }
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

    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            Button {
                if let picked = Actions.pickDirectory(
                    title: "Add a projects folder",
                    defaultPath: store.projectsDirs.first
                ) {
                    updateSettings {
                        if !$0.projectsDirs.contains(picked) {
                            $0.projectsDirs.append(picked)
                        }
                    }
                    store.settingsChanged()
                }
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
            topPanel
            Rectangle().fill(Theme.borderHeader).frame(height: 1)
            detailContent
        }
        .background(Theme.background)
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
        case let .project(path): name(of: path)
        case let .server(id):
            servers.devServers.first { $0.id == id }
                .map { $0.project ?? $0.command } ?? "Server"
        case .none: "Houston"
        }
    }

    private var headerSubtitle: String? {
        switch selection {
        case let .project(path): path
        case let .server(id):
            servers.devServers.first { $0.id == id }
                .map { "localhost:" + String($0.port) }
        case .none: nil
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case let .project(path):
            if terminals.hasPane(for: path) {
                ZStack(alignment: .topTrailing) {
                    TerminalHostView(path: path)
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
            EmptyStateView(
                recentProjects: Array(
                    store.projectGroups.flatMap(\.projects)
                        .sorted { $0.modifiedMs > $1.modifiedMs }
                        .prefix(3)
                ),
                onOpen: { select(.project($0.path)) }
            )
        }
    }

    // MARK: - Sidebar data

    /// Only sessions Houston hosts. A session running in Ghostty, VS Code, or a
    /// script is observable (its transcript is on disk) but not displayable —
    /// Houston doesn't hold its pty.
    private var ownedSessions: [ActiveSession] {
        store.sessions.filter(\.isHoustonOwned)
    }

    /// Panes with an agent running in them, from `AgentDetect`'s process scan
    /// rather than session files — instant, and works for agents that write no
    /// session file at all.
    private var activePaths: [String] {
        terminals.agents.keys.sorted(by: byName)
    }

    private var shellPaths: [String] {
        let active = Set(terminals.agents.keys)
        return terminals.panes.keys.filter { !active.contains($0) }.sorted(by: byName)
    }

    /// Projects that already have a shell or agent live in Active/Shells, not
    /// under their folder.
    private func idlePaths(in group: ProjectGroup) -> [String] {
        let taken = Set(terminals.agents.keys).union(terminals.panes.keys)
        return group.projects.map(\.path).filter { !taken.contains($0) }
    }

    private func byName(_ a: String, _ b: String) -> Bool {
        (a as NSString).lastPathComponent
            .localizedCaseInsensitiveCompare((b as NSString).lastPathComponent) == .orderedAscending
    }

    /// The flattened row list the table renders, in the design's section
    /// order: Active, Servers, Shells, Projects.
    private var entries: [SidebarEntry] {
        var out: [SidebarEntry] = []
        if !activePaths.isEmpty {
            out.append(.header("Active"))
            out += activePaths.map { .row(id: .project($0), title: name(of: $0)) }
        }
        if !servers.devServers.isEmpty {
            out.append(.header("Servers"))
            out += servers.devServers.map {
                .row(id: .server($0.id), title: $0.project ?? $0.command)
            }
        }
        // Always present, even empty — its "+" is how a home shell is opened.
        out.append(.header("Shells"))
        out += shellPaths.map { .row(id: .project($0), title: name(of: $0)) }
        if !store.projectGroups.isEmpty {
            out.append(.header("Projects"))
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

    private func height(for entry: SidebarEntry) -> CGFloat {
        switch entry {
        case .header:
            return 21
        case .folder:
            return 26
        case let .row(id, _):
            if case .server = id { return 42 }
            if case let .project(path) = id, state(for: path) == .idle { return 28 }
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
                // A shell that belongs to no project — it opens in `~`.
                if title == "Shells" {
                    Button {
                        select(.project(NSHomeDirectory()))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New shell in your home folder")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.bottom, 2)

        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                    .rotationEffect(collapsed ? .zero : .degrees(90))
                Text(folderName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .modifier(RowChrome(hovered: hovered, selected: false))
            .onTapGesture { toggleFolder(path) }

        case let .row(id, title):
            switch id {
            case let .project(path):
                SidebarRow(
                    name: title,
                    state: state(for: path),
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
            return "h:\(title)"
        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            return "f:\(folderName)|\(collapsed ? "c" : "-")|\(hovered ? "h" : "-")"
        case let .row(id, title):
            let selected = selection == id
            switch id {
            case let .project(path):
                return [
                    title,
                    String(describing: state(for: path)),
                    selected ? "s" : "-",
                    hovered ? "h" : "-",
                ].joined(separator: "|")
            case let .server(sid):
                let port = servers.devServers.first { $0.id == sid }.map { String($0.port) } ?? "-"
                return "\(title)|\(port)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")"
            }
        }
    }

    private func state(for path: String) -> RowState {
        if terminals.agents[path] != nil { return .active }
        if terminals.hasPane(for: path) { return .shell }
        return .idle
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
        if let path = target?.projectPath {
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

    /// Rows that may hold the selection, in sidebar display order (Active
    /// section first): something is running in them.
    private var selectablePaths: [String] { activePaths + shellPaths }

    private func closeTerminal(_ path: String) {
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

/// What a row's dot means.
enum RowState {
    case active, shell, server, idle

    var color: Color {
        switch self {
        case .active: Theme.dotActive
        case .shell: Theme.dotShell
        case .server: Theme.dotServer
        case .idle: .clear
        }
    }
}

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
    let state: RowState
    var hovered: Bool = false
    var selected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Idle (Projects) rows carry no dot; they indent instead — one
            // level under their collapsible folder row.
            if state != .idle {
                Circle()
                    .fill(state.color)
                    .frame(width: 6, height: 6)
            }
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, state == .idle ? 17 : 0)
        .modifier(RowChrome(hovered: hovered, selected: selected))
    }
}

struct ServerRow: View {
    let server: DevServer
    var hovered: Bool = false
    var selected: Bool = false
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(RowState.server.color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
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
