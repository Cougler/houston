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

/// What the right sheet can show — Git, Skills, the notification feed,
/// Tasks (which carries Reminders as its second tab), or a dev server (by
/// `DevServer.id`). One sheet, so the panels are exclusive by construction.
enum RightPanel: Equatable {
    case git, skills, feed, tasks
    case server(String)
    /// A project's capsule shelf — its sealed chats. `focus` (a capsule
    /// id) lands straight in that capsule's transcript view.
    case capsules(project: String, focus: String?)
}

/// Which terminal row the rename card is editing.
struct RenameTarget: Equatable {
    let path: String
    let tabID: UUID
}

/// The tasks sheet's two pages: the cross-project task lists and the
/// Tracked reminders, which push from a row in the All Tasks root.
enum TaskSheetTab: String, CaseIterable {
    case tasks = "Tasks"
    case reminders = "Reminders"
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
    // Shared, not @StateObject-owned: the menubar popover renders the same
    // servers / share / relay state, and the proxy and relay tunnels must
    // exist exactly once.
    @ObservedObject private var servers = DevServerStore.shared
    @ObservedObject private var share = ShareProxyStore.shared
    @ObservedObject private var relay = RelayTunnelStore.shared
    @StateObject private var git = GitStatusStore()
    @StateObject private var statusFeed = StatusLineStore()
    @StateObject private var mcp = MCPStatusStore()
    @StateObject private var handoffs = HandoffCoordinator()
    @ObservedObject private var terminals = TerminalSessionManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared
    @ObservedObject private var notify = NotifyStore.shared
    @StateObject private var tracked = TrackedStore()
    @ObservedObject private var feed = EventFeed.shared
    @State private var selection: SidebarSelection?
    /// What the right sheet shows. One sheet, four contents — Git, Skills,
    /// Tracked, and the notification feed are mutually exclusive by type.
    @State private var rightPanel: RightPanel?
    /// Docked: the sheet joins the layout and pushes the detail column.
    /// Floating (default): it overlays the content, click-away dismisses.
    @State private var rightPanelDocked = false
    /// The tasks sheet's navigation: nil shows All Tasks (the root), a path
    /// shows that project's page nested under it (Back pops to nil).
    @State private var taskSheetProject: String? = nil
    /// Which tab the tasks sheet shows — Tasks or Reminders.
    @State private var taskSheetTab: TaskSheetTab = .tasks
    /// Hover for the breadcrumb's "All Tasks" button in the sheet title bar.
    @State private var crumbHovered = false
    /// Project headers whose chat list is folded away (persisted under the
    /// old `collapsedFolders` settings key).
    @State private var collapsedProjects = Set(HoustonSettings.read().collapsedFolders)
    /// Chat rows disclosed per project beyond the base few ("Show more") —
    /// cleared when the project collapses, so reopening shows the short list.
    @State private var chatRowsShown: [String: Int] = [:]
    /// The Servers item's flyout is open — stopped (recent) servers in a
    /// second-layer card beside the sidebar, same chrome as the rail's
    /// flyouts. Session-only, like hover state.
    @State private var serversFlyout = false
    /// Capsule rows shown per project — starts at 5, "Show more" steps by
    /// 5 (mirroring the chats' disclosure). Resets when the project
    /// header folds.
    @State private var capsuleRowsShown: [String: Int] = [:]
    /// Projects whose archived chats are expanded in the sidebar — the
    /// only surface archived chats appear on (the transcript view has no
    /// list anymore).
    @State private var archivedShown: Set<String> = []
    /// The detail pane shows a project's chat archive instead of the
    /// terminal — independent of the selection, so opening a chat never
    /// disturbs which terminal is live. Clears on any selection change.
    struct ChatTarget: Hashable {
        var path: String
        var sessionFile: String?
    }
    @State private var chatTarget: ChatTarget?
    @StateObject private var chatIndex = ChatIndexStore.shared
    @StateObject private var chatTitler = ChatTitler.shared
    @StateObject private var chatMeta = ChatMetaStore.shared
    @StateObject private var capsuleStore = CapsuleStore.shared
    /// Last panel shown — what the sheet renders while sliding closed.
    @State private var lastRightPanel: RightPanel?
    /// Agent the header's split button launches; the chevron menu changes it.
    @State private var launchAgent: CodingAgent = .claude
    @State private var skills: [Skill] = []
    /// Uninstalled harness the user picked — drives the install prompt.
    @State private var pendingInstall: CodingAgent?
    /// The harness selector's popped menu, for its active chrome.
    @State private var agentMenuOpen = false
    @State private var agentMenuBox = MenuAnchorBox()
    /// Mirror of the settings file, for the footer gear's checkmarks.
    @State private var settings = HoustonSettings.read()
    /// Whether Houston's feed script is Claude's configured statusline.
    @State private var statusFeedInstalled = StatusLineFeed.state == .houston
    /// Consent dialog for taking over the Claude statusline.
    @State private var showStatusPrompt = false
    /// The searchable terminal-theme popover, opened from the footer gear.
    @State private var showThemePicker = false
    @State private var showChatColors = false
    @StateObject private var chatStyle = ChatStyleStore.shared
    /// The terminal row being renamed inline in the sidebar; nil = none.
    @State private var renameTarget: RenameTarget?
    /// Whether Houston's hooks feed notifications (mirrors settings.json).
    @State private var notifyInstalled = NotifyFeed.isInstalled
    /// Consent dialog for installing the notification hooks.
    @State private var showNotifyPrompt = false
    /// The automatic offer fires at most once per launch.
    @State private var statusPromptOffered = false
    /// Project folders currently collapsed, persisted in settings.
    @State private var collapsedFolders = Set(HoustonSettings.read().collapsedFolders)
    /// First-launch onboarding: a full-window takeover on the empty-state
    /// sky (sidebar hidden underneath), until dismissed once.
    @State private var showOnboarding = !HoustonSettings.read().onboardingSeen
    /// While the onboarding takeover is up, the sidebar isn't laid out at
    /// all: the detail column spans the window, putting the empty state's
    /// solar system at the same window center the onboarding's occupies.
    /// Dismissal fades the overlay onto that aligned system, then slides
    /// the sidebar in, gliding the system to the detail center with no jump.
    @State private var sidebarRevealed = HoustonSettings.read().onboardingSeen
    /// Sidebar collapsed to the three-icon rail, persisted in settings.
    @State private var sidebarCollapsed = HoustonSettings.read().sidebarCollapsed
    /// The rail section whose popover is open, while collapsed.
    @State private var railPopover: RailSection?

    /// Clearance for the traffic lights, which float over the sidebar now that
    /// the title bar is transparent and full-size.
    private let trafficLightInset: CGFloat = 48

    /// Sidebar width, dragged by the divider below.
    // Restored from settings; the literal bounds mirror `sidebarRange`,
    // which isn't available in a property initializer.
    @State private var sidebarWidth: CGFloat =
        min(max(CGFloat(HoustonSettings.read().sidebarWidth), 180), 420)
    /// Below this width the library rows' inline diff counts come off and
    /// move into hover tooltips — squeezed against a long name they were
    /// the first thing to look broken.
    private var sidebarNarrow: Bool { sidebarWidth < 210 }
    private let sidebarRange: ClosedRange<CGFloat> = 180...420
    /// Width when the divider drag began — translation is cumulative from the
    /// gesture's start, so it must be applied to the start width, not the
    /// live one.
    @State private var sidebarDragStart: CGFloat?
    /// The terminal region's frame in root coordinates — where the floating
    /// panels live. The outside-click scrim covers everything around it.
    /// Pointer over the divider's grip — lights the faint stroke that tells
    /// the user there's something to grab.
    @State private var dividerHovered = false
    /// Right sheet width, dragged by its leading edge; bounds mirror
    /// `rightSheetRange` (unavailable in a property initializer).
    @State private var rightSheetWidth: CGFloat =
        min(max(CGFloat(HoustonSettings.read().rightSheetWidth), 300), 600)
    private let rightSheetRange: ClosedRange<CGFloat> = 300...600
    @State private var rightSheetDragStart: CGFloat?
    @State private var rightSheetDividerHovered = false

