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

    var projectPath: String? {
        switch self {
        case let .project(path): path
        case let .shell(path, _): path
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
    case git, skills, tasks
    /// The server list — clicking a row pushes to that server's page.
    case servers
    case server(String)
    /// A project's capsule shelf — its sealed chats. `focus` (a capsule
    /// id) lands straight in that capsule's transcript view.
    case capsules(project: String)
    /// A project's chat list — the layout's chat navigator (2026-09-20):
    /// clicking a project in the sidebar opens its chats HERE, not nested
    /// under the project row. The sidebar carries projects; this carries
    /// their conversations.
    case chats(project: String)
    /// An inline chat thread hanging off one reply paragraph — the
    /// target is self-contained (project, file, harness, anchor), so the
    /// panel works even if the chat behind it navigates away.
    case chatThread(ChatThreadTarget)
}

/// The project panel's segmented pages — Chat / Terminal / Server
/// (2026-09-20 design: one panel per project, three views of it).
enum ProjectPanelTab: String, CaseIterable {
    case chat = "Chat"
    case terminal = "Terminal"
    case server = "Server"
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
    // Re-renders chat-row badges on session phase changes (activityTick).
    @ObservedObject private var chatHub = ChatSessionHub.shared
    @ObservedObject private var providerAuth = ProviderAuthStore.shared
    @StateObject private var tracked = TrackedStore()
    @ObservedObject private var feed = EventFeed.shared
    @State private var selection: SidebarSelection?
    /// What the right sheet shows. One sheet, four contents — Git, Skills,
    /// Tracked, and the notification feed are mutually exclusive by type.
    @State private var rightPanel: RightPanel?
    /// Docked: the sheet joins the layout and pushes the detail column.
    /// Floating: it overlays the content. Seeded from the last pin choice
    /// (settings.json) so a sheet opens the way the user last left one.
    @State private var rightPanelDocked = HoustonSettings.read().rightPanelDocked
    /// The tasks sheet's navigation: nil shows All Tasks (the root), a path
    /// shows that project's page nested under it (Back pops to nil).
    @State private var taskSheetProject: String? = nil
    /// Which tab the tasks sheet shows — Tasks or Reminders.
    @State private var taskSheetTab: TaskSheetTab = .tasks
    /// Hover for the breadcrumb's "All Tasks" button in the sheet title bar.
    @State private var crumbHovered = false
    /// The centered capsule dialog (transcript + fragment selection).
    /// Clicking a capsule anywhere opens this; the right sheet only ever
    /// shows the shelf.
    @State private var capsuleDialog: ChatCapsule?
    /// Whether the dialog fronts the "Introducing Capsules" explainer —
    /// the persisted flag is read ONCE per open here, never in the
    /// dialog's init (which re-runs on every body evaluation).
    @State private var capsuleDialogIntro = false
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
    /// The project panel's active page — reset to Chat on every project
    /// click (that's the click's intent); Terminal/Server are one tap away.
    @State private var projectPanelTab: ProjectPanelTab = .chat
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
    /// Whether the sidebar panel's top edge is tucked below the titlebar
    /// strip. Expanded, the panel runs full height and slides UNDER the
    /// strip's opaque cover; collapsing tucks the top edge down first,
    /// then swaps to the rail — the two phases read as the panel's
    /// top-right corner wrapping down around the traffic lights.
    /// Tracks `sidebarCollapsed` at rest.
    @State private var sidebarTopTucked = HoustonSettings.read().sidebarCollapsed
    /// Cancels a staged collapse/expand phase still in flight when a newer
    /// call lands (rapid toggling, a drag mid-choreography).
    @State private var collapseStageSeq = 0
    /// The rail section whose popover is open, while collapsed.
    @State private var railPopover: RailSection?
    /// The rail row under the pointer — drives the INSTANT tooltip beside
    /// the rail (`railTipLayer`; the system `.help` delay made icon-only
    /// buttons feel unlabeled). Rendered in the root overlay because the
    /// rail column itself is clipped to its 52pt width.
    @State private var railTip: RailTipItem?

    /// Clearance for the traffic lights, which float over the sidebar now that
    /// the title bar is transparent and full-size.
    private let trafficLightInset: CGFloat = 48
    /// The titlebar strip cover: an opaque plate in the app-background color
    /// under the traffic lights + collapse/gear/bell cluster, drawn over the
    /// full-height sidebar. Its rounded bottom-trailing corner is what cuts
    /// the "wraps around the traffic lights" notch into the panel.
    private var stripCoverHeight: CGFloat { trafficLightInset - 16 }
    /// Past the button cluster (ends at x≈152) with breathing room before
    /// the corner; the 180pt sidebar minimum keeps the panel poking out.
    private let stripCoverWidth: CGFloat = 166
    /// Where the tucked panel's top edge rests: 1pt ABOVE the strip
    /// cover's bottom, so the panel stays just behind the traffic-light
    /// plate instead of landing flush — no seam, and the collapsed state
    /// reads as emerging from under it.
    private var sidebarTuckTop: CGFloat { stripCoverHeight - 1 }

    @Environment(\.colorScheme) private var systemScheme

    /// The window's one full-bleed surface (2026-09-14): the content area
    /// has no frame or border — the root background IS whatever the detail
    /// shows (chat's panel fill, the terminal theme's background, the empty
    /// state's sky) and the sidebar floats over it as a rounded panel.
    /// A terminal (not chat, not the empty state) fills the detail pane.
    /// In this mode the sidebar and the page around the terminal card are
    /// one seamless surface — flat `sidebarFill`, no glass, no border.
    private var inTerminalView: Bool {
        guard chatTarget == nil, let path = selection?.projectPath else { return false }
        return terminals.hasPane(for: path)
    }

    private var chromeBackground: Color {
        // Terminal mode's page is the chat page's color too (2026-09-14):
        // the terminal theme paints only the rounded terminal card, not
        // the chrome around it.
        if chatTarget != nil { return Theme.gitPanelFill }
        if let path = selection?.projectPath, terminals.hasPane(for: path) {
            // Terminal mode's page matches the sidebar (the rounded
            // terminal card carries the theme color; the chrome around it
            // reads as one surface with the sidebar).
            return Theme.sidebarFill
        }
        return Theme.emptyStateBackground
    }

    /// Whether that surface is dark — the fixed collapse toggle sits on it
    /// (not on the sidebar panel), so its glyph flips appearance with it.
    /// Every chrome surface now tracks the appearance (the sky included),
    /// so this is just the system scheme.
    private var chromeIsDark: Bool {
        systemScheme == .dark
    }

    /// Sidebar width, dragged by the divider below.
    // Restored from settings; the literal bounds mirror `sidebarRange`,
    // which isn't available in a property initializer.
    @State private var sidebarWidth: CGFloat =
        min(max(CGFloat(HoustonSettings.read().sidebarWidth), 180), 420)
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
            // Reserve the sheet's width in the layout. The sheet itself
            // always draws in the overlay flush with the right edge, so
            // pin/unpin animates nothing but this width (and the scrim) —
            // no re-parenting, no jump. The project sidebar reserves even
            // unpinned: chat content centers between the two sidebars.
            Color.clear
                .frame(width: rightPanelReservedWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chromeBackground)
        // The collapse toggle shares the rail-flyout slot — one more root
        // modifier tips the type-checker (see shortcutListeners).
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                collapseToggleLayer
                railFlyoutLayer
                railTipLayer
            }
        }
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
        // Fully invisible — no stroke on hover or drag; the resize grip
        // below is the whole control, the cursor is the only hint.
        Rectangle()
            .fill(Color.clear)
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
                                        setSidebarCollapsed(false, staged: false)
                                    }
                                    return
                                }
                                // Well past the minimum snaps to the rail,
                                // Finder-style — rebased so reversing the
                                // same drag pulls it straight back out.
                                if proposed < sidebarRange.lowerBound - 50 {
                                    sidebarWidth = sidebarRange.lowerBound
                                    sidebarDragStart = railWidth - value.translation.width
                                    setSidebarCollapsed(true, staged: false)
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

    /// The panel silhouette both sidebar states share: flush left, and a
    /// rounded top-trailing corner ONLY at full height — tucked (mid-
    /// collapse, or the rail), the top edge hides behind the strip cover
    /// and a curve there would poke out square-less. Driven by the same
    /// tucked flag as the paddings, so the radius tweens inside the same
    /// spring.
    private var sidebarPanelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: sidebarTopTucked ? 0 : 24
        )
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            // No titlebar strip inside the panel — expanded, the panel runs
            // full height and slides under the strip's opaque cover (see
            // `collapseToggleLayer`); tucked, it starts below the traffic
            // lights. The collapse control lives in the fixed
            // `collapseToggleLayer`, up in the strip, and holds its spot
            // when the column collapses.
            // The Houston wordmark crowns the panel — template-tinted so
            // it follows the appearance like an SF Symbol.
            if let logo = SVGIcon.template(named: "houstonlogo") {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    .padding(.top, 22)
            }
            sidebarTopCluster
                .padding(.top, 20)
                // Off the root body — one more root modifier tips the
                // type-checker over its expression limit.
                .onChange(of: store.pinnedProjects) { _, paths in
                    chatIndex.refreshAll(paths)
                }
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
        // The two paddings trade the same inset across the surface modifier,
        // so content holds its absolute position while only the panel's top
        // edge moves between full height (expanded) and tucked (collapsing).
        .padding(.top, sidebarTopTucked ? 0 : sidebarTuckTop)
        .modifier(SidebarSurface(shape: sidebarPanelShape, seamless: inTerminalView))
        .padding(.top, sidebarTopTucked ? sidebarTuckTop : 0)
    }

    // MARK: - Collapsed rail

    /// Rail width — enough for a 34pt icon button centered with breathing
    /// room. The traffic lights (ending at x=69) overhang the divider onto
    /// the detail column's top-left, brushing the sky container's rounded
    /// corner on the empty state — accepted for the thin rail.
    private let railWidth: CGFloat = 52

    /// The collapsed sidebar, mirroring the expanded layout (2026-09-16):
    /// the top-tile trio (New Chat, Tasks, Servers — same actions, Servers
    /// opens the right sheet, not a flyout) above the rule, then the
    /// table's sections (Terminals, Projects) as flyout buttons below it.
    private var railColumn: some View {
        VStack(spacing: 6) {
            // Expand lives in the fixed `collapseToggleLayer` beside the
            // traffic lights — the same spot as when the sidebar is out;
            // gear and bell ride the titlebar strip beside it.
            // The trio's labels come from the INSTANT tip layer (help: ""
            // so the delayed system tooltip doesn't double up beside it).
            RailButton(
                help: "",
                active: chatTarget == ChatTarget(
                    path: NSHomeDirectory(), sessionFile: nil),
                action: {
                    chatTarget = ChatTarget(
                        path: NSHomeDirectory(), sessionFile: nil)
                }
            ) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .modifier(railTipHover(.newChat))
            .padding(.top, 14)
            RailButton(
                help: "",
                active: rightPanel == .tasks,
                action: { openAllTasks() }
            ) {
                Image(systemName: "checklist")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        if tracked.attentionCount > 0 {
                            Circle()
                                .fill(Theme.dotDegraded)
                                .frame(width: 5, height: 5)
                                .offset(x: 4, y: -3)
                        }
                    }
            }
            .modifier(railTipHover(.tasks))
            RailButton(
                help: "",
                active: rightPanel == .servers,
                action: { toggleRightPanel(.servers) }
            ) {
                // Same language as the expanded tile: green glyph while
                // servers run, with the count riding its corner.
                ServerGlyph(
                    color: servers.devServers.isEmpty
                        ? Theme.textSecondary : Theme.dotActive,
                    size: 15
                )
                .overlay(alignment: .topTrailing) {
                    if !servers.devServers.isEmpty {
                        Text(String(servers.devServers.count))
                            .font(.system(size: 8, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPositive)
                            .offset(x: 7, y: -4)
                    }
                }
            }
            .modifier(railTipHover(.servers))
            // Same short rule as the expanded footer, centered on the rail.
            Rectangle()
                .fill(Theme.borderSidebar)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
            railButton(.terminals)
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
        .modifier(SidebarSurface(shape: sidebarPanelShape, seamless: inTerminalView))
        .padding(.top, sidebarTuckTop)
    }

    private func railButton(_ section: RailSection) -> some View {
        let tip: RailTipItem = switch section {
        case .terminals: .terminals
        case .servers: .servers
        case .projects: .projects
        }
        return RailButton(
            help: "",
            active: railPopover == section,
            action: { setRailPopover(railPopover == section ? nil : section) }
        ) {
            railIcon(section)
        }
        .modifier(railTipHover(tip))
    }

    /// The sidebar collapse/expand toggle, pinned to the titlebar strip
    /// just right of the traffic lights (which end at x≈69) — the SAME
    /// spot in both states, so the control never jumps as the column
    /// swaps between sidebar and rail.
    private var collapseToggleLayer: some View {
        HStack(spacing: 4) {
            FooterIconButton(
                systemName: "sidebar.left",
                help: sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar",
                action: toggleSidebarCollapse
            )
            // Settings and notifications ride the strip beside the toggle
            // (2026-09-14) — bare glyphs, out of the sidebar's row stack.
            settingsMenu()
            notificationsMenu
        }
        .padding(.leading, 78)
        // Centered on the traffic lights (12pt buttons, center y≈18),
        // NOT in the 48pt strip — centering there sat the button ~6pt
        // below the lights' line.
        .padding(.top, 5)
        .frame(height: trafficLightInset, alignment: .top)
        // The strip cover: an opaque app-background plate under the lights
        // and buttons. The expanded sidebar runs full height beneath it, so
        // the panel pokes out to its right and the cover's rounded corner
        // cuts the wrap-around notch. Hit-testing off so clicks land where
        // they always did (the cover is chrome, not a control).
        .background(alignment: .topLeading) {
            UnevenRoundedRectangle(bottomTrailingRadius: 14)
                .fill(chromeBackground)
                // Subtle edge on the plate's exposed run (bottom + the
                // rounded corner + right); the mask trims the top and
                // left, which sit flush to the window edges.
                .overlay(
                    UnevenRoundedRectangle(bottomTrailingRadius: 14)
                        .inset(by: 0.5)
                        .stroke(Theme.borderSidebar, lineWidth: 1)
                        .mask(Rectangle().padding(.leading, 2).padding(.top, 2))
                )
                .frame(width: stripCoverWidth, height: stripCoverHeight)
                .allowsHitTesting(false)
        }
        // Over a dark surface (terminal theme, the empty-state sky) the
        // glyph must resolve its dark-appearance color.
        .colorScheme(chromeIsDark ? .dark : .light)
    }

    /// The bell as a dropdown like the gear (2026-09-14 — was a right
    /// sheet): recent events newest-first, clicking one jumps to its
    /// project. Opening the menu marks everything read.
    private var notificationsMenu: some View {
        Menu {
            Section {
                if feed.events.isEmpty {
                    Button("No notifications yet") {}.disabled(true)
                } else {
                    ForEach(feed.events.prefix(20)) { event in
                        Button {
                            if let path = event.projectPath {
                                select(.project(path))
                            }
                        } label: {
                            Text(event.title)
                            Text(event.detail)
                        }
                    }
                }
            }
            .onAppear { feed.markAllRead() }
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 12))
                .foregroundStyle(Theme.heading)
                .frame(width: 22, height: 22)
                .overlay(alignment: .topTrailing) {
                    if feed.unreadCount > 0 {
                        Text(String(feed.unreadCount))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14)
                            .frame(height: 14)
                            .background(Capsule().fill(Theme.dotDegraded))
                    }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notifications")
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

    /// Layout width the right sheet takes. The project sidebar ALWAYS
    /// reserves its width — pinned or floating, the chat content pushes
    /// left and centers between the two sidebars (a floating card keeps
    /// its 32pt edge inset, hence the extra). Other panels reserve only
    /// when docked; floating ones overlay the content.
    private var rightPanelReservedWidth: CGFloat {
        guard let rightPanel else { return 0 }
        if case .chats = rightPanel {
            return rightSheetWidth + (rightPanelDocked ? 0 : 32)
        }
        return rightPanelDocked ? rightSheetWidth : 0
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
        case .skills:
            if let path = selection?.projectPath {
                skills = SkillsCatalog.load(projectPath: path)
            }
        case let .chats(project):
            chatIndex.refresh(project, force: true)
        case .git, .servers, .server, .tasks, .capsules, .chatThread:
            break
        }
    }

    private func closeRightPanel() {
        withAnimation(sheetSpring) { rightPanel = nil }
    }

    /// Every pin toggle goes through here so the choice persists — the
    /// next sheet (this launch or the next) opens pinned or floating
    /// based on how the user last left one.
    private func toggleRightPanelPinned() {
        withAnimation(sheetSpring) { rightPanelDocked.toggle() }
        updateSettings { $0.rightPanelDocked = rightPanelDocked }
    }

    /// Open the tasks sheet at its All Tasks root (the footer checklist),
    /// or close it if that's already showing.
    private func openAllTasks() {
        if rightPanel == .tasks && taskSheetProject == nil && taskSheetTab == .tasks {
            closeRightPanel()
            return
        }
        withAnimation(sheetSpring) {
            taskSheetProject = nil
            taskSheetTab = .tasks
        }
        if rightPanel != .tasks { toggleRightPanel(.tasks) }
    }

    /// Open the tasks sheet pushed into one project's page (the terminal
    /// header's Tasks button), or close it if that page is already showing.
    private func openProjectTasks(_ path: String) {
        if rightPanel == .tasks && taskSheetProject == path {
            closeRightPanel()
            return
        }
        withAnimation(sheetSpring) {
            taskSheetProject = path
            taskSheetTab = .tasks
        }
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
        // Floating: a detached card at 80% of the window's height, 32px
        // in from the window's top and right edges. Docked: the
        // full-height strip, part of the page. The GeometryReader spans
        // the window but only the sheet itself is hit-testable.
        GeometryReader { geo in
            rightSheet
                .frame(height: rightPanelDocked
                    ? geo.size.height : geo.size.height * 0.8)
                .padding(.top, rightPanelDocked ? 0 : 32)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: .topTrailing
                )
        }
        .offset(x: open ? 0 : rightSheetWidth + 40)
        .allowsHitTesting(open)
        // The project sidebar tracks the project view: entering one (any
        // chatTarget — home or a chat) summons it, wherever the target
        // was set from (row click, rekey, banner route); leaving closes
        // it. Attached here, not the root body — the sheet layer is
        // always mounted, and one more root modifier tips the
        // type-checker's expression limit.
        .onChange(of: chatTarget) { _, target in
            if let target {
                if rightPanel != .chats(project: target.path) {
                    // A different project's panel: land on Chat — that's
                    // the open's intent, whatever tab the last project
                    // was showing.
                    projectPanelTab = .chat
                    lastRightPanel = .chats(project: target.path)
                    withAnimation(sheetSpring) {
                        rightPanel = .chats(project: target.path)
                    }
                }
            } else if case let .chats(project) = rightPanel,
                      selection?.projectPath != project {
                // Leaving the project closes its panel — but selecting one
                // of the SAME project's terminals (the panel's Terminal
                // tab does exactly this) is still "in the project", so the
                // panel must not dismiss the page the click came from.
                closeRightPanel()
            }
        }
        // Once the close animation lands, drop the sheet's render
        // fallback — a closed sheet keeps building `lastRightPanel`'s
        // content on every body evaluation otherwise.
        .onChange(of: rightPanel) { _, panel in
            guard panel == nil else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if rightPanel == nil { lastRightPanel = nil }
            }
        }
    }

    /// Click on dead chrome: dismiss a floating sheet, never a docked one.
    /// The project sidebar is exempt while a project view is up — it's
    /// part of that view (no ✕ either); leaving the project closes it.
    private func closeFloatingSheet() {
        guard rightPanel != nil, !rightPanelDocked else { return }
        if case .chats = rightPanel, chatTarget != nil { return }
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
                        action: { toggleRightPanelPinned() }
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
            // ZStack: while a push runs, the outgoing and incoming pages
            // must overlap in the same slot — bare ConditionalContent in
            // the VStack let them stack instead of sliding over each other.
            ZStack(alignment: .top) { rightSheetContent }
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
        // Glass, same recipe as the left sidebar: the content behind the
        // floating card reads through the blur, the fill wash keeps the
        // panel's rows legible.
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.7)
            }
        )
        // Floating: a rounded card with a hairline all the way around,
        // detached from the window edge. Docked: square and flush, part
        // of the page — a border there would read as a seam.
        .clipShape(RoundedRectangle(
            cornerRadius: rightPanelDocked ? 0 : 16))
        .overlay(
            RoundedRectangle(cornerRadius: rightPanelDocked ? 0 : 16)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                .opacity(rightPanelDocked ? 0 : 1)
        )
        .overlay(alignment: .leading) { rightSheetGrip }
        .padding(.trailing, rightPanelDocked ? 0 : 32)
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

    /// Panels that draw their own header (per the Figma/mock designs), so
    /// the shared controls bar stands down: the server page and the
    /// project panel.
    private var serverChromeHidden: Bool {
        switch effectiveRightPanel {
        case .server, .chats: return true
        default: return false
        }
    }

    private var rightSheetTitle: String {
        switch effectiveRightPanel {
        case .git: "GIT"
        case .skills: "SKILLS"
        case .servers: "SERVERS"
        case .server: "SERVER"
        case .tasks: "ALL TASKS"
        case .capsules: "CAPSULES"
        case let .chats(project): name(of: project).uppercased()
        case .chatThread: "THREAD"
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
                    withAnimation(sheetSpring) {
                        taskSheetTab = .tasks
                        taskSheetProject = nil
                    }
                }
            } else if let path = taskSheetProject {
                taskBreadcrumbs(current: (path as NSString).lastPathComponent) {
                    withAnimation(sheetSpring) { taskSheetProject = nil }
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

    /// Push/pop between the sheet's parent and child pages, with no
    /// direction state: a parent page always enters and leaves at the
    /// LEADING edge, a child at the TRAILING edge. Pushing slides the
    /// child in from the right as it shoves the parent out the left;
    /// popping reverses both. Pure moves — an opacity fade here turns
    /// the push into a crossfade.
    static let pageParent = AnyTransition.move(edge: .leading)
    static let pageChild = AnyTransition.move(edge: .trailing)

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
                        terminals.send(
                            "/\(skill.name.strippingTerminalControls)\n",
                            to: path
                        )
                        if !rightPanelDocked { closeRightPanel() }
                    },
                    onInsert: { skill in
                        terminals.send(
                            "/\(skill.name.strippingTerminalControls) ",
                            to: path
                        )
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
                // The id makes root ↔ project page a real view swap, so
                // the push transitions run between them.
                TasksNavigator(
                    projectPath: taskSheetProject,
                    trackedAttention: tracked.attentionCount,
                    onOpenProject: { path in
                        withAnimation(sheetSpring) { taskSheetProject = path }
                    },
                    onOpenReminders: {
                        withAnimation(sheetSpring) { taskSheetTab = .reminders }
                    }
                )
                .id(taskSheetProject ?? "tasks-root")
                .transition(taskSheetProject == nil
                    ? Self.pageParent : Self.pageChild)
            case .reminders:
                TrackedPanel(store: tracked)
                    .transition(Self.pageChild)
            }
        case .servers:
            ScrollView { serversListPanel }
                .transition(Self.pageParent)
        case let .chatThread(target):
            ChatThreadPanel(target: target)
                .transition(Self.pageChild)
        case let .server(sid):
            // Resolve by live id first, then through the recent entry the id
            // maps to — so the sheet morphs live↔off in place as the server
            // stops or comes back, whichever id it was opened under.
            Group {
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
                    onTogglePin: { toggleRightPanelPinned() },
                    onClose: closeRightPanel,
                    onBack: {
                        withAnimation(sheetSpring) { rightPanel = .servers }
                    }
                )
            } else if let recent = servers.recent(matching: sid) {
                OffServerPanel(
                    recent: recent,
                    busyPorts: Dictionary(
                        servers.devServers.map { ($0.port, $0.project ?? $0.command) },
                        uniquingKeysWith: { a, _ in a }
                    ),
                    docked: rightPanelDocked,
                    onTogglePin: { toggleRightPanelPinned() },
                    onClose: closeRightPanel,
                    onBack: {
                        withAnimation(sheetSpring) { rightPanel = .servers }
                    },
                    onStart: { command in
                        terminals.pane(for: recent.projectPath)
                        select(.project(recent.projectPath))
                        terminals.send(command + "\n", to: recent.projectPath)
                    }
                )
            } else {
                rightSheetPlaceholder("This server is no longer listening.")
            }
            }
            .transition(Self.pageChild)
        case let .chats(project):
            chatListPanel(for: project)
                .transition(Self.pageParent)
        case let .capsules(path):
            CapsulePanel(
                projectPath: path,
                onAttach: { capsule in
                    attachCapsuleToNewChat(project: path, capsule: capsule)
                },
                onOpenChat: { file in
                    chatTarget = ChatTarget(path: path, sessionFile: file)
                    chatIndex.refresh(path, force: true)
                    if !rightPanelDocked { closeRightPanel() }
                },
                onView: { openCapsuleDialog($0) }
            )
        case nil:
            EmptyView()
        }
    }

    private func openCapsuleDialog(_ capsule: ChatCapsule) {
        capsuleDialogIntro = !HoustonSettings.read().capsuleHintDismissed
        withAnimation(Theme.quick) { capsuleDialog = capsule }
    }

    private func openCapsuleDialog(id: String) {
        if let capsule = capsuleStore.capsules.first(where: { $0.id == id }) {
            openCapsuleDialog(capsule)
        }
    }

    private func closeCapsuleDialog() {
        withAnimation(Theme.quick) { capsuleDialog = nil }
    }

    /// The centered capsule dialog: traditional modal — dimmed scrim,
    /// click-away or ✕ closes, actions in the dialog's footer.
    @ViewBuilder
    private var capsuleDialogLayer: some View {
        if let capsule = capsuleDialog {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { closeCapsuleDialog() }
                    CapsuleDialog(
                        capsule: capsule,
                        showIntroInitially: capsuleDialogIntro,
                        onClose: closeCapsuleDialog,
                        onAttach: {
                            closeCapsuleDialog()
                            attachCapsuleToNewChat(
                                project: capsule.project, capsule: capsule
                            )
                        },
                        onInsert: { references in
                            closeCapsuleDialog()
                            insertIntoComposer(
                                project: capsule.project, texts: references
                            )
                        }
                    )
                    // 80vw × 90vh as a CEILING — the transcript fills it;
                    // the intro dialog stays its own fitting size.
                    .frame(
                        maxWidth: geo.size.width * 0.8,
                        maxHeight: geo.size.height * 0.9
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .transition(.opacity)
        }
    }

    /// A capsule-view section insert: make sure a chat surface for the
    /// project is up (a new chat if none is), then hand the composer the
    /// text — after a beat, so a freshly mounted composer is listening.
    private func insertIntoComposer(project: String, text: String) {
        insertIntoComposer(project: project, texts: [text])
    }

    /// Multi-fragment adds ride ONE delayed hop — N separate asyncAfter
    /// blocks landing together made the composer rebuild N times in a
    /// single runloop burst.
    private func insertIntoComposer(project: String, texts: [String]) {
        guard !texts.isEmpty else { return }
        if chatTarget?.path != project {
            chatTarget = ChatTarget(path: project, sessionFile: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for text in texts {
                NotificationCenter.default.post(
                    name: .houstonComposerInsert, object: text
                )
            }
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
                // Single-quoted + control-stripped: git allows `$`, `` ` ``
                // and parens in ref names, so a hostile repo's branch
                // list must never reach the shell double-quoted.
                let safe = branch.strippingTerminalControls.shellQuoted
                terminals.send("git switch \(safe)\n", to: path)
                git.refresh()
            },
            onNewBranch: {
                guard let name = promptForText(
                    title: "New Branch",
                    message: "Created from the current branch and switched to.",
                    placeholder: "feature/thing"
                ), !name.isEmpty else { return }
                let safe = name.strippingTerminalControls.shellQuoted
                terminals.send("git switch -c \(safe)\n", to: path)
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

    /// The instant tooltip beside the hovered rail icon — same second-layer
    /// card language as the flyouts, suppressed while a flyout is open
    /// (they share the slot beside the rail).
    @ViewBuilder
    private var railTipLayer: some View {
        if sidebarCollapsed, railPopover == nil, let tip = railTip {
            Text(tip.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(Theme.panelFill)
                        .shadow(
                            color: Theme.floatShadowColor,
                            radius: 4, x: 0, y: 1
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                )
                .offset(x: railWidth + 8, y: railTipTop(tip))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Vertical center of a rail row's tooltip: the rows stack from the
    /// panel top in 36pt steps (30pt button + 6 spacing), with the rule
    /// block (5pt + 6 spacing) between the trio and the sections; the
    /// ~23pt tip card centers on the 30pt button.
    private func railTipTop(_ tip: RailTipItem) -> CGFloat {
        let rowTop = sidebarTuckTop + 14 + tip.row * 36
            + (tip.row >= 3 ? 11 : 0)
        return rowTop + 3
    }

    /// Hover wiring for one rail row — entering sets the tip, leaving
    /// clears it only if it's still ours (rows share one tip slot).
    private func railTipHover(_ item: RailTipItem) -> some ViewModifier {
        HoverAction { inside in
            if inside {
                railTip = item
            } else if railTip == item {
                railTip = nil
            }
        }
    }

    /// Aligns the flyout's top edge with the rail button that opened it.
    private func flyoutTop(for section: RailSection) -> CGFloat {
        let index: CGFloat = switch section {
        case .terminals: 0
        // Servers opens the right sheet now, not a flyout — the case
        // exists only for exhaustiveness.
        case .servers: 0
        case .projects: 1
        }
        // Panel top + inner padding (14), then the top trio (three 30pt
        // buttons + 6pt spacings) and the rule block (5pt + 6 spacing)
        // sit above the first flyout button; each further row is 36pt.
        return sidebarTuckTop + 14 + 3 * 36 + 11 + index * 36
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

    /// Two-phase choreography (2026-09-16): collapsing tucks the panel's
    /// top edge down under the strip cover FIRST, then after a beat swaps
    /// to the rail — the top-right corner drops past the traffic lights,
    /// then slides left, reading as the edge wrapping around them.
    /// Expanding runs the phases in reverse. `staged: false` (the divider
    /// drag) does both at once — a delayed width swap mid-drag would fight
    /// the gesture's origin rebasing.
    private func setSidebarCollapsed(_ collapsed: Bool, staged: Bool = true) {
        guard collapsed != sidebarCollapsed || collapsed != sidebarTopTucked
        else { return }
        railPopover = nil
        collapseStageSeq += 1
        let seq = collapseStageSeq
        updateSettings { $0.sidebarCollapsed = collapsed }
        guard staged else {
            withAnimation(.easeOut(duration: 0.15)) {
                sidebarTopTucked = collapsed
                sidebarCollapsed = collapsed
            }
            return
        }
        if collapsed {
            // Mirror of the expand sweep below: the top drop leads and
            // the width joins while it's still moving — one diagonal
            // down-and-in motion on the same overlapping springs.
            withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
                sidebarTopTucked = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard seq == collapseStageSeq else { return }
                withAnimation(.spring(duration: 0.38, bounce: 0.12)) {
                    sidebarCollapsed = true
                }
            }
        } else {
            // Expand sweeps: the width leads and the top joins while the
            // width is still moving — overlapping springs read as one
            // diagonal out-and-up motion. Waiting for the width to land
            // before popping the top felt like two mechanical steps.
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) {
                sidebarCollapsed = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard seq == collapseStageSeq else { return }
                withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
                    sidebarTopTucked = false
                }
            }
        }
    }

    private func toggleSidebarCollapse() {
        // Both-at-rest is the only true "collapsed"; mid-choreography a
        // second toggle re-runs the collapse rather than guessing intent.
        setSidebarCollapsed(!(sidebarCollapsed && sidebarTopTucked))
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
                        hasTerminal: true,
                        hovered: hovered,
                        selected: highlightedSelection == .project(path),
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
                            hasTerminal: true,
                            hovered: hovered,
                            selected: highlightedSelection == .shell(path: path, tab: tab.id),
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
        // Same filter as the project panel — dismissed husks, superseded
        // segments and archived chats stay hidden here too.
        let chatCount = pinned.reduce(0) {
            $0 + min(listedChats(for: $1).count, 3)
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
                    Array(listedChats(for: path).prefix(3)),
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

    /// Clicking a project opens its chats panel + chat home — same as the
    /// expanded sidebar's project row; the terminal lives one hover-icon
    /// away.
    private func projectPopoverRow(_ path: String) -> some View {
        PopoverRow(height: 28, action: {
            setRailPopover(nil)
            openProjectChats(path)
        }) { hovered in
            HStack(spacing: 0) {
                SidebarRow(
                    name: name(of: path),
                    diff: libraryDiff(path),
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

    /// The topmost overlay tier: the capsule dialog (a true modal — it
    /// must dim the right sheet too, so it can't ride the flyout slots),
    /// with the first-launch onboarding takeover above everything.
    private var modalLayer: some View {
        ZStack {
            capsuleDialogLayer
            providerKeyDialogLayer
            onboardingLayer
        }
    }

    /// The provider API-key dialog: same traditional modal chrome as the
    /// capsule dialog — dimmed scrim, click-away or Esc cancels.
    @ViewBuilder
    private var providerKeyDialogLayer: some View {
        if let provider = providerAuth.keyPrompt {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { providerAuth.keyPrompt = nil }
                ProviderKeyDialog(
                    provider: provider,
                    onSave: { key in
                        providerAuth.setKey(key, for: provider.id)
                        providerAuth.keyPrompt = nil
                    },
                    onCancel: { providerAuth.keyPrompt = nil }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
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
        // Single-quoted, not double — a pasted URL with `$(…)` must not
        // execute when the line lands in the shell.
        let safeURL = url.strippingTerminalControls.shellQuoted
        let safeDest = dest.strippingTerminalControls.shellQuoted
        terminals.send("git clone \(safeURL) \(safeDest)\n", to: NSHomeDirectory())
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

    /// The sidebar's one action row — "New" (a home-folder shell) while
    /// no terminal is open. Every click opens another shell: the first
    /// becomes the home terminal, the rest nest under it as "~ · N" tabs.
    private func runAction(_ key: String) {
        guard key == "new-terminal" else { return }
        let home = NSHomeDirectory()
        if terminals.hasPane(for: home), let tab = terminals.newTab(in: home) {
            select(.shell(path: home, tab: tab.id))
        } else {
            select(.project(home))
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
    /// Below this sidebar width the three tiles can't fit their labels
    /// side by side — they restack vertically as horizontal rows.
    private var topTilesStackVertically: Bool { sidebarWidth < 235 }

    @ViewBuilder
    private func topTiles(rowLayout: Bool) -> some View {
        // New Chat leads in both layouts — first tile across, top row
        // stacked.
        TopTileButton(
            systemName: "square.and.pencil",
            label: "New Chat",
            active: chatTarget == ChatTarget(
                path: NSHomeDirectory(), sessionFile: nil),
            rowLayout: rowLayout,
            help: "Start a new chat",
            action: {
                chatTarget = ChatTarget(
                    path: NSHomeDirectory(), sessionFile: nil)
            }
        )
        TopTileButton(
            systemName: "checklist",
            label: "Tasks",
            dot: tracked.attentionCount > 0,
            active: rightPanel == .tasks,
            rowLayout: rowLayout,
            help: "Tasks and reminders across all projects",
            action: { openAllTasks() }
        )
        TopTileButton(
            systemName: "server.rack",
            label: "Servers",
            active: rightPanel == .servers,
            serverIcon: true,
            count: servers.devServers.count,
            rowLayout: rowLayout,
            help: "Dev servers",
            action: { toggleRightPanel(.servers) }
        )
    }

    private var sidebarTopCluster: some View {
        // Three even tiles (2026-09-14 design). Wide sidebar: side by
        // side, icon over label. Narrow: stacked vertically, each tile a
        // horizontal icon-beside-label row. Tasks and Servers open the
        // right sheet; New Chat opens a project-less chat (home stands in
        // for its path until the composer's chip sets one).
        Group {
            if topTilesStackVertically {
                VStack(spacing: 6) { topTiles(rowLayout: true) }
            } else {
                HStack(spacing: 6) { topTiles(rowLayout: false) }
            }
        }
        .padding(.horizontal, 10)
        // One section gap's worth before the table — the same 20pt a
        // header box puts between the table's own sections.
        .padding(.bottom, 20)
    }

    /// The server list, in the right sheet (2026-09-14 — was a flyout
    /// card beside the sidebar): running then stopped, each row pushing
    /// the sheet to that server's page.
    private var serversListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !servers.devServers.isEmpty {
                sheetSectionLabel("RUNNING")
                ForEach(servers.devServers, id: \.id) { server in
                    SheetListRow(
                        title: server.project ?? server.command,
                        subtitle: "localhost:" + String(server.port),
                        onTap: {
                            withAnimation(sheetSpring) {
                                rightPanel = .server(server.id)
                            }
                        },
                        icon: { ServerGlyph(color: Theme.dotActive, size: 15) }
                    )
                    .contextMenu {
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
            }
            sheetSectionLabel("STOPPED")
            if servers.recents.isEmpty {
                Text("No stopped servers")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ForEach(servers.recents, id: \.id) { recent in
                    SheetListRow(
                        title: recent.name,
                        subtitle: "was localhost:" + String(recent.port),
                        titleTint: Theme.textSecondary,
                        onTap: {
                            withAnimation(sheetSpring) {
                                rightPanel = .server(recent.id)
                            }
                        },
                        icon: { ServerGlyph(color: Theme.textSecondary, size: 15) }
                    )
                    .contextMenu {
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
                Color.clear.frame(height: 6)
            }
        }
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
        // No band, no card (2026-09-14): the root background already IS
        // the content's surface (chromeBackground), so the header and
        // status bar float directly over it.
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
            // Title and path share one row (not stacked): this keeps the
            // lockup a single line low enough that it never collides with
            // the fixed collapse/gear/bell controls, collapsed or not.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textPath)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }

            Spacer(minLength: 8)

            if let path = selection?.projectPath, terminals.hasPane(for: path) {
                headerActions(for: path)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        // Sits clear of the fixed collapse/gear/bell strip (~48pt tall) so
        // the one-row title never crowds it, collapsed or expanded.
        .padding(.top, 28)
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
        case .none: "Houston"
        }
    }

    private var headerSubtitle: String? {
        switch selection {
        case let .project(path), let .shell(path, _): path
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
            // Chat owns the whole detail column, full-bleed — its surface
            // (gitPanelFill) is also the root chromeBackground, so there
            // is no frame anywhere around it.
            ChatBrowserView(
                projectPath: chatTarget.path,
                initialSessionFile: chatTarget.sessionFile,
                projects: store.pinnedProjects
            )
            .id(chatTarget)
        } else {
            selectionContent
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case let .project(path), let .shell(path, _):
            if terminals.hasPane(for: path) {
                // The terminal is a rounded card on the chat-page chrome
                // (2026-09-14): the terminal theme's background fills only
                // the card, and the header/status bar sit on the page.
                TerminalHostView(path: path, tabID: selection?.tabID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TerminalSessionManager.themeBackgroundColor(
                        named: settings.terminalTheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // Collapsed drops the leading gap so the card sits
                    // flush against the thin rail. The trailing gap runs
                    // wider to visually match the left (the window's right
                    // chrome eats a few points otherwise).
                    .padding(.leading, sidebarCollapsed ? 0 : 12)
                    .padding(.trailing, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            } else {
                // Selection normally clears when the last pane closes (see
                // the terminalPaths onChange) — this is the transient frame
                // before it does, and any odd path into a pane-less
                // selection. Same sky either way.
                emptyState
            }
        case .none:
            emptyState
        }
    }

    /// The empty-state sky, edge to edge like every other detail state.
    private var emptyState: some View {
        // While the sidebar is hidden for onboarding, the sky holds the
        // welcome screen's 56pt lift so the dismissal crossfade lands on an
        // already-aligned solar system; the reveal spring then glides it
        // down to center as the sidebar slides in.
        // No skyShift (2026-09-14): the solar system centers in the DETAIL
        // column, treating the sidebar as inline — the old half-sidebar
        // shift centered it in the window and read as off-center.
        EmptyStateView(skyLift: sidebarRevealed ? 0 : -56)
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
        Set(terminalPaths).union(store.pinnedProjects)
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
        // Projects are plain rows (2026-09-20): chats no longer nest
        // beneath them — clicking a project opens its chat list in the
        // right sheet (`openProjectChats`), so the sidebar stays a short
        // project index however many conversations pile up.
        out.append(.header("Projects"))
        for path in store.pinnedProjects {
            out.append(.folder(path: path, name: name(of: path)))
        }
        return out
    }

    private func name(of path: String) -> String {
        path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
    }

    /// Open a chat from the chats panel — never moves the terminal
    /// selection. The panel stays put: it's part of the project view.
    private func openChat(project: String, file: String) {
        chatTarget = ChatTarget(path: project, sessionFile: file.isEmpty ? nil : file)
    }

    /// A project click: its chat home in the center, its chat list in the
    /// right sheet (2026-09-20 layout — chats live in the right sidebar,
    /// not nested under the project row).
    private func openProjectChats(_ path: String) {
        // Already inside one of this project's chats: keep it; the click
        // just summons the list.
        if chatTarget?.path != path {
            chatTarget = ChatTarget(path: path, sessionFile: nil)
        }
        if rightPanel != .chats(project: path) {
            lastRightPanel = .chats(project: path)
            withAnimation(sheetSpring) { rightPanel = .chats(project: path) }
        }
        // The click's intent is chats; Terminal/Server stay one tap away.
        projectPanelTab = .chat
        chatIndex.refresh(path, force: true)
    }

    /// The project panel (2026-09-20 mock): its own header — folder glyph
    /// + project name, pin and close — over a Chat / Terminal / Server
    /// segment bar, then the active page.
    private func chatListPanel(for path: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(name(of: path).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Three filled circle chips (per the mock): new chat,
                // pin, close. Dead-chrome clicks never dismiss this panel
                // (it's part of the project view) — the ✕ is the one
                // deliberate way out; the next project click brings it back.
                HStack(spacing: 8) {
                    ControlIconButton(
                        systemName: "plus.bubble",
                        help: "Start a new chat in this project",
                        circleSize: 32,
                        action: { newChat(in: path) }
                    )
                    ControlIconButton(
                        systemName: rightPanelDocked ? "pin.slash" : "pin",
                        help: rightPanelDocked
                            ? "Float over the content"
                            : "Dock beside the content",
                        circleSize: 32,
                        action: { toggleRightPanelPinned() }
                    )
                    ControlIconButton(
                        systemName: "xmark", help: "Close", circleSize: 32,
                        action: closeRightPanel
                    )
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, 4)

            projectPanelSegments
                .padding(.top, 16)
                .padding(.horizontal, 2)

            Group {
                switch projectPanelTab {
                case .chat: projectChatPage(for: path)
                case .terminal: projectTerminalPage(for: path)
                case .server: projectServerPage(for: path)
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The Chat / Terminal / Server pill bar — one capsule container, the
    /// active segment filled.
    private var projectPanelSegments: some View {
        HStack(spacing: 0) {
            ForEach(ProjectPanelTab.allCases, id: \.self) { tab in
                let active = projectPanelTab == tab
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Theme.text : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Capsule().fill(active ? Theme.rowSelected : .clear))
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) {
                            projectPanelTab = tab
                        }
                    }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.rowHovered.opacity(0.5)))
        .overlay(Capsule().strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    /// The chats the panel lists (same filter the sidebar nesting used):
    /// dismissed husks and rolled-over segments hidden, pinned first.
    private func listedChats(for path: String) -> [ChatSessionRef] {
        let all = (chatIndex.chats[path] ?? []).filter {
            !capsuleStore.isDismissed($0.filePath)
                && !chatMeta.supersededFiles.contains($0.filePath)
        }
        return chatMeta.arrangeSidebar(all)
    }

    private func archivedChats(for path: String) -> [ChatSessionRef] {
        (chatIndex.chats[path] ?? []).filter {
            chatMeta.archived.contains($0.filePath)
                && !capsuleStore.isDismissed($0.filePath)
                && !chatMeta.supersededFiles.contains($0.filePath)
        }
    }

    /// Chat page: every chat as a two-line row (title + timestamp over a
    /// one-line snippet) — no truncation, the list just scrolls — with
    /// the Archived fold at the bottom. New chat lives in the header.
    private func projectChatPage(for path: String) -> some View {
        let refs = listedChats(for: path)
        let archived = archivedChats(for: path)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(refs) { ref in
                    chatPanelRow(project: path, ref: ref)
                }
                if !archived.isEmpty {
                    PanelRow(action: {
                        if archivedShown.contains(path) {
                            archivedShown.remove(path)
                        } else {
                            archivedShown.insert(path)
                        }
                    }) { _ in
                        Text(archivedShown.contains(path)
                            ? "Hide archived" : "Archived (\(archived.count))")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 6)
                    }
                    if archivedShown.contains(path) {
                        ForEach(archived) { ref in
                            chatPanelRow(project: path, ref: ref)
                        }
                    }
                }
            }
            // Breathing room between the rows and the panel's edges.
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }

    /// One chat: title + pin/branch marks + (busy dot | timestamp, or the
    /// archive ✕ on hover) over the snippet. Keeps every function the old
    /// nested rows had — click opens, drag attaches to a composer,
    /// right-click carries the full menu.
    private func chatPanelRow(project: String, ref: ChatSessionRef) -> some View {
        let file = ref.filePath
        let open = chatTarget?.path == project && chatTarget?.sessionFile == file
        let phase = ChatSessionHub.shared.sessions[file]?.phase
        let busy = phase != nil && phase != .idle
        return PanelRow(
            selected: open,
            action: { openChat(project: project, file: file) }
        ) { hovered in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chatTitler.displayTitle(ref))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if chatMeta.pinned.contains(file) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if chatMeta.branches[file] != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.textSecondary)
                            .help("Branched from another chat")
                    }
                    Spacer(minLength: 8)
                    if hovered, !busy {
                        RowActionIcon(symbol: "xmark", help: "Archive chat") {
                            archiveChat(project: project, file: file)
                        }
                    } else if busy {
                        Circle()
                            .fill(Theme.dotActive)
                            .frame(width: 6, height: 6)
                    } else {
                        Text(Self.chatTimestamp(ref.modified))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                // The snippet observes its own store in a leaf view, so
                // snippets streaming in re-render one row each — not the
                // whole window (the root observed the store before, and
                // every publish invalidated the full body).
                SnippetText(file: file)
            }
            .padding(.vertical, 7)
        }
        .contextMenu { chatContextMenu(project: project, ref: ref) }
        .onDrag {
            let reference = ChatCapsule(
                id: file, project: project, sourceFile: file,
                harness: ref.harness.rawValue,
                title: chatTitler.displayTitle(ref), sealedAt: Date()
            ).referenceText
            return NSItemProvider(object: reference as NSString)
        }
        .onAppear { ChatIndexStore.Snippets.shared.ensure(ref) }
    }

    /// "Today 2:13 PM" for today's chats, "9/10/26" otherwise.
    private static func chatTimestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(
            .dateTime.month(.defaultDigits).day().year(.twoDigits)
        )
    }

    /// Same actions the sidebar's NSMenu carried, as a SwiftUI menu.
    @ViewBuilder
    private func chatContextMenu(project: String, ref: ChatSessionRef) -> some View {
        let file = ref.filePath
        Button("Rename…") { ChatRowActions.promptRename(ref) }
        Button(chatMeta.pinned.contains(file) ? "Unpin" : "Pin") {
            chatMeta.togglePin(file)
        }
        Button(chatMeta.archived.contains(file) ? "Unarchive" : "Archive") {
            // Archiving goes through archiveChat, not a bare flag flip —
            // it refuses a chat mid-turn, shuts the warm session down,
            // and moves the open view off the archived chat.
            if chatMeta.archived.contains(file) {
                chatMeta.toggleArchive(file)
            } else {
                archiveChat(project: project, file: file)
            }
        }
        Divider()
        Button("Branch Chat") {
            ChatRowActions.duplicate(ref, project: project, asBranch: true)
        }
        Button("Duplicate") { ChatRowActions.duplicate(ref, project: project) }
        Button("Copy Transcript") { ChatRowActions.copyTranscript(ref) }
        Button("Reveal Transcript in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: file)]
            )
        }
        Divider()
        Button("Delete Chat") { deleteChat(project: project, file: file) }
    }

    /// Terminal page: "+ New Terminal", then the project's open shells —
    /// click selects (focus follows), hover carries the close.
    private func projectTerminalPage(for path: String) -> some View {
        let tabs = terminals.tabs[path] ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelRow(action: { newTerminal(in: path) }) { _ in
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                        Text("New Terminal")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 9)
                }
                ForEach(tabs, id: \.id) { tab in
                    let isMain = tab.id == tabs.first?.id
                    let target: SidebarSelection = isMain
                        ? .project(path) : .shell(path: path, tab: tab.id)
                    PanelRow(
                        selected: selection == target,
                        action: { select(target) }
                    ) { hovered in
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Text(tab.customName ?? name(of: path))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if hovered {
                                RowActionIcon(
                                    symbol: "xmark", help: "Close terminal"
                                ) {
                                    if isMain {
                                        closeTerminal(path)
                                    } else {
                                        terminals.closeTab(path: path, tabID: tab.id)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }

    /// Server page: the project's dev servers (live, then recent) —
    /// clicking one pushes to its server page.
    private func projectServerPage(for path: String) -> some View {
        let live = servers.devServers.filter { $0.cwd == path }
        let livePorts = Set(live.map(\.port))
        let recents = servers.recents.filter {
            $0.projectPath == path && !livePorts.contains($0.port)
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if live.isEmpty && recents.isEmpty {
                    Text("No dev server detected in this project.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 12)
                        .padding(.horizontal, 10)
                }
                ForEach(live, id: \.id) { server in
                    PopoverRow(height: 38, action: {
                        toggleRightPanel(.server(server.id))
                    }) { hovered in
                        ServerRow(
                            server: server,
                            health: servers.health[server.id],
                            hovered: hovered,
                            selected: false
                        )
                    }
                }
                ForEach(recents, id: \.id) { recent in
                    PopoverRow(height: 28, action: {
                        toggleRightPanel(.server(recent.id))
                    }) { hovered in
                        ServerRow(recent: recent, hovered: hovered)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }

    /// Archive a chat: it folds under the project's Archived toggle,
    /// transcript untouched. A chat mid-turn keeps running.
    private func archiveChat(project: String, file: String) {
        guard !file.isEmpty,
              ChatSessionHub.shared.sessions[file]?.running != true else { return }
        ChatSessionHub.shared.forget(file: file)
        if !chatMeta.archived.contains(file) {
            chatMeta.toggleArchive(file)
        }
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
        case .row:
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
                    // Revealed by row hover; opacity (not `if`) so the
                    // header's layout never shifts under the pointer.
                    HeaderPlusButton(help: "New terminal in the home folder") {
                        let home = NSHomeDirectory()
                        if terminals.hasPane(for: home),
                           let tab = terminals.newTab(in: home) {
                            select(.shell(path: home, tab: tab.id))
                        } else {
                            select(.project(home))
                        }
                    }
                    .opacity(hovered ? 1 : 0)
                } else if title == "Projects" {
                    HeaderPlusButton(icon: "folder.badge.plus", help: "Add a project") {
                        addFolder()
                    }
                    .opacity(hovered ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.leading, 10)
            // 10 + half the 20pt button = the 20pt center line every
            // hover icon in the sidebar right-aligns to (RowChrome rows:
            // 3 inset + 8 padding + half an 18pt frame).
            .padding(.trailing, 10)

        case let .action(_, title):
            // The only action row today is "new-terminal" (the Terminals
            // section's stand-in while no shell is open).
            actionRowLabel(title: title, hovered: hovered)
                .onTapGesture { runAction("new-terminal") }

        case let .folder(path, folderName):
            // A project row (2026-09-20 layout): clicking it opens the
            // project's chat list in the right sheet and its chat home in
            // the center — nothing nests beneath it anymore. Hover carries
            // the quick actions ("+" starts a chat, the terminal glyph
            // adds an instance up in Terminals); a working chat anywhere
            // in the project surfaces as the trailing accent dot.
            let chatOpen = chatTarget?.path == path
            let busy = chatHub.sessions.values.contains {
                $0.projectPath == path && $0.phase != .idle
            }
            HStack(spacing: 9) {
                // Every project wears an icon (2026-09-17): its own
                // favicon/app icon when it ships one, the generic project
                // glyph otherwise.
                ZStack {
                    if let logo = ProjectLogoCache.logo(for: path) {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
                            // Tints template logos (dark monochrome glyphs)
                            // with the appearance; full-color ones ignore it.
                            .foregroundStyle(Theme.text)
                    } else {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 18, height: 18)
                Text(folderName)
                    // Regular weight at 0.85 — headers should sit in the
                    // chrome, not shout over the rows (2026-09-12).
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if busy, !hovered {
                    Circle()
                        .fill(Theme.dotActive)
                        .frame(width: 6, height: 6)
                }
                if hovered {
                    HStack(spacing: 1) {
                        RowActionIcon(
                            symbol: "plus", help: "New chat", size: 12
                        ) {
                            newChat(in: path)
                        }
                        RowActionIcon(
                            symbol: "terminal", help: "New terminal", size: 12
                        ) {
                            newTerminal(in: path)
                        }
                    }
                }
            }
            // The breathing room lives inside the row (and its hover
            // chrome), not as a gap between rows.
            .padding(.vertical, 2)
            .modifier(RowChrome(hovered: hovered, selected: chatOpen))
            .onTapGesture { openProjectChats(path) }

        case let .row(id, title):
            switch id {
            case let .project(path):
                let mainTab = terminals.tabs[path]?.first?.id
                let renaming = mainTab != nil
                    && renameTarget == mainTab.map { RenameTarget(path: path, tabID: $0) }
                SidebarRow(
                    name: renaming
                        ? currentRowName(path: path, tabID: mainTab!) : title,
                    hasTerminal: true,
                    // Gated on the process scan so a killed agent (no
                    // Stop hook ever fires) can't pulse forever.
                    working: terminals.agents[path] != nil
                        && notify.isWorking(path: path),
                    needsAttention: notify.hasAttention(path: path),
                    hovered: hovered,
                    selected: highlightedSelection == id,
                    onClose: { closeTerminal(path) },
                    renaming: renaming,
                    onRename: { result in
                        if let mainTab {
                            finishInlineRename(path: path, tabID: mainTab, result: result)
                        }
                    }
                )
            case let .shell(path, tabID):
                let renaming = renameTarget == RenameTarget(path: path, tabID: tabID)
                SidebarRow(
                    name: renaming ? currentRowName(path: path, tabID: tabID) : title,
                    hasTerminal: true,
                    working: terminals.agents[path] != nil
                        && notify.isWorking(path: path, tab: tabID),
                    needsAttention: notify.hasAttention(path: path, tab: tabID),
                    hovered: hovered,
                    selected: highlightedSelection == id,
                    onClose: { terminals.closeTab(path: path, tabID: tabID) },
                    renaming: renaming,
                    onRename: { result in
                        finishInlineRename(path: path, tabID: tabID, result: result)
                    }
                )
            }
        }
    }

    /// Everything `row(for:hovered:)` reads, flattened. Cheap to build and
    /// compare; keeps rows from being re-hosted on every poll.
    private func contentKey(for entry: SidebarEntry, hovered: Bool) -> String {
        switch entry {
        case let .header(title):
            // Hover is content here: the Terminals "+" reveals on it.
            return "h:\(title)|\(hovered ? "h" : "-")"
        case let .action(key, title):
            return "a:\(key)|\(title)|\(hovered ? "h" : "-")"
        case let .folder(path, folderName):
            let chatOpen = chatTarget?.path == path
            let busy = chatHub.sessions.values.contains {
                $0.projectPath == path && $0.phase != .idle
            }
            return "f:\(folderName)|\(busy ? "w" : "-")"
                + "|\(chatOpen ? "o" : "-")|\(hovered ? "h" : "-")"
        case let .row(id, title):
            // Only what the row RENDERS rides in the key — folding in
            // agent labels and git status re-hosted rows whose pixels
            // could not change, on every poll that moved either.
            let selected = highlightedSelection == id
            switch id {
            case let .project(path):
                let renaming = renameTarget?.path == path
                    && renameTarget?.tabID == terminals.tabs[path]?.first?.id
                let working = terminals.agents[path] != nil
                    && notify.isWorking(path: path)
                return [
                    title, "t",
                    working ? "w" : "-",
                    notify.hasAttention(path: path) ? "!" : "-",
                    selected ? "s" : "-",
                    hovered ? "h" : "-",
                    renaming ? "r" : "-",
                ].joined(separator: "|")
            case let .shell(path, tab):
                let bang = notify.hasAttention(path: path, tab: tab) ? "!" : "-"
                let renaming = renameTarget == RenameTarget(path: path, tabID: tab)
                let working = terminals.agents[path] != nil
                    && notify.isWorking(path: path, tab: tab)
                return "sh:\(title)|\(tab)|\(working ? "w" : "-")|\(bang)|\(selected ? "s" : "-")|\(hovered ? "h" : "-")|\(renaming ? "r" : "-")"
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
                }
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
        // Leaving chat mode must not depend on `.onChange(of: selection)`:
        // opening a chat never moves the selection, so clicking the
        // still-selected terminal row fires no change and the chat stayed
        // stuck on screen. Every select() means "show me that terminal".
        if target != nil { chatTarget = nil }
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

    /// What the sidebar HIGHLIGHTS as selected: nothing while a chat is
    /// on screen — the chat row wears the open state then, and a terminal
    /// row lit at the same time read as two selections. `selection` itself
    /// is untouched (git watch, status bar, and the return click's target
    /// all still need it).
    private var highlightedSelection: SidebarSelection? {
        chatTarget == nil ? selection : nil
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

    /// Invisible receiver for the menu's shortcut notifications. Split in
    /// two: one long onReceive chain is past what the type-checker will
    /// solve in reasonable time.
    private var shortcutListeners: some View {
        ZStack {
            primaryShortcutListeners
            chatListeners
        }
    }

    private var chatListeners: some View {
        Color.clear
            // A reply paragraph's "ask about this" — open (or toggle) the
            // thread panel in the right sheet.
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonOpenChatThread)
            ) { note in
                guard let info = note.userInfo,
                      let project = info["project"] as? String,
                      let file = info["file"] as? String,
                      let harness = info["harness"] as? String,
                      let anchor = info["anchor"] as? String else { return }
                toggleRightPanel(.chatThread(ChatThreadTarget(
                    project: project, file: file,
                    harnessRaw: harness, anchor: anchor
                )))
            }
            // A chat continued under a new transcript file (context
            // rollover, cross-harness transplant): follow it, so the
            // sidebar highlight and the seal-protection don't point at
            // the sealed predecessor.
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonChatRekeyed)
            ) { note in
                guard let project = note.userInfo?["project"] as? String,
                      let file = note.userInfo?["file"] as? String
                else { return }
                // Follow when the open chat is the one being rekeyed —
                // matched by the new project, or by the path the browser
                // was opened under (`fromPath`: a project-less New Chat
                // promoted into its chosen project).
                let fromPath = note.userInfo?["fromPath"] as? String
                guard chatTarget?.path == project
                    || (fromPath != nil && chatTarget?.path == fromPath)
                else { return }
                chatTarget = ChatTarget(path: project, sessionFile: file)
            }
            // The auto-seal sweep lives in CapsuleStore; the view's only
            // job is telling it which chat is on screen (protected).
            .onChange(of: chatTarget) { _, target in
                capsuleStore.activeChatFile = target?.sessionFile
            }
            // A CLI login flow (claude /login) runs in a home-directory
            // terminal pane — same pane→select→send pattern the server
            // panel's Start button uses.
            .onReceive(
                NotificationCenter.default.publisher(for: .houstonRunLoginCommand)
            ) { note in
                guard let command = note.userInfo?["command"] as? String
                else { return }
                let home = NSHomeDirectory()
                _ = terminals.pane(for: home)
                chatTarget = nil
                select(.project(home))
                terminals.send(command + "\n", to: home)
            }
    }

    private var primaryShortcutListeners: some View {
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
                    openCapsuleDialog(capsule)
                } else if let project = chatTarget?.path {
                    // The capsule was dissolved — land on the shelf. Open,
                    // never toggle: with the shelf already showing, a
                    // toggle would CLOSE it and the click would read as
                    // doing nothing.
                    if rightPanel != .capsules(project: project) {
                        toggleRightPanel(.capsules(project: project))
                    }
                }
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

/// One rail row for the instant-tooltip layer: label + position in the
/// rail's stack (the rule sits between rows 2 and 3).
private enum RailTipItem: Equatable {
    case newChat, tasks, servers, terminals, projects

    var label: String {
        switch self {
        case .newChat: "New Chat"
        case .tasks: "Tasks"
        case .servers: "Servers"
        case .terminals: "Terminals"
        case .projects: "Projects"
        }
    }

    var row: CGFloat {
        switch self {
        case .newChat: 0
        case .tasks: 1
        case .servers: 2
        case .terminals: 3
        case .projects: 4
        }
    }
}

/// `.onHover` as a passable modifier — lets a helper hand the same
/// enter/leave wiring to several buttons.
private struct HoverAction: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover(perform: action)
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
        let button = Button(action: action) {
            icon()
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(active
                            ? Theme.buttonActiveFill
                            : (hovered ? Theme.rowHovered : .clear))
                )
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: Theme.radiusControl)
                            .strokeBorder(Theme.buttonActiveStroke, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // Empty help = the caller labels the button itself (the rail's
        // instant tip layer) — don't stack the delayed system tooltip.
        return Group {
            if help.isEmpty { button } else { button.help(help) }
        }
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

/// A chat row's one-line snippet. Observes the snippet store HERE, in the
/// leaf — snippets stream in one file at a time, and observing from the
/// root view invalidated the entire window per publish.
private struct SnippetText: View {
    @ObservedObject private var snippets = ChatIndexStore.Snippets.shared
    let file: String

    var body: some View {
        let text = snippets.snippet(for: file) ?? ""
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }
}

/// A project-panel row: self-owned hover state, RowChrome highlight,
/// variable height (unlike `PopoverRow`, which fixes it).
private struct PanelRow<Content: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovered = false

    var body: some View {
        content(hovered)
            .modifier(RowChrome(hovered: hovered, selected: selected))
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
/// The sidebar panel's surface. Normally a frosted-glass panel with a
/// hairline on its top/right/bottom edges; in terminal view it goes
/// seamless — flat `sidebarFill`, no glass, no border — so the panel and
/// the page around the terminal read as one surface.
private struct SidebarSurface: ViewModifier {
    let shape: UnevenRoundedRectangle
    let seamless: Bool

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if seamless {
                        shape.fill(Theme.sidebarFill)
                    } else {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(Theme.sidebarFill.opacity(0.7))
                        }
                    }
                }
            )
            .clipShape(shape)
            .overlay {
                if !seamless {
                    // Hairline on top/right/bottom; the mask trims the
                    // left run, since the panel sits flush to the edge.
                    shape
                        .inset(by: 0.5)
                        .stroke(Theme.borderSidebar, lineWidth: 1)
                        .mask(Rectangle().padding(.leading, 2))
                }
            }
    }
}

/// One of the sidebar's three top tiles: icon over label in an even box,
/// a step darker than the sidebar panel, hairline border, hover lift.
/// The running-server tally: a soft green capsule badge — tinted fill,
/// text-grade green count, no stroke chrome.
private struct ServerCountBadge: View {
    let count: Int

    var body: some View {
        Text(String(count))
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.textPositive)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.dotActive.opacity(0.16)))
    }
}

private struct TopTileButton: View {
    let systemName: String
    let label: String
    var dot: Bool = false
    var active: Bool = false
    var iconTint: Color? = nil
    /// Draw the hand-drawn server glyph instead of an SF Symbol.
    var serverIcon: Bool = false
    /// Live tally (running dev servers) — when non-zero it REPLACES the
    /// server glyph as the tile's icon, in signal green.
    var count: Int = 0
    /// Narrow-sidebar mode: icon beside label in a short full-width row
    /// instead of icon over label in an even tile.
    var rowLayout: Bool = false
    let help: String
    let action: () -> Void
    @State private var hovered = false

    @ViewBuilder
    private func iconView(size: CGFloat) -> some View {
        if serverIcon {
            // The glyph goes signal-green while servers run; the count
            // rides separately as the soft capsule badge.
            ServerGlyph(
                color: count > 0
                    ? Theme.dotActive
                    : (iconTint ?? Theme.text.opacity(0.85)),
                size: size + 2
            )
        } else {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(iconTint ?? Theme.text.opacity(0.85))
        }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if rowLayout {
                    HStack(spacing: 8) {
                        iconView(size: 13)
                            .frame(width: 18)
                        Text(label)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if count > 0 {
                            ServerCountBadge(count: count)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34)
                } else {
                    VStack(spacing: 5) {
                        iconView(size: 14)
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
            }
            // Rest sits darker than the sidebar; active lifts to the
            // lighter fill. Hover is the sidebar rows' own wash
            // (`rowHovered`, translucent) layered over the rest fill, so
            // tiles and rows read as one hover language.
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSurface)
                    .fill(active ? Theme.tileActive : Theme.tileFill)
            )
            .overlay {
                if hovered, !active {
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(Theme.rowHovered)
                }
            }
            .overlay(alignment: .topTrailing) {
                if dot {
                    Circle()
                        .fill(Theme.dotDegraded)
                        .frame(width: 5, height: 5)
                        .padding(6)
                } else if count > 0, !rowLayout {
                    // The live tally in the tile's corner — the row
                    // layout carries it inline instead.
                    ServerCountBadge(count: count)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
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
                    // Top-level items: 14pt regular at 0.85 — a size step
                    // above the rows without weight or full-white glare.
                    Text(label)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text.opacity(0.85))
                    badge
                    Spacer(minLength: 8)
                    // The count rides the row's far edge, right-justified.
                    if count > 0 {
                        Text(String(count))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, label == nil ? 0 : 6)
            // Labeled items: 2px more air top and bottom, and the row
            // stretches the sidebar's width so the hover pill does too.
            .frame(width: label == nil ? 22 : nil, height: label == nil ? 22 : 30)
            .frame(
                maxWidth: label == nil ? nil : .infinity,
                alignment: .leading
            )
            // Badge INSIDE the button's frame, not overhanging the glyph —
            // an ancestor clips at the frame edge and was slicing the pill.
            .overlay(alignment: .topTrailing) {
                if label == nil { badge }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(active
                        ? Theme.buttonActiveFill
                        : (hovered ? Theme.rowHovered : .clear))
            )
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .strokeBorder(Theme.buttonActiveStroke, lineWidth: 1.5)
                }
            }
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
    var hasTerminal: Bool = false
    /// An extra terminal tab nested under its project's row: indented, no
    /// git dot (same repo as the parent), plain terminal glyph.
    var nested: Bool = false
    /// The pane's agent has a turn in flight — the dot pulses amber.
    var working: Bool = false
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
            if let diff {
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
    fileprivate func rowIconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        HoverBrightIcon(symbol: symbol, help: help, nested: nested, action: action)
    }
}

/// A `SidebarRow` trailing icon (the terminal ✕): no chrome, hover steps
/// the glyph up to full text color. A struct (not a helper func) because
/// the hover flag needs @State.
private struct HoverBrightIcon: View {
    let symbol: String
    let help: String
    let nested: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                // Width 18 puts the glyph on the sidebar's shared 20pt
                // right-align line (see the header's trailing padding).
                .frame(width: 18, height: nested ? 13 : 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
        // Same push grammar as the sheet's page swaps: the child change
        // list rides the trailing edge, the parent page the leading. The
        // ZStack keeps the two overlapping while the push runs.
        ZStack(alignment: .top) {
            if showingChangeList, let cwd = server.cwd {
                changeList(cwd: cwd)
                    .transition(MainWindowView.pageChild)
            } else {
                serverContent
                    .transition(MainWindowView.pageParent)
            }
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
                    action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showingChangeList = false
                        }
                    }
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
                HStack(spacing: 8) {
                    // The list's glyph, health-tinted — the page header
                    // reads as the row it was pushed from.
                    ServerGlyph(color: healthColor, size: 15)
                    Text(displayName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .help(details)
                Spacer(minLength: 8)
                moreMenu
                pinCloseControls
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showingChangeList = true
                }
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Edit and track")
            // Rows stack flush so the hairlines read as one linear list,
            // matching the SERVERS page.
            VStack(spacing: 0) {
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
                    HStack(spacing: 8) {
                        ServerGlyph(color: Theme.textSecondary, size: 15)
                        Text(displayName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    .help("Not running\n\(recent.projectPath)")
                    Spacer(minLength: 8)
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

/// A clickable row on the server page in the SAME anatomy and sizes as
/// `SheetServerRow` — icon centered in the fixed leading slot, title over
/// subtitle, full-width hairline underneath, hover pill. The trailing
/// affordance says what the click does: the redirect glyph for "opens a
/// window", a chevron for "drills into this sheet".
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                trailingGlyph
                    .opacity(hovered ? 1 : 0.4)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.borderSidebar)
                    .frame(height: 1)
                    .opacity(hovered ? 0 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var trailingGlyph: some View {
        switch trailing {
        case .redirect:
            SVGIcon(name: "redirect", size: 16)
                .foregroundStyle(Theme.heading)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.heading)
        }
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
    /// Glyph point size; the project-header actions run larger (12, the
    /// section-header "+" size) than the tiny ✕ (9).
    var size: CGFloat = 9
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: size >= 12 ? .medium : .semibold))
                // No hover pill anywhere in the sidebar (2026-09-13) —
                // the glyph stepping up to full text color is the state.
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .frame(width: 18, height: 18)
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
                .frame(width: 20, height: 20)
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
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text.opacity(0.85))
            }
        }
        .padding(.horizontal, labeled ? 6 : 0)
        .frame(width: labeled ? nil : 22, height: labeled ? 30 : 22)
        .frame(maxWidth: labeled ? .infinity : nil, alignment: .leading)
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
