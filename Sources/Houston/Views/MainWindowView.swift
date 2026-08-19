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
    @StateObject private var handoffs = HandoffCoordinator()
    @ObservedObject private var terminals = TerminalSessionManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var installer = UpdateInstaller.shared
    @ObservedObject private var notify = NotifyStore.shared
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
    /// The harness selector's popped menu, for its active chrome.
    @State private var agentMenuOpen = false
    @State private var agentMenuBox = MenuAnchorBox()
    /// Mirror of the settings file, for the footer gear's checkmarks.
    @State private var settings = HoustonSettings.read()
    /// The server whose detail popover is open, by `DevServer.id`.
    @State private var serverPopover: String?
    /// Whether Houston's feed script is Claude's configured statusline.
    @State private var statusFeedInstalled = StatusLineFeed.state == .houston
    /// Consent dialog for taking over the Claude statusline.
    @State private var showStatusPrompt = false
    /// Whether Houston's hooks feed notifications (mirrors settings.json).
    @State private var notifyInstalled = NotifyFeed.isInstalled
    /// Consent dialog for installing the notification hooks.
    @State private var showNotifyPrompt = false
    /// The automatic offer fires at most once per launch.
    @State private var statusPromptOffered = false
    /// Project folders currently collapsed, persisted in settings.
    @State private var collapsedFolders = Set(HoustonSettings.read().collapsedFolders)
    /// First-launch welcome overlay, until dismissed once.
    @State private var showWelcome = !HoustonSettings.read().welcomeSeen
    /// Sidebar collapsed to the three-icon rail, persisted in settings.
    @State private var sidebarCollapsed = HoustonSettings.read().sidebarCollapsed
    /// The rail section whose popover is open, while collapsed.
    @State private var railPopover: RailSection?

    /// Clearance for the traffic lights, which float over the sidebar now that
    /// the title bar is transparent and full-size.
    private let trafficLightInset: CGFloat = 48

    /// Sidebar width, dragged by the divider below.
    @State private var sidebarWidth: CGFloat = Theme.sidebarWidth
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
    @State private var detailFrame: CGRect = .zero
    private static let rootSpace = "houston-root"
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
                    .frame(width: railWidth)
            } else {
                sidebarColumn
                    .frame(width: sidebarWidth)
            }
            // One divider for both states, outside the branch so its view —
            // and any drag mid-flight through a collapse/expand — survives
            // the swap.
            splitDivider
            detailColumn
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .coordinateSpace(name: Self.rootSpace)
        .onPreferenceChange(DetailFrameKey.self) { frame in
            Task { @MainActor in detailFrame = frame }
        }
        .overlay(alignment: .topLeading) { railFlyoutLayer }
        .overlay(alignment: .topLeading) { panelOutsideClickScrim }
        .overlay {
            if showWelcome {
                WelcomeView {
                    withAnimation(.easeOut(duration: 0.3)) { showWelcome = false }
                    updateSettings { $0.welcomeSeen = true }
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
            git.start()
            git.watchRows(gitWatchSet)
            statusFeed.start()
            notify.start()
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
        .onChange(of: gitWatchSet) { _, set in git.watchRows(set) }
        // A project's last terminal closing (✕, ⇧⌘W, ctrl-D) lands on the
        // solar-system empty state, not a dead detail page.
        .onChange(of: terminalPaths) { _, paths in
            if case let .project(path) = selection, !paths.contains(path),
               !terminals.hasPane(for: path) {
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            showSkills = false
            showGit = false
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
                            .onEnded { _ in sidebarDragStart = nil }
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

    // MARK: - Collapsed rail

    /// Rail width — the traffic lights end at x=69 (last button 55+14,
    /// measured), and the rail runs 12pt past them so it fully contains the
    /// cluster. That's also what lets the empty-state sky go without a shelf
    /// under the lights.
    private let railWidth: CGFloat = 81

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
            // Same arrangement AND position as the expanded footer — gear,
            // then collapse, left-aligned at the same 14pt inset — so the
            // pair doesn't shift when the sidebar collapses.
            HStack(spacing: 2) {
                settingsMenu
                FooterIconButton(
                    systemName: "sidebar.left",
                    help: "Expand sidebar",
                    action: toggleSidebarCollapse
                )
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Click-away for the floating git/skills panels, covering what their
    /// in-region scrim can't: the sidebar, the header, and the status bar.
    /// Three rectangles around the detail region rather than one sheet over
    /// the window, so the panels themselves (inside the region) stay
    /// clickable. Clicks are consumed — the standard popover bargain.
    @ViewBuilder
    private var panelOutsideClickScrim: some View {
        if showSkills || showGit, detailFrame != .zero {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    // Left of the detail region: sidebar/rail + divider.
                    scrimRect(width: detailFrame.minX, height: g.size.height)
                    // Above it: the header.
                    scrimRect(width: g.size.width - detailFrame.minX,
                              height: detailFrame.minY)
                        .offset(x: detailFrame.minX)
                    // Below it: the status bar.
                    scrimRect(width: g.size.width - detailFrame.minX,
                              height: max(0, g.size.height - detailFrame.maxY))
                        .offset(x: detailFrame.minX, y: detailFrame.maxY)
                }
            }
        }
    }

    private func scrimRect(width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { closeFloatingPanels() }
            .frame(width: max(0, width), height: max(0, height))
    }

    private func closeFloatingPanels() {
        withAnimation(.easeOut(duration: 0.18)) {
            showSkills = false
            showGit = false
        }
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

    /// Chrome shared by the rail popovers: a header with the section's glyph
    /// in a rose-tinted tile and a count badge, the rows (capped at 400pt,
    /// scrolling past that), and an optional pinned action footer.
    private func railPopoverPanel(
        title: String,
        count: Int,
        rowsHeight: CGFloat,
        @ViewBuilder icon: () -> some View,
        @ViewBuilder rows: () -> some View,
        @ViewBuilder footer: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.rowSelected)
                    )
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
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
        .frame(width: 260)
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
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        } rows: {
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
            railPopoverFooter("New Terminal") {
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
            ServerGlyph(color: Theme.textSecondary, size: 13)
        } rows: {
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
                            selected: false,
                            onOpen: { Actions.openExternal(server.url) }
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
            Image(systemName: "shippingbox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        } rows: {
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .modifier(RowChrome(hovered: hovered, selected: false))
        .contentShape(Rectangle())
    }


    private var sidebarFooter: some View {
        // Gear + collapse, tucked into the bottom-left corner — no rule above.
        HStack(spacing: 2) {
            settingsMenu
            FooterIconButton(
                systemName: "sidebar.left",
                help: "Collapse sidebar",
                action: toggleSidebarCollapse
            )
            if let update = updates.available {
                UpdatePill(version: update.version, busy: installer.isBusy) {
                    installer.requestInstall(update)
                }
                .padding(.leading, 4)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
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
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome(active: showGit))
        .help("Git status")

        // Skills only exist inside an agent session, so the button appears
        // with the agent and leaves with it.
        if terminals.agents[path] != nil {
            Button {
                if !showSkills { skills = SkillsCatalog.load(projectPath: path) }
                withAnimation(.easeOut(duration: 0.18)) {
                    showSkills.toggle()
                    showGit = false
                }
            } label: {
                Text("Skills")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(HeaderButtonChrome(active: showSkills))
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
                ZStack(alignment: .topTrailing) {
                    // Inset from the right so the chrome wraps the terminal,
                    // with the surface itself rounded off.
                    TerminalHostView(path: path, tabID: selection?.tabID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.trailing, 16)
                        .padding(.bottom, 6)
                    // Scrim under the floating panels: any click outside a
                    // panel dismisses it (and is consumed, not passed to the
                    // terminal — the standard popover bargain).
                    if showSkills || showGit {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeFloatingPanels() }
                    }
                    // Floats over the terminal; the agent-gate mirrors the
                    // button so the card leaves with the session.
                    if showSkills, terminals.agents[path] != nil {
                        SkillsPanel(
                            skills: skills,
                            onRun: { skill in
                                terminals.send("/\(skill.name)\n", to: path)
                                withAnimation(.easeOut(duration: 0.18)) { showSkills = false }
                            },
                            onInsert: { skill in
                                terminals.send("/\(skill.name) ", to: path)
                                withAnimation(.easeOut(duration: 0.18)) { showSkills = false }
                            }
                        )
                        .padding(12)
                        // Slides down from the header, as if out of the
                        // button that opened it.
                        .transition(.opacity)
                    }
                    if showGit {
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
                                    // Destructive: type it and get out of the
                                    // way — the user's Return is the confirm.
                                    terminals.send(command, to: path)
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        showGit = false
                                    }
                                }
                            },
                            prompt: { promptForText(
                                title: $0, message: $1, placeholder: $2
                            ) }
                        )
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: DetailFrameKey.self,
                            value: g.frame(in: .named(Self.rootSpace))
                        )
                    }
                )
            } else {
                // Selection normally clears when the last pane closes (see
                // the terminalPaths onChange) — this is the transient frame
                // before it does, and any odd path into a pane-less
                // selection. Same sky either way.
                emptyState
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
            emptyState
        }
    }

    /// The empty-state sky. The collapsed rail is wider than the traffic
    /// lights, so no shelf is needed under them anymore.
    private var emptyState: some View {
        EmptyStateView()
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
            out.append(.action(key: "new-terminal", title: "New Terminal"))
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
            return 22
        case .folder:
            return 26
        case let .action(key, _):
            // "New" stands in for the first terminal row — same height as one
            // (32pt), so the sections below don't jump when it's swapped out.
            return key == "new-terminal" ? 32 : 26
        case .library:
            return 28
        case let .row(id, _):
            if case .server = id { return 42 }
            if case let .project(path) = id, !terminals.hasPane(for: path) { return 28 }
            return 32
        }
    }

    // MARK: - Sidebar rows

    @ViewBuilder
    private func row(for entry: SidebarEntry, hovered: Bool) -> some View {
        switch entry {
        case let .header(title):
            HStack(alignment: .bottom, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
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
            .padding(.leading, 14)
            .padding(.trailing, 8)

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
                        hovered: hovered || serverPopover == sid,
                        selected: false,
                        onOpen: { Actions.openExternal(server.url) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { serverPopover = sid }
                    .popover(
                        isPresented: Binding(
                            get: { serverPopover == sid },
                            set: { if !$0 { serverPopover = nil } }
                        ),
                        arrowEdge: .trailing
                    ) {
                        ServerPopover(
                            server: server,
                            health: servers.health[sid],
                            onOpenTerminal: {
                                serverPopover = nil
                                if let cwd = server.cwd { select(.project(cwd)) }
                            }
                        )
                    }
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
                // While the popover is up, hover changes must NOT re-host the
                // row — that would tear down the view anchoring the popover.
                let state = serverPopover == sid ? "P" : (hovered ? "h" : "-")
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
private struct DetailFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

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
    /// "Needs you": a rose wash over the pill. Drawn here — RowChrome is the
    /// one layer that draws row highlights — so it can never fight the
    /// hover/selection fills.
    var attention: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
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
                        .foregroundStyle(Color(hex: 0x16A34A))
                    Text("−\(diff.removed)")
                        .foregroundStyle(Theme.closeRed)
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

/// The server detail, as a popover off its sidebar row — replaces the old
/// full detail page.
struct ServerPopover: View {
    let server: DevServer
    var health: ServerHealth? = nil
    var onOpenTerminal: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ServerGlyph(color: healthColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.project ?? server.command)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(healthLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Button("localhost:" + String(server.port)) {
                    Actions.openExternal(server.url)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                if let cwd = server.cwd {
                    Text(cwd)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(server.command) · pid \(server.pid)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 8) {
                Button("Open in Browser") { Actions.openExternal(server.url) }
                if server.cwd != nil {
                    Button("Open Terminal") { onOpenTerminal() }
                }
                Button("Stop") { Actions.killPid(server.pid) }
            }
            .font(.system(size: 11))
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private var healthColor: Color {
        switch health {
        case .healthy: Theme.dotActive
        case .degraded: Color(hex: 0xD97706)
        case .down: Theme.closeRed
        case nil: Theme.textSecondary
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

struct ServerRow: View {
    let server: DevServer
    /// Last probe verdict; nil until the first probe lands.
    var health: ServerHealth? = nil
    var hovered: Bool = false
    var selected: Bool = false
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ServerGlyph(color: healthColor)
                .help(healthHelp)
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

    private var healthColor: Color {
        switch health {
        case .healthy: Theme.dotActive
        case .degraded: Color(hex: 0xD97706)
        case .down: Theme.closeRed
        case nil: Theme.textSecondary
        }
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