    var body: some View {
        // Plain HStack, not `HSplitView`: NSSplitView-backed `HSplitView`
        // computed a *fitting* height instead of filling its parent, so the
        // whole UI collapsed into a band floating in dead space. A hand-drawn
        // divider is also the point — we own the layout.
        HStack(spacing: 0) {
            if sidebarCollapsed {
                railColumn
                    .frame(width: sidebarRevealed ? railWidth : 0)
                    .clipped()
            } else {
                sidebarColumn
                    .frame(width: sidebarRevealed ? sidebarWidth : 0)
                    .clipped()
            }
            // One divider for both states, outside the branch so its view —
            // and any drag mid-flight through a collapse/expand — survives
            // the swap.
            splitDivider
                .opacity(sidebarRevealed ? 1 : 0)
            detailColumn
                .frame(maxWidth: .infinity)
            // Docked: reserve the sheet's width in the layout. The sheet
            // itself always draws in the overlay flush with the right edge,
            // so pin/unpin animates nothing but this width (and the scrim) —
            // no re-parenting, no jump.
            Color.clear
                .frame(width: rightPanelDocked && rightPanel != nil
                    ? rightSheetWidth : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarFill)
        .overlay(alignment: .topLeading) { railFlyoutLayer }
        .overlay(alignment: .topLeading) { serversFlyoutLayer }
        .overlay(alignment: .bottomLeading) { themePickerLayer }
        .overlay(alignment: .bottomLeading) { chatColorsLayer }
        .overlay(alignment: .topTrailing) { rightSheetLayer }
        // One overlay link, contents extracted — inline closures here push
        // the root body past the type-checker's limit.
        .overlay { modalLayer }
        // The titlebar region is a safe area, so without this the whole
        // layout starts ~30pt down: the split divider stopped short of the
        // top and every sidebar section sat lower than designed. Ignoring it
        // runs the sidebar (and divider) to y=0 with the traffic lights
        // floating over the sidebar, as in the design.
        .ignoresSafeArea()
        .onAppear {
            store.start()
            servers.start()
            share.start()
            git.start()
            git.watchRows(gitWatchSet)
            statusFeed.start()
            notify.start()
            tracked.start()
            terminals.startAgentPolling()
            terminals.detectInstalledAgents()
            chatIndex.refreshAll(store.pinnedProjects)
            // Ship the mission skills: copy any that are missing into
            // ~/.claude/skills so Start Mission / Handoff / End Mission work
            // on a machine that never had them.
            Task.detached(priority: .utility) { HoustonSkills.installMissing() }
            if let path = ProcessInfo.processInfo.environment["HOUSTON_TEST_PANE"] {
                Task { @MainActor in select(.project(path)) }
            }
        }
        .onChange(of: ownedSessions.map(\.cwd)) { _, _ in pruneSelectionIfStale() }
        // Every dev-server tick re-feeds the share proxy's Host-header routes
        // and the set of `<project>.local` names advertised over Bonjour.
        .onChange(of: servers.devServers) { _, list in
            share.update(servers: list)
            relay.update(servers: list)
        }
        .onChange(of: gitWatchSet) { _, set in git.watchRows(set) }
        // Commit watch for the bell's feed: HEAD moving on the watched
        // project's branch becomes a "Committed"/"New commits" event.
        .onChange(of: git.info) { _, info in
            feed.noteGit(path: selection?.projectPath, info: info)
        }
        // A project's last terminal closing (✕, ⇧⌘W, ctrl-D) lands on the
        // solar-system empty state, not a dead detail page.
        .onChange(of: terminalPaths) { _, paths in
            if case let .project(path) = selection, !paths.contains(path),
               !terminals.hasPane(for: path) {
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            // Picking a sidebar row means "show me that terminal" — chat
            // mode never follows the selection.
            chatTarget = nil
            if let path = newValue?.projectPath { chatIndex.refresh(path) }
            // Navigation does NOT dismiss the sheet (docked or floating) —
            // its content follows the selection instead (git already
            // watches it; skills reload here). Dismissal is dead-chrome
            // clicks and the ✕ only.
            if rightPanel == .skills, let path = newValue?.projectPath {
                skills = SkillsCatalog.load(projectPath: path)
            }
            terminals.activeProjectPath = newValue?.projectPath
            terminals.activeTabID = newValue?.tabID
            git.watch(newValue?.projectPath)
            notify.markSeen(projectPath: newValue?.projectPath)
        }
        // Coming back to Houston with a flagged project on screen spends its
        // attention; a banner click routes to the project it came from.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            notify.markSeen(projectPath: selection?.projectPath)
            // Coming back from another app lands you typing in the selected
            // terminal, no click needed. A text field mid-edit (rename, task
            // input) keeps focus — only "nowhere useful" is redirected;
            // focusTerminal itself already stays put when a pane has it.
            if let path = selection?.projectPath,
               terminals.hasPane(for: path),
               !(NSApp.keyWindow?.firstResponder is NSTextView) {
                terminals.focusTerminal(path: path, tab: selection?.tabID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .houstonOpenProject)) { note in
            if let path = note.userInfo?["path"] as? String {
                // An optional "tab" targets a specific nested shell (the
                // chat login flow opens a fresh tab when the main pane is
                // busy); without it the project's main terminal is fine.
                if let raw = note.userInfo?["tab"] as? String,
                   let tab = UUID(uuidString: raw) {
                    select(.shell(path: path, tab: tab))
                } else {
                    select(.project(path))
                }
            }
        }
        // Keyboard shortcuts, routed from MainMenu — the menu owns no state,
        // so anything needing the selection lands here. Hung off a background
        // view: seven more onReceive links on the root chain pushed the
        // type-checker past its time limit.
        .background(shortcutListeners)
        // Clicking into a terminal pane dismisses a floating sheet — ghostty
        // eats the click, so it arrives as a notification instead.
        .onReceive(NotificationCenter.default.publisher(for: .houstonTerminalClicked)) { _ in
            closeFloatingSheet()
        }
        // A nested shell closing (⇧⌘W, context menu) must not strand the
        // selection on a dead tab — fall back to the project's main
        // terminal. Same fallback when the selected tab still lives but got
        // promoted to the main row (the first tab closed): its `.shell` row
        // no longer exists in the sidebar, `.project` now names it.
        .onChange(of: allTabIDs) { _, ids in
            guard case let .shell(path, tab) = selection else { return }
            if !ids.contains(tab) {
                selection = terminals.hasPane(for: path) ? .project(path) : nil
            } else if terminals.tabs[path]?.first?.id == tab {
                selection = .project(path)
            }
        }
        // Keep the launch selection pointing at something that exists.
        .onChange(of: terminals.installedAgents) { _, installed in
            if !installed.contains(launchAgent), let first = installed.first {
                launchAgent = first
            }
        }
        // The menu-bar Settings menu writes the settings file directly —
        // re-read and apply whatever changed.
        .onReceive(NotificationCenter.default.publisher(for: .houstonSettingsChanged)) { _ in
            let new = HoustonSettings.read()
            if new.terminalTheme != settings.terminalTheme {
                terminals.applyTerminalTheme(named: new.terminalTheme)
            }
            settings = new
            statusFeedInstalled = StatusLineFeed.state == .houston
            store.settingsChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .houstonShowStatusFeedPrompt)) { _ in
            showStatusPrompt = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .houstonShowThemePicker)) { _ in
            setThemePicker(true)
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
        .alert("Notify when Claude needs you?", isPresented: $showNotifyPrompt) {
            Button("Enable") {
                notifyInstalled = NotifyFeed.install()
                NotifyStore.requestAuthorization()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(
                "Houston can tell you the moment a session is waiting — a "
                + "permission request, idle waiting for input, or a finished "
                + "response — with a notification, a menubar dot, and a badge "
                + "on the project's row.\n\nThis adds a Houston entry to the "
                + "hooks in ~/.claude/settings.json. Your own hooks are left "
                + "untouched, and Disable removes exactly Houston's entry. "
                + "Sessions already running pick it up on their next turn."
            )
        }
    }

    /// Draggable split handle — invisible now (no line between sidebar and
    /// detail), but still the 6pt-wide resize grip. One control for both
    /// states: dragging past the minimum collapses to the rail, dragging the
    /// rail's edge back out springs it open — and either way the *same*
    /// gesture keeps resizing, because the crossing rebases the drag origin
    /// instead of ending it.
    private var splitDivider: some View {
        // Invisible until the pointer finds it: the faint stroke while
        // hovered (and held through a drag) is the only hint the grip exists.
        Rectangle()
            .fill(dividerHovered || sidebarDragStart != nil
                ? Theme.borderSidebar
                : Color.clear)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: dividerHovered)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        dividerHovered = inside
                        if inside {
                            (sidebarCollapsed ? NSCursor.resizeRight : NSCursor.resizeLeftRight)
                                .set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        // Global space, not the default `.local`: the divider
                        // itself moves as the width changes, so a local-space
                        // translation feeds back into the value that produced
                        // it — the sidebar oscillated with the pointer held
                        // still. The window's space stays put.
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = sidebarDragStart
                                    ?? (sidebarCollapsed ? railWidth : sidebarWidth)
                                sidebarDragStart = start
                                let proposed = start + value.translation.width
                                if sidebarCollapsed {
                                    // Crossing halfway to the minimum springs
                                    // the sidebar open; rebasing the origin
                                    // lets this drag continue as a plain
                                    // resize from the minimum, no jump.
                                    if proposed > (railWidth + sidebarRange.lowerBound) / 2 {
                                        sidebarWidth = sidebarRange.lowerBound
                                        sidebarDragStart =
                                            sidebarRange.lowerBound - value.translation.width
                                        setSidebarCollapsed(false)
                                    }
                                    return
                                }
                                // Well past the minimum snaps to the rail,
                                // Finder-style — rebased so reversing the
                                // same drag pulls it straight back out.
                                if proposed < sidebarRange.lowerBound - 50 {
                                    sidebarWidth = sidebarRange.lowerBound
                                    sidebarDragStart = railWidth - value.translation.width
                                    setSidebarCollapsed(true)
                                    return
                                }
                                // Whole pixels only — drag translations are
                                // fractional, and text laid out at a subpixel
                                // x-offset renders soft (the "blur" during
                                // resize). And only touch the state when the
                                // rounded value actually moved: every write
                                // re-lays-out the window, terminal included.
                                let clamped = min(
                                    max(proposed, sidebarRange.lowerBound),
                                    sidebarRange.upperBound
                                ).rounded()
                                guard clamped != sidebarWidth else { return }
                                // No implicit animation may ride along: a
                                // tween chasing a live drag is exactly the
                                // jumpy trail-behind look.
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) { sidebarWidth = clamped }
                            }
                            .onEnded { _ in
                                sidebarDragStart = nil
                                updateSettings {
                                    $0.sidebarWidth = Double(sidebarWidth)
                                }
                            }
                    )
            )
    }

    // MARK: - Sidebar column

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // The collapse control rides the titlebar strip, just right of
            // the traffic lights (which end at x≈69).
            HStack {
                FooterIconButton(
                    systemName: "sidebar.left",
                    help: "Collapse sidebar",
                    action: toggleSidebarCollapse
                )
                .padding(.leading, 74)
                Spacer(minLength: 0)
            }
            .frame(height: trafficLightInset)
                // Off the root body — one more root modifier tips the
                // type-checker over its expression limit.
                .onChange(of: store.pinnedProjects) { _, paths in
                    chatIndex.refreshAll(paths)
                }
            sidebarTopCluster
            SidebarTable(
                entries: entries,
                selection: selectionBinding,
                heightForEntry: height(for:),
                content: { entry, hovered in row(for: entry, hovered: hovered) },
                contentKey: contentKey(for:hovered:),
                menuForEntry: menu(for:),
                // Re-clicking the selected row fires no selection change,
                // but still means "put me in that terminal".
                onRowClick: { entry in
                    if let target = entry.selection { select(target) }
                },
                // Sidebar dead space is "outside" too.
                onEmptyClick: { closeFloatingSheet() },
                // Double-clicking a terminal row renames it inline. Deferred
                // past the click cycle: the second click's select() has just
                // focused the terminal, and starting the edit mid-event let
                // that focus land AFTER the field's claim and kill the edit.
                onRowDoubleClick: { entry in
                    guard case let .row(id, _) = entry, renameTarget == nil
                    else { return }
                    let target: RenameTarget? = switch id {
                    case let .project(path):
                        (terminals.tabs[path]?.first?.id)
                            .map { RenameTarget(path: path, tabID: $0) }
                    case let .shell(path, tabID):
                        RenameTarget(path: path, tabID: tabID)
                    case .server:
                        nil
                    }
                    guard let target else { return }
                    DispatchQueue.main.async {
                        renameTerminal(path: target.path, tabID: target.tabID)
                    }
                }
            )
            // NSViewRepresentable has no intrinsic content size, so without
            // this SwiftUI hands it ~zero height and the whole column collapses
            // to fit — the window looked like a small band floating in dead
            // space. `List` was greedy on its own; an NSView is not.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            sidebarFooter
        }
        .background(Theme.sidebarFill)
    }

    // MARK: - Collapsed rail

    /// Rail width — enough for a 34pt icon button centered with breathing
    /// room. The traffic lights (ending at x=69) overhang the divider onto
    /// the detail column's top-left, brushing the sky container's rounded
    /// corner on the empty state — accepted for the thin rail.
    private let railWidth: CGFloat = 52

    /// The collapsed sidebar: three section icons whose popovers carry the
    /// same rows the full sidebar shows, expand at the bottom above the gear.
    private var railColumn: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: trafficLightInset)
            // Expand sits below the traffic lights — the same control that
            // lives beside them when the sidebar is out.
            FooterIconButton(
                systemName: "sidebar.left",
                help: "Expand sidebar",
                action: toggleSidebarCollapse
            )
            // The top cluster, bare icons in the expanded order:
            // gear, tasks, bell.
            settingsMenu()
            FooterLabeledButton(
                systemName: "checklist",
                dot: tracked.attentionCount > 0,
                active: rightPanel == .tasks,
                help: "Tasks and reminders across all projects",
                action: { openAllTasks() }
            )
            FooterLabeledButton(
                systemName: "bell",
                badgeCount: feed.unreadCount,
                active: rightPanel == .feed,
                help: "Notifications",
                action: { toggleRightPanel(.feed) }
            )
            // Same short rule as the expanded footer, centered on the rail.
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
            railButton(.terminals)
            railButton(.servers)
            railButton(.projects)
            Spacer(minLength: 0)
            if let update = updates.available {
                RailButton(
                    help: installer.isBusy
                        ? "Updating Houston…"
                        : "Update available — install Houston \(update.version)",
                    active: false,
                    action: { installer.requestInstall(update) }
                ) {
                    Image(systemName: installer.isBusy
                        ? "arrow.triangle.2.circlepath"
                        : "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.buttonActiveStroke)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarFill)
    }

    private func railButton(_ section: RailSection) -> some View {
        RailButton(
            help: section.title,
            active: railPopover == section,
            action: { setRailPopover(railPopover == section ? nil : section) }
        ) {
            railIcon(section)
        }
    }

    /// Flyout open/close rides one animation so the card slides, not pops.
    private func setRailPopover(_ section: RailSection?) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            railPopover = section
        }
    }

    /// The rail flyout: a second-layer card floating beside the rail,
    /// top-aligned with its button. Replaces `.popover` — NSPopover's
    /// arrow-and-frame chrome read heavy at this size.
    @ViewBuilder
    private var railFlyoutLayer: some View {
        if sidebarCollapsed, let section = railPopover {
            ZStack(alignment: .topLeading) {
                // Scrim: any click outside dismisses (and is consumed). The
                // rail itself stays uncovered so switching sections is one
                // click, not dismiss-then-click.
                HStack(spacing: 0) {
                    Color.clear.frame(width: railWidth)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { setRailPopover(nil) }
                }
                railPopoverContent(section)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .fill(Theme.panelFill)
                            .shadow(color: Theme.floatShadowColor, radius: Theme.floatShadowRadius, x: 0, y: Theme.floatShadowY)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    )
                    .offset(x: railWidth + 6, y: flyoutTop(for: section))
                    .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
    }

    /// The theme picker in the rail flyout's chrome: a second-layer card
    /// beside the sidebar (or rail), bottom-aligned with the footer gear
    /// that opens it. Same scrim, card, and slide as `railFlyoutLayer`.
    @ViewBuilder
    private var themePickerLayer: some View {
        if showThemePicker {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { setThemePicker(false) }
                TerminalThemePicker(
                    current: settings.terminalTheme,
                    recents: settings.recentTerminalThemes,
                    select: { name in
                        terminalThemeBinding.wrappedValue = name
                        if !name.isEmpty {
                            updateSettings { s in
                                var r = s.recentTerminalThemes.filter { $0 != name }
                                r.insert(name, at: 0)
                                s.recentTerminalThemes = Array(r.prefix(10))
                            }
                        }
                        setThemePicker(false)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusFloat))
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .fill(Theme.panelFill)
                        .shadow(color: Theme.floatShadowColor, radius: Theme.floatShadowRadius, x: 0, y: Theme.floatShadowY)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                )
                .onExitCommand { setThemePicker(false) }
                .offset(
                    x: (sidebarCollapsed ? railWidth : sidebarWidth) + 6,
                    y: -12
                )
                .transition(.opacity.combined(with: .offset(x: -8)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Open/close rides the rail flyout's animation so the card slides.
    private func setThemePicker(_ open: Bool) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showThemePicker = open
        }
    }

    /// The gear's "Chat Colors…" card: bubble + text pickers with a live
    /// preview bubble, same placement as the theme picker.
    @ViewBuilder
    private var chatColorsLayer: some View {
        if showChatColors {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showChatColors = false }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Chat Colors")
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.text)
                    ColorPicker("Your bubble", selection: Binding(
                        get: { chatStyle.bubble },
                        set: { chatStyle.setBubble($0) }
                    ), supportsOpacity: false)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    ColorPicker("Your text", selection: Binding(
                        get: { chatStyle.text },
                        set: { chatStyle.setText($0) }
                    ), supportsOpacity: false)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    HStack {
                        Spacer(minLength: 0)
                        Text("Looks like this")
                            .font(.system(size: 13))
                            .foregroundStyle(chatStyle.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(chatStyle.bubble)
                            )
                    }
                    HStack {
                        Button("Reset") { chatStyle.reset() }
                            .buttonStyle(.plain)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.link)
                            .opacity(chatStyle.isDefault ? 0.4 : 1)
                            .disabled(chatStyle.isDefault)
                        Spacer(minLength: 0)
                        Button("Done") { showChatColors = false }
                            .buttonStyle(.plain)
                            .font(Theme.Fonts.bodyMedium)
                            .foregroundStyle(Theme.link)
                    }
                }
                .padding(16)
                .frame(width: 250)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .fill(Theme.panelFill)
                        .shadow(color: Theme.floatShadowColor, radius: Theme.floatShadowRadius, x: 0, y: Theme.floatShadowY)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                )
                .onExitCommand { showChatColors = false }
                .offset(
                    x: (sidebarCollapsed ? railWidth : sidebarWidth) + 6,
                    y: -12
                )
                .transition(.opacity.combined(with: .offset(x: -8)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Right sheet

    /// The sheet's one animation — springy enough to feel alive, damped
    /// enough not to bounce off the edge.
    private var sheetSpring: Animation {
        .spring(response: 0.35, dampingFraction: 0.86)
    }

    private func toggleRightPanel(_ panel: RightPanel) {
        let opening = rightPanel != panel
        // The render fallback: the close animation slides out still showing
        // this panel instead of a blanked strip.
        if opening { lastRightPanel = panel }
        withAnimation(sheetSpring) {
            rightPanel = opening ? panel : nil
        }
        guard opening else { return }
        switch panel {
        case .feed:
            // Opening is seeing: the badge's job ends here.
            feed.markAllRead()
        case .skills:
            if let path = selection?.projectPath {
                skills = SkillsCatalog.load(projectPath: path)
            }
        case .git, .server, .tasks, .capsules:
            break
        }
    }

    private func closeRightPanel() {
        withAnimation(sheetSpring) { rightPanel = nil }
    }

    /// Open the tasks sheet at its All Tasks root (the footer checklist),
    /// or close it if that's already showing.
    private func openAllTasks() {
        if rightPanel == .tasks && taskSheetProject == nil && taskSheetTab == .tasks {
            closeRightPanel()
            return
        }
        taskSheetProject = nil
        taskSheetTab = .tasks
        if rightPanel != .tasks { toggleRightPanel(.tasks) }
    }

    /// Open the tasks sheet pushed into one project's page (the terminal
    /// header's Tasks button), or close it if that page is already showing.
    private func openProjectTasks(_ path: String) {
        if rightPanel == .tasks && taskSheetProject == path {
            closeRightPanel()
            return
        }
        taskSheetProject = path
        taskSheetTab = .tasks
        if rightPanel != .tasks { toggleRightPanel(.tasks) }
    }

    /// The sheet always lives here, flush with the right edge, sliding in
    /// and out by offset — one continuously-mounted view for both modes, so
    /// pin/unpin can't jump. Docking just reserves width in the root HStack.
    ///
    /// Deliberately NO click-away scrim: a floating sheet must not eat the
    /// rest of the window. Clicking another opener (a server row, the Git
    /// button) swaps the sheet's content in place; clicking projects or the
    /// terminal works normally and leaves the sheet up; only dead chrome
    /// (header gaps, the empty-state sky) closes it — those taps are wired
    /// where that chrome lives (`closeFloatingSheet`).
    @ViewBuilder
    private var rightSheetLayer: some View {
        let open = rightPanel != nil
        rightSheet
            .offset(x: open ? 0 : rightSheetWidth + 40)
            .allowsHitTesting(open)
    }

    /// Click on dead chrome: dismiss a floating sheet, never a docked one.
    private func closeFloatingSheet() {
        guard rightPanel != nil, !rightPanelDocked else { return }
        closeRightPanel()
    }

    /// The sheet itself: a full-height strip off the right edge — a controls
    /// bar (title, dock toggle, close) over the active panel's card. Same
    /// view in both modes; only who owns its geometry changes.
    private var rightSheet: some View {
        VStack(spacing: 0) {
            // The server panel embeds pin/close in its own header (per the
            // Figma design), so the shared controls bar stands down there.
            if !serverChromeHidden {
                HStack(spacing: 4) {
                    rightSheetTitleView
                    Spacer(minLength: 8)
                    ControlIconButton(
                        systemName: rightPanelDocked
                            ? "pin.slash" : "pin",
                        help: rightPanelDocked
                            ? "Float over the content"
                            : "Dock beside the content",
                        bare: true,
                        circleSize: 32,
                        action: {
                            withAnimation(sheetSpring) {
                                rightPanelDocked.toggle()
                            }
                        }
                    )
                    ControlIconButton(
                        systemName: "xmark",
                        help: "Close",
                        circleSize: 32,
                        action: closeRightPanel
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            rightSheetContent
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, 12)
                // Docked, the right edge gets breathing room to mirror the
                // left-side gap against the terminal; floating keeps the
                // tight edge.
                .padding(.trailing, rightPanelDocked ? 24 : 12)
                .padding(.top, serverChromeHidden ? 14 : 0)
                .padding(.bottom, 12)
        }
        .frame(width: rightSheetWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) {
            // Floating only — pinned, the sheet is part of the page and a
            // border would read as a seam. Opacity (not removal) so the pin
            // toggle fades it with the same spring.
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(width: 1)
                .opacity(rightPanelDocked ? 0 : 1)
        }
        .overlay(alignment: .leading) { rightSheetGrip }
    }

    /// The sheet's resize grip, mirroring the sidebar divider: invisible
    /// until hovered, dragging left widens. Same global-space rationale —
    /// the edge moves with the width it controls.
    private var rightSheetGrip: some View {
        Rectangle()
            .fill(rightSheetDividerHovered || rightSheetDragStart != nil
                ? Theme.borderSidebar : Color.clear)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: rightSheetDividerHovered)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        rightSheetDividerHovered = inside
                        if inside {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let start = rightSheetDragStart ?? rightSheetWidth
                                rightSheetDragStart = start
                                // Leading edge: dragging left grows the sheet.
                                let proposed = start - value.translation.width
                                let clamped = min(
                                    max(proposed, rightSheetRange.lowerBound),
                                    rightSheetRange.upperBound
                                ).rounded()
                                guard clamped != rightSheetWidth else { return }
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    rightSheetWidth = clamped
                                }
                            }
                            .onEnded { _ in
                                rightSheetDragStart = nil
                                updateSettings {
                                    $0.rightSheetWidth = Double(rightSheetWidth)
                                }
                            }
                    )
            )
    }

    /// What the sheet renders: the open panel, or the last one while the
    /// close animation runs.
    private var effectiveRightPanel: RightPanel? { rightPanel ?? lastRightPanel }

    /// The running server a sheet id addresses — directly, through the
    /// recent entry's project path, or through the store's revived-id map
    /// once the server restarts (the restart deletes the recent, so a sheet
    /// opened under an off id or the old pid:port would otherwise resolve
    /// to nothing and fall to the "no longer listening" placeholder).
    private func liveServer(for sid: String) -> DevServer? {
        if let live = servers.devServers.first(where: { $0.id == sid }) { return live }
        let path = servers.recent(matching: sid)?.projectPath
            ?? servers.revivedPath(matching: sid)
        guard let path else { return nil }
        return servers.devServers.first { $0.cwd == path }
    }

    private var serverChromeHidden: Bool {
        if case .server = effectiveRightPanel { return true }
        return false
    }

    private var rightSheetTitle: String {
        switch effectiveRightPanel {
        case .git: "GIT"
        case .skills: "SKILLS"
        case .feed: "NOTIFICATIONS"
        case .server: "SERVER"
        case .tasks: "ALL TASKS"
        case .capsules: "CAPSULES"
        case nil: ""
        }
    }

    /// The title bar doubles as the tasks sheet's nav: the caps title at
    /// the All Tasks root, breadcrumbs once a project's list or the
    /// Reminders page is pushed. Other panels keep the quiet caps title.
    @ViewBuilder
    private var rightSheetTitleView: some View {
        if effectiveRightPanel == .tasks {
            if taskSheetTab == .reminders {
                taskBreadcrumbs(current: "Reminders") {
                    taskSheetTab = .tasks
                    taskSheetProject = nil
                }
            } else if let path = taskSheetProject {
                taskBreadcrumbs(current: (path as NSString).lastPathComponent) {
                    taskSheetProject = nil
                }
            } else {
                capsSheetTitle(rightSheetTitle)
            }
        } else {
            capsSheetTitle(rightSheetTitle)
        }
    }

    private func capsSheetTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.meta)
            .kerning(0.5)
            .foregroundStyle(Theme.heading)
    }

    /// "All Tasks › current" — the root is the button, the current page is
    /// plain text a size up.
    private func taskBreadcrumbs(
        current: String, onRoot: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: onRoot) {
                Text("All Tasks")
                    .font(Theme.Fonts.secondaryMedium)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusControl)
                            .fill(crumbHovered ? Theme.rowHovered : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
            }
            .buttonStyle(.plain)
            .onHover { crumbHovered = $0 }
            .help("Back to All Tasks")
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.heading)
            Text(current)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var rightSheetContent: some View {
        switch effectiveRightPanel {
        case .git:
            if let path = selection?.projectPath {
                gitPanel(for: path)
            } else {
                rightSheetPlaceholder("Select a project to see its git state.")
            }
        case .skills:
            if let path = selection?.projectPath, terminals.agents[path] != nil {
                SkillsPanel(
                    skills: skills,
                    onRun: { skill in
                        terminals.send("/\(skill.name)\n", to: path)
                        if !rightPanelDocked { closeRightPanel() }
                    },
                    onInsert: { skill in
                        terminals.send("/\(skill.name) ", to: path)
                        if !rightPanelDocked { closeRightPanel() }
                    }
                )
            } else {
                rightSheetPlaceholder(
                    "Skills apply to a running agent session — select a "
                    + "project with one."
                )
            }
        case .tasks:
            switch taskSheetTab {
            case .tasks:
                TasksNavigator(
                    projectPath: taskSheetProject,
                    trackedAttention: tracked.attentionCount,
                    onOpenProject: { taskSheetProject = $0 },
                    onOpenReminders: { taskSheetTab = .reminders }
                )
            case .reminders:
                TrackedPanel(store: tracked)
            }
        case let .server(sid):
            // Resolve by live id first, then through the recent entry the id
            // maps to — so the sheet morphs live↔off in place as the server
            // stops or comes back, whichever id it was opened under.
            if let server = liveServer(for: sid) {
                ServerPanel(
                    server: server,
                    share: share,
                    relay: relay,
                    health: servers.health[server.id],
                    onOpenTerminal: {
                        guard let cwd = server.cwd else { return }
                        select(.project(cwd))
                        if !rightPanelDocked { closeRightPanel() }
                    },
                    docked: rightPanelDocked,
                    onTogglePin: {
                        withAnimation(sheetSpring) { rightPanelDocked.toggle() }
                    },
                    onClose: closeRightPanel
                )
            } else if let recent = servers.recent(matching: sid) {
                OffServerPanel(
                    recent: recent,
                    busyPorts: Dictionary(
                        servers.devServers.map { ($0.port, $0.project ?? $0.command) },
                        uniquingKeysWith: { a, _ in a }
                    ),
                    docked: rightPanelDocked,
                    onTogglePin: {
                        withAnimation(sheetSpring) { rightPanelDocked.toggle() }
                    },
                    onClose: closeRightPanel,
                    onStart: { command in
                        terminals.pane(for: recent.projectPath)
                        select(.project(recent.projectPath))
                        terminals.send(command + "\n", to: recent.projectPath)
                    }
                )
            } else {
                rightSheetPlaceholder("This server is no longer listening.")
            }
        case let .capsules(path, focus):
            CapsulePanel(
                projectPath: path,
                focus: focus,
                onAttach: { capsule in
                    attachCapsuleToNewChat(project: path, capsule: capsule)
                },
                onOpenChat: { file in
                    chatTarget = ChatTarget(path: path, sessionFile: file)
                    chatIndex.refresh(path, force: true)
                    if !rightPanelDocked { closeRightPanel() }
                },
                onInsert: { text in
                    insertIntoComposer(project: path, text: text)
                }
            )
        case .feed:
            FeedSheet(feed: feed) { event in
                if let path = event.projectPath {
                    select(.project(path))
                }
                if !rightPanelDocked { closeRightPanel() }
            }
        case nil:
            EmptyView()
        }
    }

    /// A capsule-view section insert: make sure a chat surface for the
    /// project is up (a new chat if none is), then hand the composer the
    /// text — after a beat, so a freshly mounted composer is listening.
    private func insertIntoComposer(project: String, text: String) {
        if chatTarget?.path != project {
            chatTarget = ChatTarget(path: project, sessionFile: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(
                name: .houstonComposerInsert, object: text
            )
        }
    }

    /// Clicking a capsule: a fresh chat with the capsule staged as a chip
    /// in the composer. Always a new chat — that's the whole model: fresh
    /// context, the capsule carrying the history.
    private func attachCapsuleToNewChat(project: String, capsule: ChatCapsule) {
        if let draft = ChatSessionHub.shared.drafts[project], !draft.running {
            ChatSessionHub.shared.discardDraft(in: project)
        }
        chatTarget = ChatTarget(path: project, sessionFile: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(
                name: .houstonComposerAttachCapsule, object: capsule
            )
        }
        if !rightPanelDocked { closeRightPanel() }
    }

    private func gitPanel(for path: String) -> some View {
        GitPanel(
            info: git.info,
            projectPath: path,
            onInitialize: {
                terminals.send("git init\n", to: path)
                git.refresh()
            },
            onSwitchBranch: { branch in
                terminals.send("git switch \"\(branch)\"\n", to: path)
                git.refresh()
            },
            onNewBranch: {
                guard let name = promptForText(
                    title: "New Branch",
                    message: "Created from the current branch and switched to.",
                    placeholder: "feature/thing"
                ), !name.isEmpty else { return }
                terminals.send("git switch -c \"\(name)\"\n", to: path)
                git.refresh()
            },
            onCommand: { command, execute in
                if execute {
                    terminals.send(command + "\n", to: path)
                    git.refresh()
                } else {
                    // Destructive: type it and get out of the way — the
                    // user's Return in the terminal is the confirm.
                    terminals.send(command, to: path)
                    if !rightPanelDocked { closeRightPanel() }
                }
            },
            prompt: { promptForText(
                title: $0, message: $1, placeholder: $2
            ) }
        )
    }

    private func rightSheetPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Aligns the flyout's top edge with the rail button that opened it —
    /// the buttons stack at `trafficLightInset` in 30pt + 6pt-spacing
    /// steps, below the expand + cluster icons (4 rows) and the rule.
    private func flyoutTop(for section: RailSection) -> CGFloat {
        let index: CGFloat = switch section {
        case .terminals: 0
        case .servers: 1
        case .projects: 2
        }
        let clusterHeight: CGFloat = 4 * 36 + 11 // icons + the short rule
        return trafficLightInset + clusterHeight + index * 36
    }

    @ViewBuilder
    private func railIcon(_ section: RailSection) -> some View {
        switch section {
        case .terminals:
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        case .servers:
            ServerGlyph(color: Theme.textSecondary, size: 15)
        case .projects:
            Image(systemName: "shippingbox")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        railPopover = nil
        withAnimation(.easeOut(duration: 0.15)) { sidebarCollapsed = collapsed }
        updateSettings { $0.sidebarCollapsed = collapsed }
    }

    private func toggleSidebarCollapse() {
        setSidebarCollapsed(!sidebarCollapsed)
    }

    /// Select from a rail popover: dismiss first, then route through the
    /// same `select(_:)` every other selection path uses.
    private func railSelect(_ target: SidebarSelection) {
        setRailPopover(nil)
        select(target)
    }

    @ViewBuilder
    private func railPopoverContent(_ section: RailSection) -> some View {
        switch section {
        case .terminals: terminalsPopover
        case .servers: serversPopover
        case .projects: projectsPopover
        }
    }

    /// Chrome shared by the rail popovers: a header with the section title
    /// and a count badge (no glyph — the rail button that opened it already
    /// is one), the rows (capped at 400pt, scrolling past that), and an
    /// optional pinned action footer.
    private func railPopoverPanel(
        title: String,
        count: Int,
        rowsHeight: CGFloat,
        width: CGFloat = 260,
        @ViewBuilder rows: () -> some View,
        @ViewBuilder footer: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Same quiet treatment as the expanded sidebar's section
                // headers — the popover is the same section, restyled.
                Text(title.uppercased())
                    .font(Theme.Fonts.meta)
                    .kerning(0.5)
                    .foregroundStyle(Theme.heading)
                Spacer(minLength: 8)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.rowSelected))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) { rows() }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(rowsHeight, 400))
            footer()
        }
        .frame(width: width)
        .padding(.bottom, 8)
    }

    /// A pinned popover footer: hairline, then an action row.
    private func railPopoverFooter(
        _ title: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            PopoverRow(height: 30, action: action) { hovered in
                actionRowLabel(title: title, hovered: hovered)
            }
        }
    }

    /// A friendly empty state for a rail popover. Sized to
    /// `railEmptyStateHeight` — keep the two in step.
    private func railEmptyState(
        _ headline: String, _ subtext: String? = nil,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        VStack(spacing: 8) {
            icon()
            Text(headline)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.text)
            if let subtext {
                Text(subtext)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .frame(height: railEmptyStateHeight)
    }

    private var railEmptyStateHeight: CGFloat { 112 }

    /// The Terminals section as a popover — same rows, plus "New Terminal".
    private var terminalsPopover: some View {
        let tabCount = terminals.tabs.values.map(\.count).reduce(0, +)
        return railPopoverPanel(
            title: "Terminals",
            count: tabCount,
            rowsHeight: tabCount == 0 ? railEmptyStateHeight : CGFloat(tabCount) * 32
        ) {
            if terminalPaths.isEmpty {
                railEmptyState("No terminals open") {
                    Image(systemName: "terminal")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.heading)
                }
            }
            ForEach(terminalPaths, id: \.self) { path in
                let list = terminals.tabs[path] ?? []
                PopoverRow(height: 32, action: { railSelect(.project(path)) }) { hovered in
                    SidebarRow(
                        name: list.first?.customName ?? name(of: path),
                        agent: primaryAgent(path: path),
                        hasTerminal: true,
                        gitStatus: git.rowStatuses[path] ?? .none,
                        hovered: hovered,
                        selected: selection == .project(path),
                        onClose: { closeTerminal(path) }
                    )
                }
                ForEach(list.dropFirst()) { tab in
                    PopoverRow(
                        height: 32,
                        action: { railSelect(.shell(path: path, tab: tab.id)) }
                    ) { hovered in
                        SidebarRow(
                            name: tab.customName ?? name(of: path),
                            agent: shellAgent(path: path, tab: tab.id),
                            hasTerminal: true,
                            gitStatus: git.rowStatuses[path] ?? .none,
                            hovered: hovered,
                            selected: selection == .shell(path: path, tab: tab.id),
                            onClose: { terminals.closeTab(path: path, tabID: tab.id) }
                        )
                    }
                }
            }
        } footer: {
            // Deliberately leaves the flyout open — the new row appearing in
            // place is the action's feedback.
            railPopoverFooter("New") {
                runAction("new-terminal")
            }
        }
    }

    /// The Servers section as a popover. Clicking a row jumps to the
    /// server's project terminal (its popover detail doesn't fit inside
    /// another popover); the hover arrow still opens the browser.
    private var serversPopover: some View {
        let list = servers.devServers
        return railPopoverPanel(
            title: "Servers",
            count: list.count,
            rowsHeight: list.isEmpty ? railEmptyStateHeight : CGFloat(list.count) * 42
        ) {
            if list.isEmpty {
                railEmptyState(
                    "No dev servers running",
                    "Start one — npm run dev, vite — and it appears here with a health light."
                ) {
                    ServerGlyph(color: Theme.heading, size: 22)
                }
            } else {
                ForEach(list) { server in
                    PopoverRow(height: 42, action: {
                        setRailPopover(nil)
                        if let cwd = server.cwd {
                            select(.project(cwd))
                        } else {
                            Actions.openExternal(server.url)
                        }
                    }) { hovered in
                        ServerRow(
                            server: server,
                            health: servers.health[server.id],
                            hovered: hovered,
                            selected: false
                        )
                    }
                }
            }
        } footer: {
            EmptyView()
        }
    }

    /// The Projects library as a popover: pinned rows, folders (always
    /// expanded — collapse state stays a full-sidebar concern), and "Add".
    /// Mirrors the expanded sidebar's chat-centric Projects section: each
    /// project row opens a new chat, with its recent chats nested beneath.
    private var projectsPopover: some View {
        let pinned = store.pinnedProjects
        let empty = pinned.isEmpty
        let chatCount = pinned.reduce(0) {
            $0 + min(chatIndex.chats[$1]?.count ?? 0, 3)
        }
        let rowsHeight = empty
            ? railEmptyStateHeight
            : CGFloat(pinned.count) * 28 + CGFloat(chatCount) * 26
        return railPopoverPanel(
            title: "Projects",
            count: pinned.count,
            rowsHeight: rowsHeight
        ) {
            if empty {
                railEmptyState(
                    "No projects yet",
                    "Add a repo or a folder of projects to build your library."
                ) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.heading)
                }
            }
            ForEach(pinned, id: \.self) { path in
                projectPopoverRow(path)
                ForEach(
                    Array((chatIndex.chats[path] ?? []).prefix(3)),
                    id: \.filePath
                ) { ref in
                    chatPopoverRow(project: path, ref: ref)
                }
            }
        } footer: {
            railPopoverFooter("Add Project…") {
                setRailPopover(nil)
                addFolder()
            }
        }
    }

    /// Clicking a project starts a chat there — same as the expanded
    /// header's "+"; the terminal lives one hover-icon away.
    private func projectPopoverRow(_ path: String) -> some View {
        PopoverRow(height: 28, action: {
            setRailPopover(nil)
            newChat(in: path)
        }) { hovered in
            HStack(spacing: 0) {
                SidebarRow(
                    name: name(of: path),
                    diff: libraryDiff(path),
                    isProject: ProjectKindCache.isProject(path),
                    live: terminals.hasPane(for: path),
                    hovered: hovered
                )
                if hovered {
                    RowActionIcon(symbol: "terminal", help: "New terminal") {
                        setRailPopover(nil)
                        newTerminal(in: path)
                    }
                    .padding(.trailing, 8)
                }
            }
        }
    }

    private func chatPopoverRow(project: String, ref: ChatSessionRef) -> some View {
        PopoverRow(height: 26, action: {
            setRailPopover(nil)
            openChat(project: project, file: ref.filePath)
        }) { _ in
            Text(chatTitler.displayTitle(ref))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text.opacity(0.8))
                .lineLimit(1)
                .padding(.leading, 24 + Theme.rowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Opens the directory picker and registers the choice. A folder that is
    /// itself a project (has `.git`, `package.json`, an `.xcodeproj`, …) is
    /// pinned as a single row; anything else becomes a parent group whose
    /// subdirectories are listed. One button, both intents — and a project
    /// can never be exploded into its `src`/`node_modules` innards.
    private func addFolder() {
        // Any picked directory is a project — one row, never expanded.
        // Folders-of-projects get added one project at a time.
        guard let picked = Actions.pickDirectory(
            title: "Add a project",
            defaultPath: store.pinnedProjects.first
                .map { ($0 as NSString).deletingLastPathComponent }
        ) else { return }
        updateSettings {
            if !$0.pinnedProjects.contains(picked) {
                $0.pinnedProjects.append(picked)
            }
        }
        store.settingsChanged()
    }

    /// Begins renaming a terminal row inline in the sidebar — the row's
    /// name becomes an editable field prefilled with the current name.
    private func renameTerminal(path: String, tabID: UUID) {
        renameTarget = RenameTarget(path: path, tabID: tabID)
    }

    /// The row's field finished: commit (result) or cancel (nil), then hand
    /// the keyboard back to the selected terminal — the field stole it.
    private func finishInlineRename(path: String, tabID: UUID, result: String?) {
        guard renameTarget == RenameTarget(path: path, tabID: tabID) else { return }
        renameTarget = nil
        if let result {
            terminals.renameTab(
                path: path,
                tabID: tabID,
                to: result.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if let selPath = selection?.projectPath {
            terminals.focusTerminal(path: selPath, tab: selection?.tabID)
        }
    }

    /// The name a row's rename field starts from: custom name if set, else
    /// the default it displays.
    private func currentRowName(path: String, tabID: UUID) -> String {
        let custom = terminals.tabs[path]?
            .first { $0.id == tabID }?.customName ?? ""
        return custom.isEmpty ? name(of: path) : custom
    }

    /// The topmost overlay tier: the first-launch onboarding takeover.
    private var modalLayer: some View {
        onboardingLayer
    }

    @ViewBuilder
    private var onboardingLayer: some View {
        if showOnboarding {
            OnboardingView {
                withAnimation(.easeOut(duration: 0.25)) { showOnboarding = false }
                updateSettings { $0.onboardingSeen = true }
                // Once the overlay has faded onto the aligned empty-state
                // system, slide the sidebar in around it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.spring(duration: 0.6, bounce: 0.12)) {
                        sidebarRevealed = true
                    }
                }
            }
            .transition(.opacity)
        }
    }


    /// Clones a repo into the projects folder — visibly, in the home shell,
    /// so credential prompts and progress land where the user can see them —
    /// then pins the result when the clone finishes.
    private func cloneRepository() {
        guard let url = promptForText(
            title: "Clone Repository",
            message: "HTTPS or SSH URL. Houston clones it into "
                + "\(cloneParent) and adds it to Projects.",
            placeholder: "git@github.com:user/repo.git"
        ), !url.isEmpty else { return }
        let name = Self.repoName(from: url)
        guard !name.isEmpty else { return }
        let parent = cloneParent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        let dest = parent + "/" + name
        select(.project(NSHomeDirectory()))
        terminals.send("git clone \"\(url)\" \"\(dest)\"\n", to: NSHomeDirectory())
        Task {
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                if FileManager.default.fileExists(atPath: dest + "/.git") {
                    pinProject(dest)
                    return
                }
            }
        }
    }

    /// Where clones land: the first configured folder, else ~/Apps.
    private var cloneParent: String {
        store.projectsDirs.first ?? "~/Apps".expandingTildePath
    }

    /// "git@github.com:user/repo.git" / "https://…/repo.git" → "repo".
    private static func repoName(from url: String) -> String {
        var tail = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while tail.hasSuffix("/") { tail.removeLast() }
        let afterColon = tail.split(separator: ":").last.map(String.init) ?? tail
        let last = afterColon.split(separator: "/").last.map(String.init) ?? afterColon
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// Pin a single project into the Projects section.
    private func pinProject(_ path: String) {
        updateSettings {
            if !$0.pinnedProjects.contains(path) { $0.pinnedProjects.append(path) }
        }
        store.settingsChanged()
    }

    /// One-line modal text prompt (branch names, clone URLs).
    private func promptForText(
        title: String, message: String, placeholder: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sidebar action rows ("New", "Add").
    private func runAction(_ key: String) {
        switch key {
        case "new-terminal":
            // Every click opens another shell: the first becomes the home
            // terminal, the rest nest under it as "~ · N" tabs.
            let home = NSHomeDirectory()
            if terminals.hasPane(for: home), let tab = terminals.newTab(in: home) {
                select(.shell(path: home, tab: tab.id))
            } else {
                select(.project(home))
            }
        case "open-folder": addFolder()
        default:
            if key.hasPrefix("archived:") {
                let path = String(key.dropFirst("archived:".count))
                if archivedShown.contains(path) {
                    archivedShown.remove(path)
                } else {
                    archivedShown.insert(path)
                }
            } else if key.hasPrefix("capsules-more:") {
                let path = String(key.dropFirst("capsules-more:".count))
                capsuleRowsShown[path] = (capsuleRowsShown[path] ?? 5) + 5
            } else if key.hasPrefix("capsules:") {
                let path = String(key.dropFirst("capsules:".count))
                toggleRightPanel(.capsules(project: path, focus: nil))
            }
        }
    }

    /// Shared chrome for the "+ New" / "+ Add" rows.
    private func actionRowLabel(
        title: String, hovered: Bool, icon: String = "plus"
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .modifier(RowChrome(hovered: hovered, selected: false))
        .contentShape(Rectangle())
    }


    /// Tasks, Notifications, Settings, and Servers — labeled rows at the
    /// TOP of the sidebar (2026-09-11 design), above the sections.
    /// Reminders lives inside the Tasks sheet (its second tab), so the
    /// Tasks row carries the tracked attention dot.
    private var sidebarTopCluster: some View {
        VStack(alignment: .leading, spacing: 2) {
            FooterLabeledButton(
                systemName: "checklist",
                label: "Tasks",
                dot: tracked.attentionCount > 0,
                active: rightPanel == .tasks,
                help: "Tasks and reminders across all projects",
                action: { openAllTasks() }
            )
            FooterLabeledButton(
                systemName: "bell",
                label: "Notifications",
                badgeCount: feed.unreadCount,
                active: rightPanel == .feed,
                help: "Notifications",
                action: { toggleRightPanel(.feed) }
            )
            settingsMenu(labeled: true)
            FooterLabeledButton(
                systemName: "server.rack",
                label: "Servers",
                active: serversFlyout,
                iconTint: servers.devServers.isEmpty ? nil : Theme.dotActive,
                count: servers.devServers.count,
                help: "Dev servers",
                action: { setServersFlyout(!serversFlyout) }
            )
        }
        // The parent VStack centers fitting-width children — pin the
        // cluster to the left edge like every other sidebar row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        // One section gap's worth before the table — the same 20pt a
        // header box puts between the table's own sections.
        .padding(.bottom, 20)
    }

    /// Flyout open/close rides the rail flyouts' spring so the card
    /// slides, not pops.
    private func setServersFlyout(_ shown: Bool) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            serversFlyout = shown
        }
    }

    /// Stopped servers in a second-layer card beside the Servers item —
    /// the same scrim, chrome, and slide as the collapsed rail's flyouts.
    @ViewBuilder
    private var serversFlyoutLayer: some View {
        if serversFlyout, !sidebarCollapsed {
            ZStack(alignment: .topLeading) {
                // Scrim: any click outside dismisses (and is consumed).
                // The sidebar stays uncovered so its rows keep one-click.
                HStack(spacing: 0) {
                    Color.clear.frame(width: sidebarWidth)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { setServersFlyout(false) }
                }
                stoppedServersCard
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .fill(Theme.panelFill)
                            .shadow(
                                color: Theme.floatShadowColor,
                                radius: Theme.floatShadowRadius,
                                x: 0, y: Theme.floatShadowY
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    )
                    // Top-aligned with the Servers item: the traffic-light
                    // inset plus the three 26pt rows (2pt spacing) above it.
                    .offset(x: sidebarWidth + 6, y: trafficLightInset + 3 * 28)
                    .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
    }

    private var stoppedServersCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !servers.devServers.isEmpty {
                flyoutSectionLabel("RUNNING")
                ForEach(servers.devServers, id: \.id) { server in
                    FlyoutServerRow(
                        row: { ServerRow(
                            server: server,
                            health: servers.health[server.id],
                            hovered: $0
                        ) },
                        height: 38,
                        onTap: {
                            setServersFlyout(false)
                            toggleRightPanel(.server(server.id))
                        }
                    ) {
                        Button("Open in Browser") {
                            Actions.openExternal(server.url)
                        }
                        if let cwd = server.cwd {
                            Button("Open Terminal Here") {
                                _ = terminals.pane(for: cwd)
                                selection = .project(cwd)
                            }
                            Button("Reveal in Finder") {
                                Actions.revealInFinder(path: cwd)
                            }
                        }
                        Divider()
                        Button("Stop Server") { Actions.killPid(server.pid) }
                    }
                }
                .padding(.horizontal, 6)
            }
            flyoutSectionLabel("STOPPED")
            if servers.recents.isEmpty {
                Text("No stopped servers")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ForEach(servers.recents, id: \.id) { recent in
                    FlyoutServerRow(
                        row: { ServerRow(recent: recent, hovered: $0) },
                        height: 28,
                        onTap: {
                            setServersFlyout(false)
                            toggleRightPanel(.server(recent.id))
                        }
                    ) {
                        Button("Open Terminal Here") {
                            _ = terminals.pane(for: recent.projectPath)
                            selection = .project(recent.projectPath)
                        }
                        Button("Reveal in Finder") {
                            Actions.revealInFinder(path: recent.projectPath)
                        }
                        Divider()
                        // Temporary by design: the row returns the next
                        // time a server runs (and stops) in this project.
                        Button("Remove") {
                            if rightPanel == .server(recent.id) {
                                closeRightPanel()
                            }
                            servers.removeRecent(recent.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                Color.clear.frame(height: 6)
            }
        }
        .frame(width: 240)
    }

    private func flyoutSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.label)
            .kerning(0.5)
            .foregroundStyle(Theme.heading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    /// All that's left at the bottom: the update pill, when there is one.
    @ViewBuilder
    private var sidebarFooter: some View {
        if let update = updates.available {
            HStack {
                UpdatePill(version: update.version, busy: installer.isBusy) {
                    installer.requestInstall(update)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Settings

    /// Footer gear: appearance (System/Light/Dark) and the terminal's theme,
    /// straight from ghostty's catalog. A bare glyph on the rail; an
    /// icon+label row in the expanded footer's stack.
    private func settingsMenu(labeled: Bool = false) -> some View {
        Menu {
            Picker("Appearance", selection: appearanceBinding) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.inline)

            // The catalog is ~485 themes — a submenu ran past the screen and
            // couldn't be searched. A Button here dismisses the menu, then
            // the popover below opens on the gear.
            Button("Terminal Theme…") {
                setThemePicker(true)
            }

            Button("Chat Colors…") {
                showChatColors = true
            }

            Divider()

            Section("Status Bar") {
                Toggle("Hide", isOn: statusBarCollapsedBinding)
                Toggle("Disable", isOn: statusBarDisabledBinding)
                Menu("Items") {
                    Toggle("Model", isOn: statusBarItemBinding("model"))
                    Toggle("Context", isOn: statusBarItemBinding("context"))
                    Toggle("Cost", isOn: statusBarItemBinding("cost"))
                    Toggle("MCP", isOn: statusBarItemBinding("mcp"))
                    Toggle("Peak Hours", isOn: statusBarItemBinding("peak"))
                    Toggle("Rate Limits", isOn: statusBarItemBinding("limits"))
                }
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

            if notifyInstalled {
                Button("Disable Needs-You Notifications") {
                    NotifyFeed.restore()
                    notifyInstalled = false
                }
            } else {
                Button("Notify When Claude Needs You…") {
                    showNotifyPrompt = true
                }
            }

            Divider()

            Button("Show Onboarding") {
                withAnimation(.easeOut(duration: 0.3)) {
                    showOnboarding = true
                    sidebarRevealed = false
                }
            }
            Button("Check for Updates…") {
                UpdateChecker.shared.checkInteractively()
            }
        } label: {
            GearLabel(labeled: labeled)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance and terminal theme")
    }

    private var statusBarDisabledBinding: Binding<Bool> {
        Binding(
            get: { settings.statusBarDisabled },
            set: { disabled in updateSettings { $0.statusBarDisabled = disabled } }
        )
    }

    private var statusBarCollapsedBinding: Binding<Bool> {
        Binding(
            get: { settings.statusBarCollapsed },
            set: { collapsed in updateSettings { $0.statusBarCollapsed = collapsed } }
        )
    }

    /// On/off for one status-bar item — stored inverted (hidden list), so an
    /// absent key means visible.
    private func statusBarItemBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !settings.statusBarHiddenItems.contains(key) },
            set: { visible in
                updateSettings {
                    $0.statusBarHiddenItems.removeAll { $0 == key }
                    if !visible { $0.statusBarHiddenItems.append(key) }
                }
            }
        )
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
            // The empty state stands alone — no title bar over it. Chat
            // mode drops the terminal chrome too: the action bar and
            // status bar are the terminal's, not the chat's.
            if selection != nil, chatTarget == nil {
                topPanel
                    // Gaps between the header's controls are dead chrome —
                    // clicking them dismisses a floating sheet. The buttons
                    // themselves win their own clicks first.
                    .contentShape(Rectangle())
                    .onTapGesture { closeFloatingSheet() }
            }
            detailContent
            // The bar keeps its place under every open pane; its components
            // only appear while a session runs.
            if chatTarget == nil,
               let path = selection?.projectPath, terminals.hasPane(for: path),
               !settings.statusBarDisabled {
                let snapshot = activeSnapshot
                StatusBarView(
                    snapshot: snapshot,
                    collapsed: statusBarCollapsedBinding,
                    mcp: mcp.statuses[path],
                    mcpAuthInFlight: mcp.authInFlight,
                    onSelectModel: { modelArg in
                        // Claude sessions target the exact pane the feed
                        // payload came from; other harnesses get the command
                        // typed into the project's focused pane.
                        if let snapshot {
                            switchModel(to: modelArg, snapshot: snapshot)
                        } else {
                            terminals.send("/model \(modelArg)\n", to: path)
                        }
                    },
                    onSelectEffort: { level in
                        if let snapshot {
                            sendToSnapshotPane("/effort \(level)\n", snapshot: snapshot)
                        } else {
                            terminals.send("/effort \(level)\n", to: path)
                        }
                    },
                    onManageMCP: {
                        if let snapshot { sendToSnapshotPane("/mcp\n", snapshot: snapshot) }
                    },
                    onRefreshMCP: { mcp.refresh(path: path) },
                    onAuthenticateMCP: { mcp.login(server: $0, path: path) },
                    onLogoutMCP: { mcp.logout(server: $0, path: path) },
                    hiddenItems: Set(settings.statusBarHiddenItems),
                    sessionRunning: terminals.agents[path] != nil,
                    agent: terminals.agents[path]
                )
                .onAppear { mcp.refreshIfStale(path: path) }
            }
        }
        // The chrome band around the content card shares the sidebar's
        // lighter surface — one continuous frame, no hairlines.
        .background(Theme.sidebarFill)
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
                        .font(Theme.Fonts.secondary)
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
        // Mission controls lead the cluster: Start Mission until a session
        // exists (and only where a mission log does), then the Mission menu.
        if terminals.agents[path] == nil {
            if FileManager.default.fileExists(atPath: path + "/missionlog.md") {
                Button {
                    terminals.send("claude \"/start-mission\"\n", to: path)
                } label: {
                    HStack(spacing: 5) {
                        SVGIcon(name: "rocket", size: 13)
                            .foregroundStyle(Theme.text.opacity(0.75))
                        Text("Start Mission")
                            .font(Theme.Fonts.bodyMedium)
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HeaderButtonChrome())
                .help("Launch claude and resume where the last session left off")
            }
        } else {
            let handingOff = handoffs.active.contains(path)
            HeaderMenuButton {
                // One-click context reset: /log-mission, wait for the log
                // write, /clear, /handoff — see HandoffCoordinator.
                let menu = NSMenu()
                menu.autoenablesItems = false
                let handoff = ClosureMenuItem("Handoff") {
                    handoffs.handoff(path: path)
                }
                handoff.isEnabled = !handingOff
                menu.addItem(handoff)
                menu.addItem(ClosureMenuItem("End Mission") {
                    terminals.send("/end-mission\n", to: path)
                })
                return menu
            } label: {
                HStack(spacing: 6) {
                    Text(handingOff ? "Handing off…" : "Mission")
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .help("Handoff (log, reset context, re-brief) or end the mission")
        }

        // Branch button: live git state at a glance, sheet on click.
        Button {
            toggleRightPanel(.git)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text.opacity(0.75))
                Text(gitButtonTitle)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let info = git.info, info.isRepo, !info.changes.isEmpty {
                    Circle()
                        .fill(Theme.dotDegraded)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome(active: rightPanel == .git))
        .help("Git status")

        // The chat archive: this project's terminal sessions (Claude and
        // Codex) rendered as clean chats, swapping the terminal surface.
        Button {
            chatTarget = chatTarget?.path == path
                ? nil : ChatTarget(path: path, sessionFile: nil)
        } label: {
            Text("Chats")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome(active: chatTarget?.path == path))
        .help("New chat (past chats live in the sidebar)")

        // The project's tasks — the queue built from the web preview's
        // "Add to Tasks", plus manual entries. Opens
        // nested under All Tasks, so Back in the sheet goes up.
        NotesHeaderButton(
            store: AnnotationStores.store(for: path),
            active: rightPanel == .tasks && taskSheetProject == path,
            action: { openProjectTasks(path) }
        )

        // Skills only exist inside an agent session, so the button appears
        // with the agent and leaves with it.
        if terminals.agents[path] != nil {
            Button {
                toggleRightPanel(.skills)
            } label: {
                Text("Skills")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(HeaderButtonChrome(active: rightPanel == .skills))
            .help("Apply a skill to this session")
        }

        // Split launch button: the menu picks the agent, play starts it.
        // Uninstalled harnesses are listed too — picking one offers to run
        // its install command instead of silently failing.
        launchButton(for: path)
        // No header ✕ — terminals close from their sidebar rows (hover ✕,
        // context menu) or by the shell exiting.
    }

    private func launchButton(for path: String) -> some View {
        HStack(spacing: 6) {
            Button {
                guard !agentMenuOpen, let anchor = agentMenuBox.view else { return }
                agentMenuOpen = true
                DispatchQueue.main.async {
                    agentMenu().popUp(
                        positioning: nil,
                        at: NSPoint(x: -12, y: -6),
                        in: anchor
                    )
                    agentMenuOpen = false
                }
            } label: {
                HStack(spacing: 6) {
                    Text(launchAgent.shortLabel)
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MenuAnchorReader(box: agentMenuBox))

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
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Run \(launchAgent.label) in this project's shell")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .modifier(HeaderButtonChrome(active: agentMenuOpen))
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
                + (terminals.installCommand(for: agent) ?? "")
                + "\n\nin this project's shell."
            )
        }
    }

    /// The harness picker's menu: installed agents plain, uninstalled ones
    /// marked and routed to the install prompt.
    private func agentMenu() -> NSMenu {
        let menu = NSMenu()
        for agent in CodingAgent.launchable {
            if terminals.installedAgents.contains(agent) {
                menu.addItem(ClosureMenuItem(agent.label) { launchAgent = agent })
            } else {
                let item = ClosureMenuItem(agent.label) { pendingInstall = agent }
                item.image = NSImage(
                    systemSymbolName: "arrow.down.circle",
                    accessibilityDescription: nil
                )
                menu.addItem(item)
            }
        }
        return menu
    }

    private var gitButtonTitle: String {
        guard let info = git.info else { return "Git" }
        return info.isRepo ? info.branchLabel : "Git"
    }

    private var headerTitle: String {
        switch selection {
        case let .project(path):
            terminals.tabs[path]?.first?.customName ?? name(of: path)
        case let .shell(path, tab):
            terminals.tabs[path]?.first { $0.id == tab }?.customName ?? name(of: path)
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
        // Chat mode swaps the surface, not the session: panes stay mounted
        // in TerminalSessionManager, so shells and agents keep running
        // underneath — and the chat can belong to a different project than
        // the selected terminal.
        if let chatTarget {
            // Chat owns the whole detail column (no terminal bars), so it
            // carries the full 24px frame itself.
            ChatBrowserView(
                projectPath: chatTarget.path,
                initialSessionFile: chatTarget.sessionFile
            )
            .id(chatTarget)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.top, 24)
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        } else {
            selectionContent
        }
    }

    /// Whether the status bar band renders under the terminal — when it
    /// does, the terminal card adds no bottom padding of its own.
    private var statusBarVisible: Bool {
        guard let path = selection?.projectPath else { return false }
        return terminals.hasPane(for: path) && !settings.statusBarDisabled
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case let .project(path), let .shell(path, _):
            if terminals.hasPane(for: path) {
                // Inset from the right so the chrome wraps the terminal,
                // with the surface itself rounded off. The panels that used
                // to float here live in the right sheet now.
                // The action bar and status bar ARE the top/bottom bands
                // here — the card adds no vertical padding of its own
                // (24px bottom only if the status bar is off).
                TerminalHostView(path: path, tabID: selection?.tabID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.trailing, 24)
                    .padding(.bottom, statusBarVisible ? 0 : 24)
            } else {
                // Selection normally clears when the last pane closes (see
                // the terminalPaths onChange) — this is the transient frame
                // before it does, and any odd path into a pane-less
                // selection. Same sky either way.
                emptyState
            }
        case let .server(id):
            // Unreachable today — server rows aren't selectable (they open
            // the right-sheet panel) — but kept sensible: same view, centered.
            if let server = servers.devServers.first(where: { $0.id == id }) {
                ServerPanel(
                    server: server,
                    share: share,
                    relay: relay,
                    health: servers.health[id],
                    onOpenTerminal: {
                        guard let cwd = server.cwd else { return }
                        select(.project(cwd))
                    }
                )
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Server stopped",
                    systemImage: "bolt.slash",
                    description: Text("This server is no longer listening.")
                )
            }
        case .none:
            emptyState
        }
    }

    /// The empty-state sky, in the terminal's rounded container so the two
    /// detail states read as the same surface swapping content. The 24pt
    /// frame matches chat mode's; in terminal view the action/status bars
    /// stand in for the vertical bands.
    private var emptyState: some View {
        // While the sidebar is hidden for onboarding, the sky holds the
        // welcome screen's 56pt lift so the dismissal crossfade lands on an
        // already-aligned solar system; the reveal spring then glides it
        // down to center as the sidebar slides in.
        EmptyStateView(skyLift: sidebarRevealed ? 0 : -56)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.top, 24)
            .padding(.trailing, 24)
            .padding(.bottom, 24)
            // Dead chrome — a click on the sky dismisses a floating sheet.
            .contentShape(Rectangle())
            .onTapGesture { closeFloatingSheet() }
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
    /// A group's rows in the Folders library. Running state doesn't matter —
    /// only pinned projects are excluded, since they have their own rows.
    private func libraryPaths(in group: ProjectGroup) -> [String] {
        group.projects.map(\.path).filter { !store.pinnedProjects.contains($0) }
    }

    /// Uncommitted line counts for a library row; nil when clean, not a
    /// repo, or the first scan is still out.
    private func libraryDiff(_ path: String) -> (added: Int, removed: Int)? {
        if case let .dirty(added, removed) = git.rowStatuses[path] {
            return (added, removed)
        }
        return nil
    }

    /// Everything the sidebar shows a git dot or subtext for: open terminals
    /// plus the whole Projects library.
    private var gitWatchSet: Set<String> {
        Set(terminalPaths)
            .union(store.pinnedProjects)
            .union(store.projectGroups.flatMap { $0.projects.map(\.path) })
    }


    private func byName(_ a: String, _ b: String) -> Bool {
        (a as NSString).lastPathComponent
            .localizedCaseInsensitiveCompare((b as NSString).lastPathComponent) == .orderedAscending
    }

    /// The flattened row list the table renders: Terminals, Servers, Projects.
    private var entries: [SidebarEntry] {
        var out: [SidebarEntry] = []
        // Terminals on top: every open shell is an *instance* row here
        // (status dot, nested tabs, ✕). Projects below are chat-centric
        // headers — the terminal button on a header adds an instance up
        // in this section (2026-09-09, replaces the hoist-to-top design).
        out.append(.header("Terminals"))
        if terminalPaths.isEmpty {
            // The "New" affordance stands in for the first row (same
            // height), so the sections below don't jump when it's swapped.
            out.append(.action(key: "new-terminal", title: "New"))
        }
        for path in terminalPaths {
            let list = terminals.tabs[path] ?? []
            out.append(.row(
                id: .project(path),
                title: list.first?.customName ?? name(of: path)
            ))
            // Extra terminals in the same directory: full peer rows, same
            // name — rename is there for anyone who wants to tell them apart.
            for tab in list.dropFirst() {
                out.append(.row(
                    id: .shell(path: path, tab: tab.id),
                    title: tab.customName ?? name(of: path)
                ))
            }
        }
        // Servers moved out of the table (2026-09-12): they live in the
        // top cluster now, beside Settings/Tasks/Notifications — live ones
        // always nested under the item, stopped ones on disclosure.
        // Each project is a collapsible header (no dot) with its chats
        // nested underneath; the hover buttons add a chat or a terminal.
        out.append(.header("Projects"))
        for path in store.pinnedProjects {
            out.append(.folder(path: path, name: name(of: path)))
            if !collapsedProjects.contains(path) {
                out += chatEntries(under: path)
            }
        }
        return out
    }

    private func toggleProjectCollapsed(_ path: String) {
        if collapsedProjects.contains(path) {
            collapsedProjects.remove(path)
        } else {
            collapsedProjects.insert(path)
            chatRowsShown[path] = nil
            archivedShown.remove(path)
            capsuleRowsShown[path] = nil
        }
        updateSettings { $0.collapsedFolders = Array(collapsedProjects) }
    }

    private func name(of path: String) -> String {
        path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
    }

    /// Chat rows first shown under a project — "Show more" steps by this.
    private static let chatRowsBase = 6

    /// Recent chats nested under a project header. An empty `file` marks
    /// the "Show more" tail row, which discloses another step of rows.
    private func chatEntries(under path: String) -> [SidebarEntry] {
        // Sealed chats live on the capsule shelf, not here — the sidebar
        // lists only chats that are still open.
        let all = (chatIndex.chats[path] ?? [])
            .filter { !capsuleStore.isSealed($0.filePath) }
        let refs = chatMeta.arrangeSidebar(all)
        let shown = chatRowsShown[path] ?? Self.chatRowsBase
        var rows: [SidebarEntry] = refs.prefix(shown).map {
            .chat(
                project: path, file: $0.filePath,
                title: chatTitler.displayTitle($0), harness: $0.harness.rawValue
            )
        }
        if refs.count > shown {
            rows.append(.chat(project: path, file: "", title: "Show more", harness: ""))
        }
        // The project's history rides right under the current chat: five
        // capsules as rows (click views, drag attaches), "Show more"
        // stepping out five at a time, and — once everything's out — a
        // "View all capsules" tail into the full shelf.
        let capsules = capsuleStore.capsules(for: path)
        let capsulesShown = capsuleRowsShown[path] ?? 5
        rows += capsules.prefix(capsulesShown).map {
            .capsuleChat(project: path, capsuleID: $0.id, title: $0.title)
        }
        if capsules.count > capsulesShown {
            rows.append(.action(
                key: "capsules-more:\(path)", title: "Show more"
            ))
        } else if !capsules.isEmpty {
            rows.append(.action(
                key: "capsules:\(path)", title: "View all capsules"
            ))
        }
        // Archived chats fold under their own toggle — this is their only
        // home now that the transcript view has no list.
        let archived = all.filter { chatMeta.archived.contains($0.filePath) }
        if !archived.isEmpty {
            rows.append(.action(
                key: "archived:\(path)",
                title: archivedShown.contains(path)
                    ? "Hide archived" : "Archived (\(archived.count))"
            ))
            if archivedShown.contains(path) {
                rows += archived.map {
                    SidebarEntry.chat(
                        project: path, file: $0.filePath,
                        title: chatTitler.displayTitle($0),
                        harness: $0.harness.rawValue
                    )
                }
            }
        }
        return rows
    }

    private func discloseMoreChats(in path: String) {
        chatRowsShown[path] = (chatRowsShown[path] ?? Self.chatRowsBase)
            + Self.chatRowsBase
    }

    /// Open a chat from the sidebar — never moves the terminal selection.
    private func openChat(project: String, file: String) {
        chatTarget = ChatTarget(path: project, sessionFile: file.isEmpty ? nil : file)
    }

    /// End a chat: seal it into a capsule. The transcript stays on disk
    /// untouched; the row leaves the open list the same instant and the
    /// capsule appears on the project's shelf. A chat mid-turn keeps
    /// running — it can seal once the turn is done.
    private func sealChat(project: String, file: String, title: String, harness: String) {
        guard !file.isEmpty,
              ChatSessionHub.shared.sessions[file]?.running != true else { return }
        ChatSessionHub.shared.forget(file: file)
        let ref = ChatSessionRef(
            harness: ChatHarness(rawValue: harness) ?? .claude,
            filePath: file, title: title, modified: Date()
        )
        capsuleStore.seal(
            ref: ref, project: project, title: chatTitler.displayTitle(ref)
        )
        if chatTarget?.sessionFile == file {
            chatTarget = ChatTarget(path: project, sessionFile: nil)
        }
    }

    /// Delete a chat: shut its live session down, trash the transcript
    /// (recoverable), and fall back to the project's chat list if it was
    /// open.
    private func deleteChat(project: String, file: String) {
        ChatSessionHub.shared.forget(file: file)
        ChatMetaStore.shared.forget(file)
        CapsuleStore.shared.forget(file: file)
        try? FileManager.default.trashItem(
            at: URL(fileURLWithPath: file), resultingItemURL: nil
        )
        if chatTarget?.sessionFile == file {
            chatTarget = ChatTarget(path: project, sessionFile: nil)
        }
        chatIndex.refresh(project, force: true)
    }

    /// The project row's "+" — the new-chat empty state; chats live
    /// outside terminals now (sends run through `ChatSessionHub`).
    private func newChat(in path: String) {
        // A stale draft (a finished turn that never promoted onto its
        // file) would hijack the empty state and make "+" look dead — a
        // fresh "+" means a fresh chat, so anything idle is discarded.
        if let draft = ChatSessionHub.shared.drafts[path], !draft.running {
            ChatSessionHub.shared.discardDraft(in: path)
        }
        chatTarget = ChatTarget(path: path, sessionFile: nil)
        chatIndex.refresh(path, force: true)
    }

    /// The project row's terminal button — another plain shell.
    private func newTerminal(in path: String) {
        if terminals.hasPane(for: path) {
            if let tab = terminals.newTab(in: path) {
                select(.shell(path: path, tab: tab.id))
            }
        } else {
            select(.project(path))
        }
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
            // The space above the bottom-aligned label IS the gap between
            // sections; just tall enough for the "+" button's hit area.
            return 20
        case .folder:
            // 26 of content + 4 of in-row vertical padding.
            return 30
        case let .action(key, _):
            // "New" stands in for the first terminal row — same height as one
            // (28pt), so the sections below don't jump when it's swapped out.
            return key == "new-terminal" ? 28 : 24
        case .divider:
            return 11
        case .chat, .capsuleChat:
            return 26
        case let .row(id, _):
            if case let .server(sid) = id {
                // Live rows carry the URL subtext; stopped ones are a
                // single line.
                return servers.devServers.contains { $0.id == sid } ? 38 : 28
            }
            if case let .project(path) = id, !terminals.hasPane(for: path) { return 26 }
            return 28
        }
    }

    // MARK: - Sidebar rows

    @ViewBuilder
    private func row(for entry: SidebarEntry, hovered: Bool) -> some View {
        switch entry {
        case let .header(title):
            HStack(alignment: .bottom, spacing: 0) {
                Text(title.uppercased())
                    .font(Theme.Fonts.meta)
                    .kerning(0.5)
                    .foregroundStyle(Theme.heading)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
                if title == "Terminals" {
                    HeaderPlusButton(help: "New terminal in the home folder") {
                        let home = NSHomeDirectory()
                        if terminals.hasPane(for: home),
                           let tab = terminals.newTab(in: home) {
                            select(.shell(path: home, tab: tab.id))
                        } else {
                            select(.project(home))
                        }
                    }
                } else if title == "Projects" {
                    HeaderPlusButton(icon: "folder.badge.plus", help: "Add a project") {
                        addFolder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 10)
            .padding(.trailing, 6)

        case let .action(key, title):
            if key == "open-folder" {
                // Two ways in: a local project folder, or a fresh clone.
                Menu {
                    Button("Add Project…") { addFolder() }
                    Button("Clone Repository…") { cloneRepository() }
                } label: {
                    actionRowLabel(title: title, hovered: hovered)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            } else if key.hasPrefix("capsules") {
                // The capsule list's tail rows ("Show more" / "View all
                // capsules"): dimmed gray, title-only, lined up with the
                // capsule titles above them.
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 42)
                    .modifier(RowChrome(hovered: hovered, selected: false))
                    .contentShape(Rectangle())
                    .onTapGesture { runAction(key) }
            } else {
                actionRowLabel(title: title, hovered: hovered)
                    .onTapGesture { runAction(key) }
            }

        case .divider:
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)

        case let .chat(project, file, title, harness):
            let open = !file.isEmpty && chatTarget?.path == project
                && chatTarget?.sessionFile == file
            let pinned = !file.isEmpty && chatMeta.pinned.contains(file)
            let isBranch = !file.isEmpty && chatMeta.branches[file] != nil
            HStack(spacing: 6) {
                if !file.isEmpty {
                    // Chats carry a bubble; a chat forked off another
                    // carries the branch glyph instead.
                    Image(systemName: isBranch
                        ? "arrow.triangle.branch" : "bubble.left")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 13))
                    // A step dimmer than the project header; the
                    // "Show more" disclosure row fades to gray.
                    .foregroundStyle(file.isEmpty
                        ? Theme.textSecondary : Theme.text.opacity(0.8))
                    .lineLimit(1)
                // Pin marker rides the trailing edge so titles line up.
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                // End the chat: seal it into a capsule (the terminal
                // rows' ✕ kills; this one archives — the transcript
                // survives untouched under the capsule).
                if hovered, !file.isEmpty {
                    RowActionIcon(
                        symbol: "xmark", help: "End chat — seal into a capsule"
                    ) {
                        sealChat(
                            project: project, file: file,
                            title: title, harness: harness
                        )
                    }
                }
            }
            // Lines up with the project header's name (18pt icon + 9 gap).
            .padding(.leading, 27)
            .modifier(RowChrome(hovered: hovered, selected: open))
            .help(harness.isEmpty ? "" : harness)
            .onTapGesture {
                if file.isEmpty {
                    discloseMoreChats(in: project)
                } else {
                    openChat(project: project, file: file)
                }
            }

        case let .capsuleChat(project, capsuleID, title):
            // A sealed chat: the chat bubble wrapped in a capsule outline.
            // Click shows its transcript in the right sheet; dragging the
            // row into a composer attaches the whole capsule as a chip.
            let viewing = rightPanel == .capsules(project: project, focus: capsuleID)
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 6.5))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2.5)
                    .overlay(Capsule().strokeBorder(lineWidth: 1))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .modifier(RowChrome(hovered: hovered, selected: viewing))
            .contentShape(Rectangle())
            .onTapGesture {
                toggleRightPanel(.capsules(project: project, focus: capsuleID))
            }
            .onDrag {
                let reference = capsuleStore.capsules
                    .first { $0.id == capsuleID }?.referenceText ?? ""
                return NSItemProvider(object: reference as NSString)
            }
            .help("A sealed chat — click to view, drag into the chat to attach it")

        case let .folder(path, folderName):
            // A project header: no dot, chats fold underneath (click
            // toggles), and hover carries the actions — "+" starts a chat,
            // the terminal glyph adds an instance up in Terminals.
            let collapsed = collapsedProjects.contains(path)
            HStack(spacing: 9) {
                // The project's own logo when it ships one; the chevron
                // takes over on hover (and everywhere for logo-less rows).
                ZStack {
                    if !hovered, let logo = ProjectLogoCache.logo(for: path) {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
                            // Tints template logos (dark monochrome glyphs)
                            // with the appearance; full-color ones ignore it.
                            .foregroundStyle(Theme.text)
                    } else {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                            .opacity(hovered ? 1 : 0.55)
                    }
                }
                .frame(width: 18, height: 18)
                Text(folderName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hovered {
                    HStack(spacing: 1) {
                        RowActionIcon(symbol: "plus", help: "New chat") {
                            newChat(in: path)
                        }
                        RowActionIcon(symbol: "terminal", help: "New terminal") {
                            newTerminal(in: path)
                        }
                    }
                }
            }
            // The breathing room lives inside the row (and its hover
            // chrome), not as a gap between rows.
            .padding(.vertical, 2)
            .modifier(RowChrome(hovered: hovered, selected: false))
            .onTapGesture { toggleProjectCollapsed(path) }

        case let .row(id, title):
            switch id {
            case let .project(path):
                let active = terminals.hasPane(for: path)
                if !active {
                    // Idle: the row sits in the library — quiet glyph, git
                    // diff as subtext. Opening a shell hoists this same row
                    // (same identity) to the top of the section.
                    SidebarRow(
                        name: title,
                        diff: libraryDiff(path),
                        diffTooltipOnly: sidebarNarrow,
                        isProject: ProjectKindCache.isProject(path),
                        hovered: hovered,
                        selected: selection == id
                    )
                } else {
                    let mainTab = terminals.tabs[path]?.first?.id
                    let renaming = mainTab != nil
                        && renameTarget == mainTab.map { RenameTarget(path: path, tabID: $0) }
                    SidebarRow(
                        name: renaming
                            ? currentRowName(path: path, tabID: mainTab!) : title,
                        agent: primaryAgent(path: path),
                        hasTerminal: true,
                        // Gated on the process scan so a killed agent (no
                        // Stop hook ever fires) can't pulse forever.
                        working: terminals.agents[path] != nil
                            && notify.isWorking(path: path),
                        gitStatus: git.rowStatuses[path] ?? .none,
                        needsAttention: notify.hasAttention(path: path),
                        hovered: hovered,
                        selected: selection == id,
                        onClose: { closeTerminal(path) },
                        renaming: renaming,
                        onRename: { result in
                            if let mainTab {
                                finishInlineRename(path: path, tabID: mainTab, result: result)
                            }
                        }
                    )
                }
            case let .shell(path, tabID):
                let renaming = renameTarget == RenameTarget(path: path, tabID: tabID)
                SidebarRow(
                    name: renaming ? currentRowName(path: path, tabID: tabID) : title,
                    agent: shellAgent(path: path, tab: tabID),
                    hasTerminal: true,
                    working: terminals.agents[path] != nil
                        && notify.isWorking(path: path, tab: tabID),
                    gitStatus: git.rowStatuses[path] ?? .none,
                    needsAttention: notify.hasAttention(path: path, tab: tabID),
                    hovered: hovered,
                    selected: selection == id,
                    onClose: { terminals.closeTab(path: path, tabID: tabID) },
                    renaming: renaming,
                    onRename: { result in
                        finishInlineRename(path: path, tabID: tabID, result: result)
                    }
                )
            case let .server(sid):
                if let server = servers.devServers.first(where: { $0.id == sid }) {
                    ServerRow(
                        server: server,
                        health: servers.health[sid],
                        hovered: hovered || rightPanel == .server(sid),
                        selected: false
                    )
                    .contentShape(Rectangle())
                    // The server page is a right-sheet panel, same as Git —
                    // clicking the row toggles it, never the selection.
                    .onTapGesture { toggleRightPanel(.server(sid)) }
                } else if let recent = servers.recents.first(where: { $0.id == sid }) {
                    ServerRow(
                        recent: recent,
                        hovered: hovered || rightPanel == .server(sid)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { toggleRightPanel(.server(sid)) }
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
        case let .action(key, title):
            // Title is in the key: "Capsules (2)" → "(3)" and
            // "Archived (n)" must re-host, their keys don't change.
            return "a:\(key)|\(title)|\(hovered ? "h" : "-")"
        case .divider:
            return "div"
        case let .chat(project, file, title, _):
            let open = !file.isEmpty && chatTarget?.path == project
                && chatTarget?.sessionFile == file
            let pinned = chatMeta.pinned.contains(file)
            let branch = chatMeta.branches[file] != nil
            return "ch:\(title)|\(open ? "o" : "-")|\(pinned ? "p" : "-")"
                + "|\(branch ? "b" : "-")|\(hovered ? "h" : "-")"
        case let .capsuleChat(project, capsuleID, title):
            let viewing = rightPanel == .capsules(project: project, focus: capsuleID)
            return "cc:\(title)|\(viewing ? "v" : "-")|\(hovered ? "h" : "-")"
        case let .folder(path, folderName):
            let collapsed = collapsedProjects.contains(path)
            return "f:\(folderName)|\(collapsed ? "c" : "-")|\(hovered ? "h" : "-")"
        case let .row(id, title):
            let selected = selection == id
            switch id {
            case let .project(path):
                // Idle rows read the diff subtext and the narrow flag;
                // active rows read the agent/attention/rename state — both
                // sets ride in one key so the hoist re-hosts the content.
                if !terminals.hasPane(for: path) {
                    let diff = libraryDiff(path).map { "+\($0.added)-\($0.removed)" } ?? "-"
                    return [
                        "lib", title, diff,
                        sidebarNarrow ? "n" : "-",
                        ProjectKindCache.isProject(path) ? "p" : "-",
                        selected ? "s" : "-",
                        hovered ? "h" : "-",
                    ].joined(separator: "|")
                }
                let renaming = renameTarget?.path == path
                    && renameTarget?.tabID == terminals.tabs[path]?.first?.id
                let working = terminals.agents[path] != nil
                    && notify.isWorking(path: path)
                return [
                    title, "t",
                    primaryAgent(path: path)?.label ?? "-",
                    working ? "w" : "-",
                    String(describing: git.rowStatuses[path] ?? .none),
                    notify.hasAttention(path: path) ? "!" : "-",
                    selected ? "s" : "-",
                    hovered ? "h" : "-",
                    renaming ? "r" : "-",
                ].joined(separator: "|")
            case let .shell(path, tab):
                let agent = shellAgent(path: path, tab: tab)?.label ?? "-"
                let status = String(describing: git.rowStatuses[path] ?? .none)
                let bang = notify.hasAttention(path: path, tab: tab) ? "!" : "-"
                let renaming = renameTarget == RenameTarget(path: path, tabID: tab)
                let working = terminals.agents[path] != nil
                    && notify.isWorking(path: path, tab: tab)
                return "sh:\(title)|\(tab)|\(agent)|\(working ? "w" : "-")|\(status)|\(bang)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")|\(renaming ? "r" : "-")"
            case let .server(sid):
                let live = servers.devServers.first { $0.id == sid }
                let port = live.map { String($0.port) }
                    ?? servers.recents.first { $0.id == sid }.map { String($0.port) }
                    ?? "-"
                let health = servers.health[sid].map { String(describing: $0) } ?? "-"
                // The row stays lit while its sheet panel is open — that
                // state must be in the key or the highlight never updates.
                let state = rightPanel == .server(sid) ? "P" : (hovered ? "h" : "-")
                return "\(title)|\(port)|\(health)|\(live != nil ? "on" : "off")|\(state)"
            }
        }
    }

    // MARK: - Context menus

    private func menu(for entry: SidebarEntry) -> NSMenu? {
        if case let .folder(path, _) = entry {
            let menu = NSMenu()
            // Any directory can host a shell — a folder-of-folders group
            // included, not just its project children.
            menu.addItem(ClosureMenuItem("Open Terminal Here") {
                select(.project(path))
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                Actions.revealInFinder(path: path)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Sidebar") {
                // Project rows come from pinnedProjects; parent folder
                // groups from projectsDirs — clear the path from both.
                updateSettings {
                    $0.pinnedProjects.removeAll { $0 == path }
                    $0.projectsDirs.removeAll { $0 == path }
                    $0.collapsedFolders.removeAll { $0 == path }
                }
                collapsedProjects.remove(path)
                store.settingsChanged()
            })
            return menu
        }
        // A chat row: rename/pin/archive ride ChatTitler + ChatMetaStore;
        // delete moves the transcript to the Trash (recoverable).
        if case let .chat(project, file, title, harness) = entry, !file.isEmpty {
            let ref = ChatSessionRef(
                harness: ChatHarness(rawValue: harness) ?? .claude,
                filePath: file, title: title, modified: Date()
            )
            let meta = ChatMetaStore.shared
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("End Chat — Seal into Capsule") {
                sealChat(project: project, file: file, title: title, harness: harness)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Rename…") {
                ChatRowActions.promptRename(ref)
            })
            menu.addItem(ClosureMenuItem(meta.pinned.contains(file) ? "Unpin" : "Pin") {
                meta.togglePin(file)
            })
            menu.addItem(ClosureMenuItem(
                meta.archived.contains(file) ? "Unarchive" : "Archive"
            ) {
                meta.toggleArchive(file)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Branch Chat") {
                ChatRowActions.duplicate(ref, project: project, asBranch: true)
            })
            menu.addItem(ClosureMenuItem("Duplicate") {
                ChatRowActions.duplicate(ref, project: project)
            })
            menu.addItem(ClosureMenuItem("Copy Transcript") {
                ChatRowActions.copyTranscript(ref)
            })
            menu.addItem(ClosureMenuItem("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file)]
                )
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Chat") {
                deleteChat(project: project, file: file)
            })
            return menu
        }
        // A sealed chat's row: view, attach, reopen, delete — the same set
        // the capsule shelf offers.
        if case let .capsuleChat(project, capsuleID, _) = entry,
           let capsule = capsuleStore.capsules.first(where: { $0.id == capsuleID }) {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open Capsule View") {
                toggleRightPanel(.capsules(project: project, focus: capsuleID))
            })
            menu.addItem(ClosureMenuItem("New Chat with Capsule") {
                attachCapsuleToNewChat(project: project, capsule: capsule)
            })
            menu.addItem(ClosureMenuItem("Reopen Chat") {
                capsuleStore.unseal(capsule)
                openChat(project: project, file: capsule.sourceFile)
            })
            menu.addItem(ClosureMenuItem("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: capsule.sourceFile)]
                )
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Delete Chat and Capsule") {
                deleteChat(project: project, file: capsule.sourceFile)
            })
            return menu
        }
        // The "New" row: click opens a home shell; the menu carries what the
        // old header "+" offered — a second shell in the selected project.
        if case .action(key: "new-terminal", _) = entry {
            let menu = NSMenu()
            if let path = selection?.projectPath, terminals.hasPane(for: path) {
                menu.addItem(ClosureMenuItem("New shell in \(name(of: path))") {
                    if let tab = terminals.newTab(in: path) {
                        select(.shell(path: path, tab: tab.id))
                    }
                })
            }
            menu.addItem(ClosureMenuItem("New shell in home folder") {
                select(.project(NSHomeDirectory()))
            })
            return menu
        }
        guard let id = entry.selection else { return nil }
        let menu = NSMenu()
        switch id {
        case let .shell(path, tabID):
            // Key equivalents here are labels: the main menu dispatches the
            // actual shortcuts, the context menu just advertises them.
            let newHere = ClosureMenuItem("New Terminal Here") {
                if let tab = terminals.newTab(in: path) {
                    select(.shell(path: path, tab: tab.id))
                }
            }
            newHere.keyEquivalent = "d"
            newHere.keyEquivalentModifierMask = [.command]
            menu.addItem(newHere)
            let rename = ClosureMenuItem("Rename…") {
                renameTerminal(path: path, tabID: tabID)
            }
            rename.keyEquivalent = "r"
            rename.keyEquivalentModifierMask = [.command]
            menu.addItem(rename)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Close Terminal") {
                terminals.closeTab(path: path, tabID: tabID)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Reveal in Finder") {
                Actions.revealInFinder(path: path)
            })
        case let .project(path):
            if terminals.hasPane(for: path) {
                let start = ClosureMenuItem("Start Claude") {
                    terminals.start(.claude, in: path)
                }
                start.keyEquivalent = "\r"
                start.keyEquivalentModifierMask = [.command]
                menu.addItem(start)
                let newHere = ClosureMenuItem("New Terminal Here") {
                    if let tab = terminals.newTab(in: path) {
                        select(.shell(path: path, tab: tab.id))
                    }
                }
                newHere.keyEquivalent = "d"
                newHere.keyEquivalentModifierMask = [.command]
                menu.addItem(newHere)
                let rename = ClosureMenuItem("Rename…") {
                    if let tabID = terminals.tabs[path]?.first?.id {
                        renameTerminal(path: path, tabID: tabID)
                    }
                }
                rename.keyEquivalent = "r"
                rename.keyEquivalentModifierMask = [.command]
                menu.addItem(rename)
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
            guard let server = servers.devServers.first(where: { $0.id == sid }) else {
                guard let recent = servers.recents.first(where: { $0.id == sid }) else { return nil }
                let path = recent.projectPath
                menu.addItem(ClosureMenuItem("Open Terminal Here") {
                    terminals.pane(for: path)
                    selection = .project(path)
                })
                menu.addItem(ClosureMenuItem("Reveal in Finder") {
                    Actions.revealInFinder(path: path)
                })
                menu.addItem(.separator())
                // Temporary by design: the row returns the next time a
                // server runs (and stops) in this project.
                menu.addItem(ClosureMenuItem("Remove from Sidebar") {
                    if rightPanel == .server(sid) { closeRightPanel() }
                    servers.removeRecent(sid)
                })
                return menu
            }
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
        // Selecting a terminal row means "type here now": focus follows the
        // selection into the pane, so keys (including arrows) go to the
        // shell, not sidebar navigation.
        switch target {
        case let .project(path):
            terminals.focusTerminal(path: path)
        case let .shell(path, tabID):
            terminals.focusTerminal(path: path, tab: tabID)
        default:
            break
        }
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

    /// Invisible receiver for the menu's shortcut notifications.
    private var shortcutListeners: some View {
        Color.clear
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonNewTerminalTab)
            ) { _ in newTerminalFromShortcut() }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonCycleTerminal)
            ) { note in cycleTerminal(by: note.userInfo?["delta"] as? Int ?? 1) }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonSelectTerminalIndex)
            ) { note in
                if let index = note.userInfo?["index"] as? Int {
                    let rows = orderedTerminalRows
                    if rows.indices.contains(index) { select(rows[index]) }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonToggleSidebar)
            ) { _ in toggleSidebarCollapse() }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonToggleGitPanel)
            ) { _ in toggleRightPanel(.git) }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonLaunchAgent)
            ) { _ in
                if let path = selection?.projectPath {
                    terminals.start(launchAgent, in: path)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonOpenFolder)
            ) { _ in addFolder() }
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonRenameTerminal)
            ) { _ in renameSelectedTerminal() }
            // A capsule chip in a chat: open that capsule's transcript in
            // the right sheet.
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonOpenCapsule)
            ) { note in
                guard let file = note.object as? String else { return }
                if let capsule = capsuleStore.capsule(forFile: file) {
                    toggleRightPanel(
                        .capsules(project: capsule.project, focus: capsule.id)
                    )
                } else if let project = chatTarget?.path {
                    // The capsule was dissolved — land on the shelf.
                    toggleRightPanel(.capsules(project: project, focus: nil))
                }
            }
            // The auto-seal sweep lives in CapsuleStore; the view's only
            // job is telling it which chat is on screen (protected).
            .onChange(of: chatTarget) { _, target in
                capsuleStore.activeChatFile = target?.sessionFile
            }
    }

    /// ⌘R: rename whichever terminal row is selected — a nested shell
    /// renames itself, a project row renames its main terminal.
    private func renameSelectedTerminal() {
        switch selection {
        case let .shell(path, tabID):
            renameTerminal(path: path, tabID: tabID)
        case let .project(path):
            if let tabID = terminals.tabs[path]?.first?.id {
                renameTerminal(path: path, tabID: tabID)
            }
        default:
            break
        }
    }

    /// Every terminal row in sidebar display order — each project's main
    /// terminal, then its nested shells. ⌘1–⌘9 and ⌘⌥↑/↓ walk this list.
    private var orderedTerminalRows: [SidebarSelection] {
        terminalPaths.flatMap { path -> [SidebarSelection] in
            guard let tabs = terminals.tabs[path], !tabs.isEmpty else { return [] }
            return [.project(path)]
                + tabs.dropFirst().map { .shell(path: path, tab: $0.id) }
        }
    }

    /// ⌘T: another shell in the selected project's directory (the sidebar's
    /// nested "name · N" row), selected and focused. With no terminal open
    /// yet the same key opens the project's first one.
    private func newTerminalFromShortcut() {
        guard let path = selection?.projectPath else { return }
        if terminals.hasPane(for: path), let tab = terminals.newTab(in: path) {
            select(.shell(path: path, tab: tab.id))
        } else {
            select(.project(path))
        }
    }

    /// ⌘⌥↑/↓: step through `orderedTerminalRows`, wrapping at the ends.
    private func cycleTerminal(by delta: Int) {
        let rows = orderedTerminalRows
        guard !rows.isEmpty else { return }
        guard let selection, let current = rows.firstIndex(of: selection) else {
            select(rows[0])
            return
        }
        let next = ((current + delta) % rows.count + rows.count) % rows.count
        select(rows[next])
    }

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

        // The ✕ ends only the project's main terminal. Extra "· N" tabs
        // are independent shells that happen to share the directory — the
        // next one is promoted to the main row (closeTab leaves the rest
        // of the list intact, and the sidebar derives its rows from it)
        // instead of being torn down alongside the first.
        if let main = terminals.tabs[path]?.first {
            terminals.closeTab(path: path, tabID: main.id)
        }
        if terminals.hasPane(for: path) {
            // A sibling survived and was promoted; a selection pointing
            // here still names a live terminal — nothing to reselect.
            return
        }

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

