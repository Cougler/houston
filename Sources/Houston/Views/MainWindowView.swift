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

/// What the right sheet can show — Git, Skills, Tracked, the notification
/// feed, or a dev server (by `DevServer.id`). One sheet, so the panels are
/// exclusive by construction.
enum RightPanel: Equatable {
    case git, skills, tracked, feed, tasks
    case server(String)
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
    @StateObject private var share = ShareProxyStore()
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
        .background(Theme.background)
        .overlay(alignment: .topLeading) { railFlyoutLayer }
        .overlay(alignment: .bottomLeading) { themePickerLayer }
        .overlay(alignment: .topTrailing) { rightSheetLayer }
        .overlay {
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
        .onChange(of: servers.devServers) { _, list in share.update(servers: list) }
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .houstonOpenProject)) { note in
            if let path = note.userInfo?["path"] as? String {
                select(.project(path))
            }
        }
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
            Color.clear.frame(height: trafficLightInset)
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
                onEmptyClick: { closeFloatingSheet() }
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
            }
            // Too narrow for the expanded footer's rows — bare icons stacked
            // in the same order: bell, calendar, gear, collapse.
            FooterLabeledButton(
                systemName: "bell",
                badgeCount: feed.unreadCount,
                active: rightPanel == .feed,
                help: "Notifications",
                action: { toggleRightPanel(.feed) }
            )
            FooterLabeledButton(
                systemName: "calendar",
                dot: tracked.attentionCount > 0,
                active: rightPanel == .tracked,
                help: "Reminders",
                action: { toggleRightPanel(.tracked) }
            )
            FooterLabeledButton(
                systemName: "checklist",
                active: rightPanel == .tasks,
                help: "Tasks across all projects",
                action: { openAllTasks() }
            )
            settingsMenu()
            // Same short rule as the expanded footer, centered on the rail.
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
            FooterIconButton(
                systemName: "sidebar.left",
                help: "Expand sidebar",
                action: toggleSidebarCollapse
            )
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.panelFill)
                            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.panelFill)
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
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

    // MARK: - Right sheet

    /// The uniform card width inside the sheet; the strip adds its gutters.
    private var rightSheetWidth: CGFloat { 364 }

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
        case .git, .tracked, .server, .tasks:
            break
        }
    }

    private func closeRightPanel() {
        withAnimation(sheetSpring) { rightPanel = nil }
    }

    /// Open the tasks sheet at its All Tasks root (the footer checklist),
    /// or close it if that's already showing.
    private func openAllTasks() {
        if rightPanel == .tasks && taskSheetProject == nil {
            closeRightPanel()
            return
        }
        taskSheetProject = nil
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
                    Text(rightSheetTitle)
                        .font(.system(size: 10))
                        .kerning(0.5)
                        .foregroundStyle(Theme.heading)
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
                .padding(.horizontal, 12)
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
    }

    /// What the sheet renders: the open panel, or the last one while the
    /// close animation runs.
    private var effectiveRightPanel: RightPanel? { rightPanel ?? lastRightPanel }

    private var serverChromeHidden: Bool {
        if case .server = effectiveRightPanel { return true }
        return false
    }

    private var rightSheetTitle: String {
        switch effectiveRightPanel {
        case .git: "GIT"
        case .skills: "SKILLS"
        case .tracked: "REMINDERS"
        case .feed: "NOTIFICATIONS"
        case .server: "SERVER"
        case .tasks: taskSheetProject == nil ? "ALL TASKS" : "TASKS"
        case nil: ""
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
        case .tracked:
            TrackedPanel(store: tracked)
        case .tasks:
            TasksNavigator(
                projectPath: taskSheetProject,
                onOpenProject: { taskSheetProject = $0 },
                onBack: { taskSheetProject = nil }
            )
        case let .server(sid):
            if let server = servers.devServers.first(where: { $0.id == sid }) {
                ServerPanel(
                    server: server,
                    share: share,
                    health: servers.health[sid],
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
            } else {
                rightSheetPlaceholder("This server is no longer listening.")
            }
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
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Aligns the flyout's top edge with the rail button that opened it —
    /// the buttons stack at `trafficLightInset` in 30pt + 6pt-spacing steps.
    private func flyoutTop(for section: RailSection) -> CGFloat {
        let index: CGFloat = switch section {
        case .terminals: 0
        case .servers: 1
        case .projects: 2
        }
        return trafficLightInset + index * 36
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
                    .font(.system(size: 10))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            if let subtext {
                Text(subtext)
                    .font(.system(size: 11))
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
    private var projectsPopover: some View {
        let pinned = store.pinnedProjects
        let groups = store.projectGroups
        let libCount = groups.reduce(0) { $0 + libraryPaths(in: $1).count }
        let empty = pinned.isEmpty && groups.isEmpty
        let rowsHeight = empty
            ? railEmptyStateHeight
            : CGFloat(pinned.count) * 28
                + CGFloat(groups.count) * 28
                + CGFloat(libCount) * 28
        return railPopoverPanel(
            title: "Projects",
            count: pinned.count + libCount,
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
            }
            ForEach(groups, id: \.path) { group in
                // Folder names read as sub-headings here — the popover has
                // no disclosure, so the quiet heading style keeps them from
                // competing with the project rows.
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.heading)
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.heading)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12 + Theme.rowInset)
                .frame(height: 24)
                .padding(.top, 4)
                ForEach(libraryPaths(in: group), id: \.self) { path in
                    projectPopoverRow(path)
                }
            }
        } footer: {
            railPopoverFooter("Add Project…") {
                setRailPopover(nil)
                addFolder()
            }
        }
    }

    private func projectPopoverRow(_ path: String) -> some View {
        PopoverRow(height: 28, action: { railSelect(.project(path)) }) { hovered in
            SidebarRow(
                name: name(of: path),
                diff: libraryDiff(path),
                isProject: ProjectKindCache.isProject(path),
                live: terminals.hasPane(for: path),
                hovered: hovered
            )
        }
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

    /// Prompts for a terminal row's new name; empty input restores the
    /// directory-based default.
    private func renameTerminal(path: String, tabID: UUID) {
        let current = terminals.tabs[path]?
            .first { $0.id == tabID }?.customName ?? ""
        guard let name = promptForText(
            title: "Rename Terminal",
            message: "Shown in the sidebar. Leave empty to restore the default name.",
            placeholder: current.isEmpty ? self.name(of: path) : current
        ) else { return }
        terminals.renameTab(path: path, tabID: tabID, to: name)
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
        default: break
        }
    }

    /// Shared chrome for the "+ New" / "+ Add" rows.
    private func actionRowLabel(title: String, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .modifier(RowChrome(hovered: hovered, selected: false))
        .contentShape(Rectangle())
    }


    private var sidebarFooter: some View {
        // One row of bare icons: collapse first, then Settings, Reminders,
        // Notifications — the same order the rail stacks upward from its
        // collapse button.
        HStack(spacing: 2) {
            FooterIconButton(
                systemName: "sidebar.left",
                help: "Collapse sidebar",
                action: toggleSidebarCollapse
            )
            settingsMenu()
            FooterLabeledButton(
                systemName: "checklist",
                active: rightPanel == .tasks,
                help: "Tasks across all projects",
                action: { openAllTasks() }
            )
            FooterLabeledButton(
                systemName: "calendar",
                dot: tracked.attentionCount > 0,
                active: rightPanel == .tracked,
                help: "Reminders",
                action: { toggleRightPanel(.tracked) }
            )
            FooterLabeledButton(
                systemName: "bell",
                badgeCount: feed.unreadCount,
                active: rightPanel == .feed,
                help: "Notifications",
                action: { toggleRightPanel(.feed) }
            )
            if let update = updates.available {
                UpdatePill(version: update.version, busy: installer.isBusy) {
                    installer.requestInstall(update)
                }
                .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Settings

    /// Footer gear: appearance (System/Light/Dark) and the terminal's theme,
    /// straight from ghostty's catalog. A bare glyph in both footer states.
    private func settingsMenu() -> some View {
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

            Divider()

            Section("Status Bar") {
                Toggle("Hide", isOn: statusBarCollapsedBinding)
                Toggle("Disable", isOn: statusBarDisabledBinding)
                Menu("Items") {
                    Toggle("Model", isOn: statusBarItemBinding("model"))
                    Toggle("Context", isOn: statusBarItemBinding("context"))
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
            GearLabel()
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
            // The empty state stands alone — no title bar over it.
            if selection != nil {
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
            if let path = selection?.projectPath, terminals.hasPane(for: path),
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
                            .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 12, weight: .medium))
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

        // The project's tasks — the queue built from the web preview's and
        // the App Inspector's "Add to Tasks", plus manual entries. Opens
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
                    .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 12, weight: .medium))
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
        switch selection {
        case let .project(path), let .shell(path, _):
            if terminals.hasPane(for: path) {
                // Inset from the right so the chrome wraps the terminal,
                // with the surface itself rounded off. The panels that used
                // to float here live in the right sheet now.
                TerminalHostView(path: path, tabID: selection?.tabID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.trailing, 16)
                    .padding(.bottom, 6)
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
    /// detail states read as the same surface swapping content. The 30pt
    /// top/bottom insets leave chrome rails above and below the card — the
    /// title bar's and status bar's bands, kept even with nothing in them.
    private var emptyState: some View {
        // While the sidebar is hidden for onboarding, the sky holds the
        // welcome screen's 56pt lift so the dismissal crossfade lands on an
        // already-aligned solar system; the reveal spring then glides it
        // down to center as the sidebar slides in.
        EmptyStateView(skyLift: sidebarRevealed ? 0 : -56)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.top, 30)
            .padding(.trailing, 16)
            .padding(.bottom, 30)
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
        out.append(.header("Terminals"))
        // The section never vanishes: with nothing open, the "New Terminal"
        // affordance stands in for the first row (same 32pt, so the sections
        // below don't jump when it's swapped for a real terminal).
        if terminalPaths.isEmpty {
            // Just "New" — it sits under the TERMINALS header, which already
            // says what it makes.
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
        if !servers.devServers.isEmpty {
            out.append(.header("Servers"))
            out += servers.devServers.map {
                .row(id: .server($0.id), title: $0.project ?? $0.command)
            }
        }
        // Projects is the stable library: rows never leave it when a project
        // runs — a running one turns its glyph green and is *mirrored* under
        // Terminals, so nothing jumps sections and spatial memory holds.
        // Pinned single projects get their own rows; a folder of projects is
        // a collapsible parent. "Add" browses for either.
        out.append(.header("Projects"))
        out += store.pinnedProjects.map { .library(path: $0, title: name(of: $0)) }
        for group in store.projectGroups {
            out.append(.folder(path: group.path, name: group.name))
            if !collapsedFolders.contains(group.path) {
                out += libraryPaths(in: group).map {
                    .library(path: $0, title: name(of: $0))
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
            // The space above the bottom-aligned label IS the gap between
            // sections; just tall enough for the "+" button's hit area.
            return 20
        case .folder:
            return 24
        case let .action(key, _):
            // "New" stands in for the first terminal row — same height as one
            // (28pt), so the sections below don't jump when it's swapped out.
            return key == "new-terminal" ? 28 : 24
        case .library:
            return 26
        case let .row(id, _):
            if case .server = id { return 38 }
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
                    .font(.system(size: 10))
                    .kerning(0.5)
                    .foregroundStyle(Theme.heading)
                    .padding(.bottom, 4)
                Spacer(minLength: 0)
                if title == "Terminals" {
                    HeaderPlusButton(help: "New terminal") {
                        let home = NSHomeDirectory()
                        if terminals.hasPane(for: home),
                           let tab = terminals.newTab(in: home) {
                            select(.shell(path: home, tab: tab.id))
                        } else {
                            select(.project(home))
                        }
                    }
                } else if title == "Projects" {
                    HeaderPlusButton(help: "Add a project or folder") {
                        addFolder()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 10)
            .padding(.trailing, 6)

        case let .action(key, title):
            if key == "open-folder" {
                // Two ways in: a local folder, or a fresh clone.
                Menu {
                    Button("Add Folder…") { addFolder() }
                    Button("Clone Repository…") { cloneRepository() }
                } label: {
                    actionRowLabel(title: title, hovered: hovered)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            } else {
                actionRowLabel(title: title, hovered: hovered)
                    .onTapGesture { runAction(key) }
            }

        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            HStack(spacing: 8) {
                // The disclosure chevron takes the folder glyph's place under
                // the pointer — Finder's sidebar move — instead of sitting
                // permanently at the row's far edge.
                Image(systemName: hovered
                    ? (collapsed ? "chevron.right" : "chevron.down")
                    : (collapsed ? "folder" : "folder.fill"))
                    .font(hovered
                        ? .system(size: 10, weight: .semibold)
                        : .system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                Text(folderName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .modifier(RowChrome(hovered: hovered, selected: false))
            .onTapGesture { toggleFolder(path) }

        case let .library(path, title):
            // The library never carries the selection highlight — that lives
            // on the project's Terminals mirror. Git state rides as subtext.
            SidebarRow(
                name: title,
                diff: libraryDiff(path),
                diffTooltipOnly: sidebarNarrow,
                isProject: ProjectKindCache.isProject(path),
                live: terminals.hasPane(for: path),
                hovered: hovered
            )

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
                    needsAttention: notify.hasAttention(path: path),
                    hovered: hovered,
                    selected: selection == id,
                    onClose: { closeTerminal(path) }
                )
            case let .shell(path, tabID):
                SidebarRow(
                    name: title,
                    agent: shellAgent(path: path, tab: tabID),
                    hasTerminal: true,
                    gitStatus: git.rowStatuses[path] ?? .none,
                    needsAttention: notify.hasAttention(path: path, tab: tabID),
                    hovered: hovered,
                    selected: selection == id,
                    onClose: { terminals.closeTab(path: path, tabID: tabID) }
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
        case let .action(key, _):
            return "a:\(key)|\(hovered ? "h" : "-")"
        case let .folder(path, folderName):
            let collapsed = collapsedFolders.contains(path)
            return "f:\(folderName)|\(collapsed ? "c" : "-")|\(hovered ? "h" : "-")"
        case let .library(path, title):
            let diff = libraryDiff(path).map { "+\($0.added)-\($0.removed)" } ?? "-"
            return [
                "lib", title, diff,
                sidebarNarrow ? "n" : "-",
                terminals.hasPane(for: path) ? "t" : "-",
                ProjectKindCache.isProject(path) ? "p" : "-",
                hovered ? "h" : "-",
            ].joined(separator: "|")
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
                    notify.hasAttention(path: path) ? "!" : "-",
                    selected ? "s" : "-",
                    hovered ? "h" : "-",
                ].joined(separator: "|")
            case let .shell(path, tab):
                let agent = shellAgent(path: path, tab: tab)?.label ?? "-"
                let status = String(describing: git.rowStatuses[path] ?? .none)
                let bang = notify.hasAttention(path: path, tab: tab) ? "!" : "-"
                return "sh:\(title)|\(tab)|\(agent)|\(status)|\(bang)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")"
            case let .server(sid):
                let port = servers.devServers.first { $0.id == sid }.map { String($0.port) } ?? "-"
                let health = servers.health[sid].map { String(describing: $0) } ?? "-"
                // The row stays lit while its sheet panel is open — that
                // state must be in the key or the highlight never updates.
                let state = rightPanel == .server(sid) ? "P" : (hovered ? "h" : "-")
                return "\(title)|\(port)|\(health)|\(state)"
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
            menu.addItem(ClosureMenuItem("New Terminal Here") {
                if let tab = terminals.newTab(in: path) {
                    select(.shell(path: path, tab: tab.id))
                }
            })
            menu.addItem(ClosureMenuItem("Rename…") {
                renameTerminal(path: path, tabID: tabID)
            })
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
                menu.addItem(ClosureMenuItem("Start Claude") { terminals.start(.claude, in: path) })
                menu.addItem(ClosureMenuItem("New Terminal Here") {
                    if let tab = terminals.newTab(in: path) {
                        select(.shell(path: path, tab: tab.id))
                    }
                })
                menu.addItem(ClosureMenuItem("Rename…") {
                    if let tabID = terminals.tabs[path]?.first?.id {
                        renameTerminal(path: path, tabID: tabID)
                    }
                })
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
                    RoundedRectangle(cornerRadius: 7)
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
private struct FooterLabeledButton: View {
    let systemName: String
    var label: String? = nil
    var badgeCount: Int = 0
    var dot: Bool = false
    var active: Bool = false
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 12))
                    .foregroundStyle(hovered || active ? Theme.text : Theme.heading)
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hovered || active ? Theme.text : Theme.heading)
                    badge
                }
            }
            .padding(.horizontal, label == nil ? 0 : 6)
            .frame(width: label == nil ? 22 : nil, height: 22)
            // Badge INSIDE the button's frame, not overhanging the glyph —
            // an ancestor clips at the frame edge and was slicing the pill.
            .overlay(alignment: .topTrailing) {
                if label == nil { badge }
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
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

// MARK: - Header button chrome

/// The design's header buttons: 30pt tall, #F3F3F3 fill, #E0E0E0 hairline,
/// 6pt radius. Also used by the empty state's quick-open buttons.
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
                    .font(.system(size: 12, weight: .medium))
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
        .help("Tasks saved from the web preview and App Inspector")
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
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        active ? Theme.buttonActiveStroke : Theme.buttonStroke,
                        lineWidth: active ? 2 : 1
                    )
            )
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
                RoundedRectangle(cornerRadius: 8)
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
    var gitStatus: GitRowStatus = .none
    /// The session is waiting on the user (permission prompt, idle, or a
    /// finished turn) — rose wash over the whole row until viewed.
    var needsAttention: Bool = false
    var hovered: Bool = false
    var selected: Bool = false
    /// Close action for a live terminal row — while hovered, an ✕ takes the
    /// terminal icon's place.
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Active rows lead with a status avatar: a circle tinted with
            // the row's git state behind a white terminal glyph, and the
            // running agent's logo as a white-backed badge on the circle's
            // lower-right corner. Idle rows lead with a project glyph when
            // they are projects, else indent. Attention is the row itself:
            // a wash drawn by RowChrome.
            if hasTerminal {
                terminalAvatar
            } else if isProject || live {
                // Always quiet gray — the live signal is the mirror row up
                // in Terminals, not this glyph.
                Image(systemName: "shippingbox")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .help(live ? "Terminal open — see Terminals" : "")
            }
            Text(name)
                .font(.system(size: nested ? 12 : 13))
                .foregroundStyle(nested ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
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
            if hasTerminal, hovered, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: nested ? 13 : 16, height: nested ? 13 : 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close terminal")
            }
        }
        .padding(.leading, nested ? 17 : (hasTerminal || isProject || live ? 0 : 17))
        .modifier(RowChrome(
            hovered: hovered, selected: selected, attention: needsAttention
        ))
        // An empty help string attaches no tooltip.
        .help(diffHelp)
    }

    /// The leading status avatar: git state as a translucent wash inside a
    /// solid ring of the same color, the terminal glyph in the solid color
    /// centered on top, and — when an agent is running — its logo as a
    /// badge overhanging the circle's lower-right, cut out by a white
    /// backing circle.
    private var terminalAvatar: some View {
        let size: CGFloat = nested ? 15 : 18
        let badge: CGFloat = nested ? 9 : 11
        return Circle()
            .fill(gitColor.opacity(0.18))
            .overlay(Circle().strokeBorder(gitColor, lineWidth: 1))
            .overlay(
                // Resizable + scaledToFit centers the symbol's box exactly;
                // font-metric layout floats it slightly off-center.
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(gitColor)
                    .frame(width: size * 0.52)
            )
            .frame(width: size, height: size)
            .help(gitHelp)
        .overlay(alignment: .bottomTrailing) {
            if let agent {
                ZStack {
                    Circle().fill(.white)
                    TerminalRowIcon(agent: agent, size: badge - 4)
                }
                .frame(width: badge, height: badge)
                .offset(x: 2.5, y: 2.5)
            }
        }
    }

    private var diffHelp: String {
        guard diffTooltipOnly, let diff else { return "" }
        return "+\(diff.added) −\(diff.removed) uncommitted lines"
    }

    private var gitColor: Color {
        switch gitStatus {
        case .none: Theme.dotShell
        case .dirty: Theme.dotDegraded
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

/// The server page, rendered in the right sheet like Git/Skills/Tracked —
/// flat on the sheet's background, filling its width.
struct ServerPanel: View {
    let server: DevServer
    @ObservedObject var share: ShareProxyStore
    var health: ServerHealth? = nil
    var onOpenTerminal: () -> Void = {}
    /// Sheet chrome, embedded in the panel's own header per the design —
    /// the server sheet hides the shared controls bar.
    var docked: Bool = false
    var onTogglePin: () -> Void = {}
    var onClose: () -> Void = {}

    /// In-sheet drill-down: the project's change list replaces the server
    /// page until its back button pops it.
    @State private var showingChangeList = false

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
                pinCloseControls
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
            // Title with the URL tucked tight beneath it — one lockup.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
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
                    pinCloseControls
                }

                // ONE link — the pretty name while the proxy is up, the raw
                // port URL otherwise. Never both: they open the same app.
                HStack(spacing: 5) {
                    LinkButton(
                        title: primaryURL.replacingOccurrences(of: "http://", with: ""),
                        size: 13
                    ) {
                        Actions.openExternal(primaryURL)
                    }
                    CopyIconButton(text: primaryURL, help: "Copy link")
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                PanelChromeButton(action: { Actions.openExternal(primaryURL) }) {
                    Text("Open in Browser")
                }
                if server.cwd != nil {
                    PanelChromeButton(action: onOpenTerminal) {
                        Text("Open Terminal")
                    }
                }
                Spacer(minLength: 0)
                PanelChromeButton(action: { Actions.killPid(server.pid) }) {
                    HStack(spacing: 5) {
                        // Record-style glyph: red ring around a red dot.
                        ZStack {
                            Circle()
                                .stroke(Theme.closeRed, lineWidth: 1.5)
                                .frame(width: 10, height: 10)
                            Circle()
                                .fill(Theme.closeRed)
                                .frame(width: 4, height: 4)
                        }
                        Text("Stop")
                    }
                }
                .help("Stops the dev server (pid \(String(server.pid)))")
            }

            // Sections separate by air alone — ~36pt with the stack's 16.
            previewEdit
                .padding(.top, 20)
            sharing
                .padding(.top, 20)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// True once the proxy is actually answering — what makes the pretty
    /// URLs live, and what flips the primary link between them and the raw
    /// port form.
    private var shareReady: Bool { share.enabled && share.running }

    /// The one URL this panel opens: pretty when the proxy serves it, raw
    /// `localhost:<port>` when it doesn't.
    private var primaryURL: String {
        shareReady
            ? share.localURL(forProjectNamed: server.project ?? server.command)
            : server.url
    }

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
    private var previewEdit: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview & Edit")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            ActionCard(
                icon: "cursorarrow.rays",
                title: "Web editor",
                subtitle: "Click any element, tell Claude what to change",
                trailing: .redirect,
                action: { PreviewWindowController.present(server: server) }
            )
            if let cwd = server.cwd {
                ChangeListCard(store: AnnotationStores.store(for: cwd)) {
                    showingChangeList = true
                }
            }
        }
    }

    /// The two tiers that put the app on OTHER screens, each its own
    /// labeled toggle row: Wi-Fi sharing (live — the URL field discloses
    /// under it) and the public link (relay-backed, coming soon, disabled).
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Share on your Wi-Fi")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { share.enabled },
                    set: { share.setEnabled($0) }
                ))
                .toggleStyle(PanelSwitchStyle())
            }
            .help("Phone, tablet, or another computer on the same network.")

            if shareReady {
                urlField(share.lanURL(forProjectNamed: server.project ?? server.command))
                if share.port != ShareProxyStore.defaultPort {
                    Text("Port 80 was busy — links carry :\(String(share.port ?? 0)).")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if share.enabled {
                Text("Starting the share proxy…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                Text("Share to the web")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                ComingSoonBadge()
                Spacer()
                Toggle("", isOn: .constant(false))
                    .toggleStyle(PanelSwitchStyle())
                    .disabled(true)
                    .opacity(0.45)
            }
            .padding(.top, 10)
            .help("A public link anyone can open — relay-backed, coming soon.")
        }
    }

    /// The share URL, framed like an input: full address left, a Copy chip
    /// living inside the field.
    private func urlField(_ url: String) -> some View {
        HStack(spacing: 8) {
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            CopyChipButton(text: url)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.gitPanelFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.buttonStroke, lineWidth: 1)
        )
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
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.buttonFill)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailingGlyph
                    .opacity(hovered ? 1 : 0.4)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.panelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(hovered ? Theme.cardHovered : .clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.buttonStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Theme.textPositive : Theme.link)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.buttonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
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
        .help("Tasks saved from the web preview and App Inspector")
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
/// buttons (fill + 1px border), used both standalone and nested in cards.
struct PanelChromeButton<Label: View>: View {
    var height: CGFloat = 30
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.buttonFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.buttonStroke, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}

struct ServerRow: View {
    let server: DevServer
    /// Last probe verdict; nil until the first probe lands.
    var health: ServerHealth? = nil
    var hovered: Bool = false
    var selected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Plain gray like the project rows' glyphs — no status color;
            // a server in the list is either serving or it isn't.
            ServerGlyph(color: Theme.textSecondary, size: 13)
                .help(healthHelp)
                .padding(.top, 1)
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
        }
        .padding(.vertical, 4)
        .modifier(RowChrome(hovered: hovered, selected: selected))
    }

    private var healthHelp: String {
        switch health {
        case .healthy: "Responding"
        case .degraded: "Slow or responding with server errors"
        case .down: "Not responding"
        case nil: "Checking…"
        }
    }
}

/// Section-header "+": a 16pt glyph in a 20pt hit area, far right of the
/// label.
private struct HeaderPlusButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? Theme.text : Theme.heading)
                .frame(width: 16, height: 16)
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

/// The footer gear: quiet glyph that gets the row-hover fill under the
/// pointer.
private struct GearLabel: View {
    @State private var hovered = false

    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 12))
            .foregroundStyle(hovered ? Theme.text : Theme.heading)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(option.background)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    Text("A")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(option.foreground)
                }
                .frame(width: 18, height: 18)
                Text(option.title)
                    .font(.system(size: 12))
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