// MARK: - Collapsed-rail pieces

/// The three sections the collapsed rail exposes as popovers.
private enum RailSection: String, Identifiable {
    case terminals, servers, projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminals: "Terminals"
        case .servers: "Servers"
        case .projects: "Projects"
        }
    }
}

/// A rail icon button: quiet glyph, hover fill, selected fill while its
/// popover is open.
private struct RailButton<Icon: View>: View {
    let help: String
    let active: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(active ? Theme.rowSelected : (hovered ? Theme.rowHovered : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// A row inside a rail popover. The popovers are plain SwiftUI (no
/// `NSTableView` here), so hover is tracked locally per row.
private struct PopoverRow<Content: View>: View {
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovered = $0 }
    }
}

/// Accent pill in the sidebar footer while a newer release exists — the
/// quiet, persistent form of the update notice (the loud one is the manual
/// check's alert). Click installs in place and relaunches.
private struct UpdatePill: View {
    let version: String
    var busy: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: busy
                    ? "arrow.triangle.2.circlepath"
                    : "arrow.down.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(busy ? "Updating…" : version)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.buttonActiveStroke)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.buttonActiveFill))
            .overlay(
                Capsule().strokeBorder(
                    Theme.buttonActiveStroke.opacity(hovered ? 0.9 : 0.35),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(busy)
        .help(busy
            ? "Updating Houston…"
            : "Update available — install Houston \(version)")
    }
}

/// A footer control in the gear's icon+label style — the bell/calendar rows
/// above Settings. With no label (the rail) it's the bare 22pt icon, badges
/// riding the corner; with one, the unread count / attention dot sits inline
/// after the text. Selected fill while its panel is open.
/// A server inside the Servers flyout card — the table's old `ServerRow`
/// (live or stopped variant) with its own hover, click-for-sheet, and
/// context menu. `height` pins the box: ServerRow ends in RowChrome,
/// which fills whatever it's given and would soak up the card otherwise.
private struct FlyoutServerRow<MenuItems: View>: View {
    let row: (Bool) -> ServerRow
    let height: CGFloat
    let onTap: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems

    @State private var hovered = false

    var body: some View {
        row(hovered)
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovered = $0 }
            .contextMenu { menuItems() }
    }
}

private struct FooterLabeledButton: View {
    let systemName: String
    var label: String? = nil
    var badgeCount: Int = 0
    var dot: Bool = false
    var active: Bool = false
    /// Overrides the glyph color (the Servers item goes signal-green
    /// while servers run).
    var iconTint: Color? = nil
    /// Quiet count to the label's right (live server tally) — plain gray
    /// text, not the amber attention badge.
    var count: Int = 0
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: label == nil ? 12 : 13))
                    .foregroundStyle(iconTint ?? (label == nil
                        ? (hovered || active ? Theme.text : Theme.heading)
                        : Theme.text))
                if let label {
                    // Top-level items read in the primary color a step
                    // above the 13pt rows (2026-09-12).
                    Text(label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if count > 0 {
                        Text(String(count))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 2)
                    }
                    badge
                }
            }
            .padding(.horizontal, label == nil ? 0 : 6)
            .frame(width: label == nil ? 22 : nil, height: label == nil ? 22 : 26)
            // Badge INSIDE the button's frame, not overhanging the glyph —
            // an ancestor clips at the frame edge and was slicing the pill.
            .overlay(alignment: .topTrailing) {
                if label == nil { badge }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(active
                        ? Theme.rowSelected
                        : (hovered ? Theme.rowHovered : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }

    @ViewBuilder
    private var badge: some View {
        if badgeCount > 0 {
            // 14×14 fully-rounded; double digits widen the pill, never
            // taller.
            Text(String(badgeCount))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14)
                .frame(height: 14)
                .background(Capsule().fill(Theme.dotDegraded))
        } else if dot {
            Circle()
                .fill(Theme.dotDegraded)
                .frame(width: 5, height: 5)
        }
    }
}

/// Footer/rail icon button with the gear's quiet hover chrome.
struct FooterIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(hovered ? Theme.text : Theme.heading)
                .frame(width: 22, height: 22)
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

// MARK: - Header button chrome

/// The design's header buttons: 30pt tall, #F3F3F3 fill, 6pt radius —
/// borderless unless active. Also used by the empty state's quick-open
/// buttons.
/// The header's Saved Changes opener — its own view because the badge
/// count comes from the project's AnnotationStore, a nested
/// ObservableObject the header wouldn't otherwise re-render for.
private struct NotesHeaderButton: View {
    @ObservedObject var store: AnnotationStore
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text.opacity(0.75))
                Text("Tasks")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                if !store.open.isEmpty {
                    Text(String(store.open.count))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Theme.buttonActiveStroke))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome(active: active))
        .help("Tasks saved from the web preview")
    }
}

struct HeaderButtonChrome: ViewModifier {
    /// Accent fill + 2px inside border while the button's menu or panel is
    /// open.
    var active = false

    func body(content: Content) -> some View {
        content
            .frame(height: 30)
            .background(
                active ? Theme.buttonActiveFill : Theme.buttonFill,
                in: RoundedRectangle(cornerRadius: Theme.radiusControl)
            )
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(Theme.buttonActiveStroke, lineWidth: 2)
                }
            }
    }
}

/// A header control that pops an `NSMenu` and reads as active while it's
/// open. SwiftUI's `Menu` exposes no open state, so the menu is popped
/// manually — `popUp` runs the tracking loop and returns on dismissal,
/// which is exactly the active window.
struct HeaderMenuButton<Label: View>: View {
    let makeMenu: () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var box = MenuAnchorBox()
    @State private var isOpen = false

    var body: some View {
        Button {
            guard !isOpen, let anchor = box.view else { return }
            isOpen = true
            // Next tick so the active chrome renders a frame before the
            // menu's tracking loop takes over.
            DispatchQueue.main.async {
                makeMenu().popUp(
                    positioning: nil,
                    at: NSPoint(x: 0, y: -6),
                    in: anchor
                )
                isOpen = false
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome(active: isOpen))
        .background(MenuAnchorReader(box: box))
    }
}

/// Weak handle to the AppKit view a popped menu anchors to.
final class MenuAnchorBox {
    weak var view: NSView?
}

struct MenuAnchorReader: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

// MARK: - Rows

/// Shared background for sidebar rows: the design's pill (8pt radius, 8pt
/// inner padding) inset `Theme.rowInset` from the sidebar edges.
///
/// Selection *and* hover are drawn here rather than by the table. Source-list
/// selection styling would only cover half of it — `NSTableView` has no hover
/// concept at all — and drawing the two in different layers is exactly what
/// produced mismatched, doubled highlights before. One place, one geometry.
private struct RowChrome: ViewModifier {
    let hovered: Bool
    let selected: Bool
    /// "Needs you": a rose wash over the pill. Drawn here — RowChrome is the
    /// one layer that draws row highlights — so it can never fight the
    /// hover/selection fills.
    var attention: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .fill(fill)
            )
            .padding(.horizontal, Theme.rowInset)
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if selected { return Theme.rowSelected }
        if hovered { return Theme.rowHovered }
        if attention { return Theme.buttonActiveFill }
        return .clear
    }
}

struct SidebarRow: View {
    let name: String
    /// Uncommitted line counts under the name (library rows): +added −removed.
    var diff: (added: Int, removed: Int)? = nil
    /// Inline diff suppressed (narrow sidebar) — the counts move into the
    /// row's hover tooltip instead of crowding the name.
    var diffTooltipOnly: Bool = false
    var agent: CodingAgent? = nil
    var hasTerminal: Bool = false
    /// An extra terminal tab nested under its project's row: indented, no
    /// git dot (same repo as the parent), plain terminal glyph.
    var nested: Bool = false
    /// The row's directory is itself a project (has `.git`, a manifest, …)
    /// rather than a plain folder — idle project rows get a project glyph.
    var isProject: Bool = false
    /// A library row whose project is running: trailing live dot, mirroring
    /// its Active row without moving anything.
    var live: Bool = false
    /// The pane's agent has a turn in flight — the dot pulses amber.
    var working: Bool = false
    var gitStatus: GitRowStatus = .none
    /// The session is waiting on the user (permission prompt, idle, or a
    /// finished turn) — rose wash over the whole row until viewed.
    var needsAttention: Bool = false
    var hovered: Bool = false
    var selected: Bool = false
    /// Close action for a live terminal row — while hovered, an ✕ takes the
    /// terminal icon's place.
    var onClose: (() -> Void)? = nil
    /// Inline rename: the name becomes an editable field prefilled with the
    /// current name. Return/blur commits, Esc cancels; committing an empty
    /// string restores the default name.
    var renaming: Bool = false
    /// Called once when editing ends — the new name, or nil for cancel.
    var onRename: ((String?) -> Void)? = nil

    @State private var renameDraft = ""
    /// Guards the blur-commit: once Return or Esc has answered, the focus
    /// change they cause must not answer again. Starts `true` — only
    /// `onAppear`'s seeding arms the field — because committing a rename
    /// changes the row's title, which rebuilds the row mid-commit, and the
    /// rebuilt copy's field can fire a blur before it is ever seeded. That
    /// phantom blur used to commit this fresh copy's empty draft ("restore
    /// default name"), silently undoing the rename Return had just saved.
    @State private var renameDone = true

    var body: some View {
        HStack(spacing: 8) {
            // Every row leads with a status dot (2026-09-09, replaces the
            // terminal avatar + project glyph): gray = idle, green = shell
            // open and ready, amber pulse = a turn in flight. Attention is
            // still the row itself: a wash drawn by RowChrome.
            StatusDot(state: hasTerminal ? (working ? .working : .ready) : .idle)
            if renaming {
                InlineRenameField(
                    text: $renameDraft,
                    fontSize: nested ? 12 : 13,
                    onSubmit: { finishRename(renameDraft) },
                    onCancel: { finishRename(nil) },
                    onBlur: { finishRename(renameDraft) }
                )
                .frame(height: 18)
                .onAppear {
                    renameDraft = name
                    renameDone = false
                }
            } else {
                Text(name)
                    .font(.system(size: nested ? 12 : 13))
                    .foregroundStyle(nested ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let diff, !diffTooltipOnly {
                HStack(spacing: 3) {
                    Text("+\(diff.added)")
                        .foregroundStyle(Theme.textPositive)
                    Text("−\(diff.removed)")
                        .foregroundStyle(Theme.textDanger)
                }
                .font(.system(size: 9, weight: .medium))
                .help("Uncommitted line changes")
            }
            if hasTerminal, hovered, !renaming, let onClose {
                rowIconButton("xmark", help: "Close terminal", action: onClose)
            }
        }
        .padding(.leading, nested ? 17 : 0)
        .modifier(RowChrome(
            hovered: hovered, selected: selected, attention: needsAttention
        ))
        // An empty help string attaches no tooltip.
        .help(diffHelp)
    }

    private func finishRename(_ result: String?) {
        guard !renameDone else { return }
        renameDone = true
        onRename?(result)
    }
}

/// The sidebar's inline rename editor. AppKit-backed because SwiftUI's
/// `.plain` text field still lets the field editor draw its focus ring and
/// background box — this one is truly bare: no border, no background, no
/// focus ring, just the row's text selected with a blinking caret.
private struct InlineRenameField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onBlur: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(Theme.text)
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        // Claim focus once mounted; the row was just re-hosted so the
        // window may not exist yet on the first pass. selectAll leaves the
        // whole name highlighted with the live caret, Finder-style.
        func grabFocus(attempts: Int) {
            if let window = field.window, window.makeFirstResponder(field) {
                field.currentEditor()?.selectAll(nil)
                return
            }
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                grabFocus(attempts: attempts - 1)
            }
        }
        DispatchQueue.main.async { grabFocus(attempts: 10) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Don't fight the user's typing — only push the binding's value
        // while the field isn't being edited.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField

        init(_ parent: InlineRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onBlur()
        }
    }
}

extension SidebarRow {
    private var diffHelp: String {
        guard diffTooltipOnly, let diff else { return "" }
        return "+\(diff.added) −\(diff.removed) uncommitted lines"
    }

    fileprivate func rowIconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: nested ? 13 : 16, height: nested ? 13 : 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The sidebar row's leading status dot. Gray = no shell, green = shell
/// open and ready, amber pulse = the agent is working a turn.
struct StatusDot: View {
    // Not named `State` — that shadows SwiftUI's @State attribute.
    enum Kind { case idle, ready, working }
    let state: Kind

    @SwiftUI.State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .frame(width: 16, height: 16)
            .opacity(state == .working && dimmed ? 0.3 : 1)
            .animation(
                state == .working
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.15),
                value: dimmed
            )
            .onAppear { dimmed = state == .working }
            .onChange(of: state) { _, now in dimmed = now == .working }
            .help(help)
    }

    private var color: Color {
        switch state {
        case .idle: Theme.dotIdle
        case .ready: Theme.dotActive
        case .working: Theme.dotDegraded
        }
    }

    private var help: String {
        switch state {
        case .idle: ""
        case .ready: "Terminal open"
        case .working: "Working…"
        }
    }
}

/// The server page, rendered in the right sheet like Git/Skills/Tracked —
/// flat on the sheet's background, filling its width.
struct ServerPanel: View {
    let server: DevServer
    @ObservedObject var share: ShareProxyStore
    @ObservedObject var relay: RelayTunnelStore
    var health: ServerHealth? = nil
    var onOpenTerminal: () -> Void = {}
    /// Sheet chrome, embedded in the panel's own header per the design —
    /// the server sheet hides the shared controls bar.
    var docked: Bool = false
    var onTogglePin: () -> Void = {}
    var onClose: () -> Void = {}
    /// Set when the panel is a pushed page (the menubar popover) instead of
    /// the right sheet: a back chevron leads the title and the sheet's
    /// pin/close controls come off.
    var onBack: (() -> Void)? = nil

    /// In-sheet drill-down: the project's change list replaces the server
    /// page until its back button pops it.
    @State private var showingChangeList = false
    /// Drafts for the web-share section: the Pro token paste field and the
    /// 4-digit viewer code, committed on submit.
    @State private var tokenDraft = ""
    @State private var pinDraft = ""
    /// The viewer-code field is revealed ("+" pressed) but not yet saved.
    @State private var pinEditing = false
    @FocusState private var pinFocused: Bool
    /// The Wi-Fi link's QR popover.
    @State private var showQR = false
    @State private var stopHovered = false

    var body: some View {
        if showingChangeList, let cwd = server.cwd {
            changeList(cwd: cwd)
        } else {
            serverContent
        }
    }

    private func changeList(cwd: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ControlIconButton(
                    systemName: "chevron.left",
                    help: "Back to server",
                    bare: true,
                    circleSize: 32,
                    action: { showingChangeList = false }
                )
                Text("Tasks")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if onBack == nil { pinCloseControls }
            }
            AnnotationsSheetPanel(
                store: AnnotationStores.store(for: cwd),
                projectPath: cwd
            )
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Health dot + name left, sheet controls right — one line.
            // Everything an operator might dig for (command, pid, port,
            // path) lives in the tooltip: this page's job is open / edit /
            // share / stop, not ops trivia.
            // Title lockup: health dot + name. The URL moved into the
            // "On this Mac" access row — one home per link.
            HStack(spacing: 8) {
                if let onBack {
                    ControlIconButton(
                        systemName: "chevron.left",
                        help: "Back to servers",
                        bare: true,
                        circleSize: 32,
                        action: onBack
                    )
                }
                HStack(spacing: 7) {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 8, height: 8)
                    Text(displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .help(details)
                Spacer(minLength: 8)
                moreMenu
                if onBack == nil { pinCloseControls }
            }

            // Sections separate by air alone.
            editAndTrack
                .padding(.top, 16)
            access
                .padding(.top, 26)

            Spacer(minLength: 24)

            // Stop lives alone at the drawer's foot — full width, tinted
            // red, away from everything a stray click could hit.
            Button(action: { Actions.killPid(server.pid) }) {
                HStack(spacing: 7) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text("Stop Server")
                        .font(Theme.Fonts.title)
                }
                .foregroundStyle(Theme.textDanger)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .fill(Theme.closeRed.opacity(stopHovered ? 0.15 : 0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusFloat))
            }
            .buttonStyle(.plain)
            .onHover { stopHovered = $0 }
            .help("Stops the dev server (pid \(String(server.pid)))")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Secondary actions tucked behind an ellipsis beside the pin.
    private var moreMenu: some View {
        Menu {
            Button("Open in Browser") { Actions.openExternal(server.url) }
            if server.cwd != nil {
                Button("Open Terminal", action: onOpenTerminal)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    /// "hierarch" the folder reads as "Hierarch" the app — title case for
    /// the page header only; links and rows keep the literal name.
    private var displayName: String {
        let name = server.project ?? server.command
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// The tooltip behind the health pill: the full verdict plus the facts
    /// the page no longer prints.
    private var details: String {
        var lines = [healthLabel, "\(server.command) · pid \(server.pid) · port \(String(server.port))"]
        if let cwd = server.cwd { lines.append(cwd) }
        return lines.joined(separator: "\n")
    }

    /// True once the proxy is actually answering — what lights up the
    /// pretty `.local` URL in the Wi-Fi row. The "On this Mac" row shows
    /// the raw `localhost:<port>` on purpose: no masked name unless a
    /// deliberate action turns one on.
    private var shareReady: Bool { share.enabled && share.running }

    /// Pin + close, shared by the server header and the change-list header.
    private var pinCloseControls: some View {
        HStack(spacing: 4) {
            ControlIconButton(
                systemName: docked ? "pin.slash" : "pin",
                help: docked ? "Float over the content" : "Dock beside the content",
                bare: true,
                circleSize: 32,
                action: onTogglePin
            )
            ControlIconButton(
                systemName: "xmark",
                help: "Close",
                circleSize: 32,
                action: onClose
            )
        }
    }

    /// The Preview & Edit tier: the web editor window, and the project's
    /// change list (drills down in place).
    /// The project's change list. The web editor itself moved up into the
    /// "Open in Inspector" access row.
    @ViewBuilder
    private var previewEdit: some View {
        if let cwd = server.cwd {
            ChangeListCard(store: AnnotationStores.store(for: cwd)) {
                showingChangeList = true
            }
        }
    }

    /// The two tiers that put the app on OTHER screens, each its own
    /// labeled toggle row: Wi-Fi sharing (live — the URL field discloses
    /// under it) and the public link (relay-backed, coming soon, disabled).
    /// The three ways to view this server, one line item each: on this
    /// Mac (localhost), on the Wi-Fi (`.local` via the share proxy), and
    /// on the web (the relay live link). Same row anatomy throughout:
    /// icon + title + trailing control, detail indented underneath.
    /// "Edit and track": the web editor and the project's change list,
    /// as matching cards.
    private var editAndTrack: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Edit and track")
            ActionCard(
                icon: "cursorarrow.rays",
                title: "Open in Inspector",
                subtitle: "Inspect elements and edit with Claude.",
                trailing: .redirect,
                action: { PreviewWindowController.present(server: server) }
            )
            previewEdit
        }
    }

    /// "View & Share": the three ways to reach the server, each a plain
    /// label (with its toggle where sharing is optional) over a
    /// code-styled URL field whose action button lives inside the field.
    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("View & Share")
                .padding(.bottom, -4)

            VStack(alignment: .leading, spacing: 8) {
                rowLabel("Open in the browser")
                urlField(server.url) {
                    Button(action: { Actions.openExternal(server.url) }) {
                        SVGIcon(name: "redirect", size: 18)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in your browser")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    rowLabel("Any device on your Wi-Fi")
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { share.enabled },
                        set: { share.setEnabled($0) }
                    ))
                    .toggleStyle(PanelSwitchStyle())
                }
                if shareReady {
                    let lanURL = share.lanURL(forProjectNamed: server.project ?? server.command)
                    urlField(lanURL) {
                        Button(action: { showQR = true }) {
                            HStack(spacing: 5) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 13, weight: .medium))
                                Text("View QR")
                                    .font(Theme.Fonts.bodyMedium)
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show a QR code phones can scan")
                        .popover(isPresented: $showQR, arrowEdge: .bottom) {
                            QRCodePopover(url: lanURL)
                        }
                    }
                    if share.port != ShareProxyStore.defaultPort {
                        caption("Port 80 was busy — links carry :\(String(share.port ?? 0)).")
                    }
                } else if share.enabled {
                    caption("Starting the share proxy…")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    rowLabel("Live link on the web")
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { relay.isEnabled(projectLabel) },
                        set: { relay.setEnabled(projectLabel, $0) }
                    ))
                    .toggleStyle(PanelSwitchStyle())
                    .disabled(relay.token.isEmpty)
                    .opacity(relay.token.isEmpty ? 0.45 : 1)
                }
                webDetail
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .kerning(1.1)
            .foregroundStyle(Theme.textSecondary)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.text)
    }

    /// A share URL in code dress: monospaced in a borderless filled field
    /// with its action controls living inside. The address itself opens
    /// the link.
    private func urlField<Trailing: View>(
        _ url: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Text(
                url
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
            )
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.middle)
            .onTapGesture { Actions.openExternal(url) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(Theme.gitPanelFill))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// This project's label in relay/proxy routing terms.
    private var projectLabel: String {
        ShareProxyStore.label(for: server.project ?? server.command)
    }

    /// Tier 3 detail: the public `https://<name>.gohouston.live` link.
    /// Locked behind the Pro token; the relay enforces everything
    /// server-side.
    @ViewBuilder
    private var webDetail: some View {
        if relay.token.isEmpty {
            caption("Needs a Houston Pro token.")
            HStack(spacing: 8) {
                TextField("Paste token (hstn_…)", text: $tokenDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.mono)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.gitPanelFill))
                    .onSubmit(saveToken)
                PanelChromeButton(action: saveToken) { Text("Save") }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else if relay.tokenRejected {
            Text("The relay rejected this token — it may have been revoked.")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textDanger)
        } else if let other = relay.portConflicts[projectLabel] {
            InlineNotice(
                kind: .error,
                title: "Two servers on one port",
                message: "This server and \(other) share port \(String(server.port)). Move one to its own port to share it live."
            )
        } else if relay.isEnabled(projectLabel) {
            switch relay.states[projectLabel] {
            case .online(let url):
                urlField(url) {
                    HStack(spacing: 4) {
                        CopyIconButton(text: url, help: "Copy link")
                        if let shareURL = URL(string: url) {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Share the link")
                        }
                    }
                }
                viewerCodeRow
            case .offline:
                caption("Waiting for the dev server…")
            case .connecting, nil:
                caption("Connecting to the relay…")
            }
        } else {
            caption("A public link you can send to anyone.")
        }
    }

    /// The optional 4-digit gate, right-aligned under the live link:
    /// "+ Add access code" reveals the code field; typing the fourth
    /// digit saves on the spot; the floating × clears it.
    private var viewerCodeRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if pinEditing || !relay.pin(for: projectLabel).isEmpty {
                Text("Access code")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Visitors type this on the splash page before the app loads.")
                TextField("----", text: $pinDraft)
                    .textFieldStyle(.plain)
                    .focused($pinFocused)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .kerning(3)
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.gitPanelFill))
                    .onChange(of: pinDraft) { _, new in
                        let clean = String(new.filter(\.isNumber).prefix(4))
                        if clean != new { pinDraft = clean }
                        if clean.count == 4, clean != relay.pin(for: projectLabel) {
                            relay.setPin(projectLabel, clean)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            pinDraft = ""
                            pinEditing = false
                            relay.setPin(projectLabel, "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .background(Circle().fill(Theme.background))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 7, y: -7)
                        .help("Remove the code")
                    }
            } else {
                Button {
                    pinEditing = true
                    pinFocused = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("Add access code")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Require a 4-digit code from visitors")
            }
        }
        .padding(.top, 4)
        .onAppear { pinDraft = relay.pin(for: projectLabel) }
    }

    private func saveToken() {
        let tok = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return }
        relay.setToken(tok)
        tokenDraft = ""
    }

    private var healthColor: Color {
        switch health {
        case .healthy: Theme.dotActive
        case .degraded: Theme.dotDegraded
        case .down: Theme.closeRed
        case nil: Theme.textSecondary
        }
    }

    /// One quiet word beside the dot; the nuance lives in the tooltip.
    private var healthWord: String {
        switch health {
        case .healthy: "Responding"
        case .degraded: "Slow"
        case .down: "Down"
        case nil: "Checking…"
        }
    }

    private var healthLabel: String {
        switch health {
        case .healthy: "Responding"
        case .degraded: "Slow or responding with server errors"
        case .down: "Not responding"
        case nil: "Checking…"
        }
    }
}

/// The server page for a stopped server: gray dot, the project's declared
/// default command (package.json's dev-ish script), an optional port
/// override, and Start — which types the command into the project's
/// terminal. Once the scan sees the new socket, the sheet morphs into the
/// live server page in place.
struct OffServerPanel: View {
    let recent: RecentServer
    /// Ports live dev servers already hold, port → project name. The
    /// guardrail: Start is blocked while the chosen port collides.
    var busyPorts: [Int: String] = [:]
    var docked: Bool = false
    var onTogglePin: () -> Void = {}
    var onClose: () -> Void = {}
    /// Pushed-page mode (the menubar popover): back chevron in, sheet
    /// pin/close controls out. Mirrors `ServerPanel.onBack`.
    var onBack: (() -> Void)? = nil
    /// Runs the finished command line in the project's terminal.
    var onStart: (String) -> Void = { _ in }

    @State private var commandDraft = ""
    @State private var portDraft = ""
    @State private var detected: DevCommandDetect.DefaultCommand?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let onBack {
                        ControlIconButton(
                            systemName: "chevron.left",
                            help: "Back to servers",
                            bare: true,
                            circleSize: 32,
                            action: onBack
                        )
                    }
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.textSecondary)
                            .frame(width: 8, height: 8)
                        Text(displayName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    .help("Not running\n\(recent.projectPath)")
                    Spacer(minLength: 8)
                    if onBack == nil {
                        HStack(spacing: 4) {
                            ControlIconButton(
                                systemName: docked ? "pin.slash" : "pin",
                                help: docked ? "Float over the content" : "Dock beside the content",
                                bare: true,
                                circleSize: 32,
                                action: onTogglePin
                            )
                            ControlIconButton(
                                systemName: "xmark",
                                help: "Close",
                                circleSize: 32,
                                action: onClose
                            )
                        }
                    }
                }
                Text("Not running · was localhost:" + String(recent.port))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Start server")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text)
                if let detected {
                    // What the project itself declares — the command runs
                    // this script.
                    Text("Default for this project: \(detected.script)")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                TextField(
                    detected == nil ? "npm run dev" : "",
                    text: $commandDraft
                )
                .textFieldStyle(.plain)
                .font(Theme.Fonts.mono)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.gitPanelFill))
                .onSubmit(startNow)
                HStack(spacing: 8) {
                    TextField(String(recent.port), text: $portDraft)
                        .textFieldStyle(.plain)
                        .font(Theme.Fonts.mono)
                        .padding(.horizontal, 10)
                        .frame(width: 76, height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.gitPanelFill))
                        .onSubmit(startNow)
                        .help("Port to run on — leave empty to use the project's own")
                    Text("port")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    PanelChromeButton(action: startNow) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.dotActive)
                            Text("Start")
                        }
                    }
                    .disabled(startBlocked)
                    .opacity(startBlocked ? 0.5 : 1)
                    .help(
                        conflictProject != nil
                            ? "That port is already serving — pick another"
                            : "Runs the command in this project's terminal"
                    )
                }
                if let conflictProject {
                    // The guardrail: same-port launches mostly fail or shadow
                    // each other, so Start stays off until the port is free.
                    HStack(spacing: 6) {
                        Text("Port \(String(effectivePort)) is already in use by \(conflictProject).")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textDanger)
                        LinkButton(title: "Use \(String(nextFreePort)) instead", size: 11) {
                            portDraft = String(nextFreePort)
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            detected = DevCommandDetect.detect(projectPath: recent.projectPath)
            commandDraft = detected?.command ?? ""
        }
    }

    /// Same title-casing as the live page.
    private var displayName: String {
        guard let first = recent.name.first else { return recent.name }
        return first.uppercased() + recent.name.dropFirst()
    }

    private var finalCommand: String {
        let base = commandDraft.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return "" }
        let usesVite = detected?.usesVite ?? base.contains("vite")
        return DevCommandDetect.apply(port: portDraft, to: base, usesVite: usesVite)
    }

    /// The port this launch will land on: the field's value, or the
    /// server's last port when the field is empty (the best guess Houston
    /// has for what the project will pick on its own).
    private var effectivePort: Int {
        Int(portDraft.trimmingCharacters(in: .whitespaces)) ?? recent.port
    }

    /// Who holds the effective port right now, if anyone.
    private var conflictProject: String? { busyPorts[effectivePort] }

    private var nextFreePort: Int {
        var port = effectivePort
        repeat { port += 1 } while busyPorts[port] != nil
        return port
    }

    private var startBlocked: Bool {
        finalCommand.isEmpty || conflictProject != nil
    }

    private func startNow() {
        let command = finalCommand
        guard !command.isEmpty, conflictProject == nil else { return }
        onStart(command)
    }
}

/// The server page's switch, drawn to the Figma design (node 511:7): a
/// capsule track with a sliding knob that goes green when on — replaces
/// the system `.switch` style, whose tint/metrics can't match the file.
struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.switchTrackOn : Theme.switchTrack)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(
            .spring(response: 0.25, dampingFraction: 0.85),
            value: configuration.isOn
        )
    }
}

/// A full-width clickable row-card for the server page's Preview & Edit
/// tier, in the icon-tile pattern: leading glyph tile, title + subtitle,
/// and a trailing affordance that says what the click does — the redirect
/// glyph for "opens a window", a chevron for "drills into this sheet".
/// The affordance sits at 40% until the card is hovered.
private struct ActionCard: View {
    enum Trailing {
        case redirect, chevron
    }

    let icon: String
    let title: String
    let subtitle: String
    var trailing: Trailing = .redirect
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSurface)
                            .fill(Theme.buttonFill)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailingGlyph
                    .opacity(hovered ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 72)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusFloat)
                    .fill(Theme.gitPanelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .fill(hovered ? Theme.cardHovered : .clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusFloat))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var trailingGlyph: some View {
        switch trailing {
        case .redirect:
            SVGIcon(name: "redirect", size: 20)
                .foregroundStyle(Theme.text)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
    }
}

/// The url field's Copy chip — link-blue label that confirms with a beat
/// of "Copied".
private struct CopyChipButton: View {
    let text: String

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
            Text(copied ? "Copied" : "Copy")
                .font(Theme.Fonts.secondaryMedium)
                .foregroundStyle(copied ? Theme.textPositive : Theme.link)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(Theme.buttonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusControl)
                                .fill(hovered ? Theme.cardHovered : .clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Copy link")
    }
}

/// The Tasks card — its own view because the count comes from the
/// project's AnnotationStore, a nested ObservableObject the panel wouldn't
/// otherwise re-render for.
private struct ChangeListCard: View {
    @ObservedObject var store: AnnotationStore
    let action: () -> Void

    var body: some View {
        ActionCard(
            icon: "checklist",
            title: "Tasks",
            subtitle: subtitle,
            trailing: .chevron,
            action: action
        )
        .help("Tasks saved from the web preview")
    }

    private var subtitle: String {
        switch store.open.count {
        case 0: "Nothing queued yet"
        case 1: "1 change queued for Claude"
        case let n: "\(n) changes queued for Claude"
        }
    }
}

/// A rounded chrome button for the server page — the Figma design's pill
/// buttons (tinted fill, borderless), used both standalone and nested in
/// cards.
struct PanelChromeButton<Label: View>: View {
    var height: CGFloat = 30
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Theme.buttonFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
        )
        .onHover { hovered = $0 }
    }
}

struct ServerRow: View {
    let name: String
    let port: Int
    /// Last probe verdict; nil until the first probe lands.
    var health: ServerHealth? = nil
    /// Green glyph while the socket is live, gray for a stopped (recent)
    /// server row.
    var running: Bool = true
    var hovered: Bool = false
    var selected: Bool = false

    init(
        server: DevServer, health: ServerHealth? = nil,
        hovered: Bool = false, selected: Bool = false
    ) {
        name = server.project ?? server.command
        port = server.port
        self.health = health
        running = true
        self.hovered = hovered
        self.selected = selected
    }

    init(recent: RecentServer, hovered: Bool = false) {
        name = recent.name
        port = recent.port
        health = nil
        running = false
        self.hovered = hovered
        selected = false
    }

    var body: some View {
        HStack(alignment: running ? .top : .center, spacing: 8) {
            ServerGlyph(
                color: running ? Theme.dotActive : Theme.textSecondary,
                size: 13
            )
            .help(healthHelp)
            .padding(.top, running ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(running ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                // A stopped server has no URL to visit — the address line
                // is live rows only. String(...) not "\(port)" —
                // interpolating an Int applies locale digit grouping and
                // renders "localhost:3,000".
                if running {
                    Text("localhost:" + String(port))
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .modifier(RowChrome(hovered: hovered, selected: selected))
    }

    private var healthHelp: String {
        guard running else { return "Not running — click for start options" }
        switch health {
        case .healthy: return "Responding"
        case .degraded: return "Slow or responding with server errors"
        case .down: return "Not responding"
        case nil: return "Checking…"
        }
    }
}

/// Section-header "+": a 16pt glyph in a 20pt hit area, far right of the
/// label.
/// A quiet hover icon on a project header row — no chrome of its own, the
/// row's hover pill is the backdrop.
private struct RowActionIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .frame(width: 18, height: 18)
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

private struct HeaderPlusButton: View {
    var icon: String = "plus"
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? Theme.text : Theme.heading)
                .frame(width: 16, height: 16)
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

/// The footer gear: quiet glyph that gets the row-hover fill under the
/// pointer.
private struct GearLabel: View {
    var labeled: Bool = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.system(size: labeled ? 13 : 12))
                .foregroundStyle(labeled
                    ? Theme.text
                    : (hovered ? Theme.text : Theme.heading))
            if labeled {
                // Matches FooterLabeledButton's labeled style — the top
                // cluster reads as one set.
                Text("Settings")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, labeled ? 6 : 0)
        .frame(width: labeled ? nil : 22, height: labeled ? 26 : 22)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(hovered ? Theme.rowHovered : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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

/// The terminal-theme picker: `SearchableMenuList` over ghostty's catalog,
/// Houston's design default pinned first, recents from settings. Each row
/// carries a swatch in the theme's own background/foreground so the list
/// can be scanned without applying anything.
private struct TerminalThemePicker: View {
    let current: String
    let recents: [String]
    let select: (String) -> Void

    /// "" is Houston's design default — pinned first, never in Recents.
    private struct Option: Identifiable {
        let name: String
        let title: String
        let background: Color
        let foreground: Color
        var id: String { name }
    }

    private static let houston = Option(
        name: "",
        title: "Houston",
        background: Color(light: 0xE0E0E0, dark: 0x181818),
        foreground: Color(light: 0x111111, dark: 0xE8E8E8)
    )

    private static func option(for theme: GhosttyThemeDefinition) -> Option {
        Option(
            name: theme.name,
            title: theme.name,
            background: Color(themeHex: theme.background),
            foreground: Color(themeHex: theme.foreground)
        )
    }

    var body: some View {
        SearchableMenuList(
            items: [Self.houston] + GhosttyThemeCatalog.allThemes.map(Self.option(for:)),
            recents: recents.compactMap { name in
                GhosttyThemeCatalog.theme(named: name).map(Self.option(for:))
            },
            allTitle: "All Themes",
            matches: { option, query in
                option.title.localizedCaseInsensitiveContains(query)
            },
            select: { select($0.name) }
        ) { option in
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(option.background)
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    Text("A")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(option.foreground)
                }
                .frame(width: 18, height: 18)
                Text(option.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if option.name == current {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
        }
    }
}

private extension Color {
    /// Ghostty catalog colors are hex strings ("1d1f21", with or without a
    /// leading #).
    init(themeHex: String) {
        let hex = themeHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(hex: UInt32(hex, radix: 16) ?? 0)
    }
}
