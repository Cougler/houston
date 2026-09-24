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
    /// The project (chats) panel doesn't pin/unpin — it docks always and
    /// COLLAPSES instead (2026-09-22): tucked off the right edge with a
    /// small handle to bring it back.
    @State private var chatsPanelCollapsed = HoustonSettings.read().chatsPanelCollapsed
    /// The git page pushed inside the project panel (like a server's).
    @State private var projectPanelGit = false
    /// A server card floated beside the workspace sub-sidebar's row.
    @State private var subServerFlyoutID: String? = nil
    /// The top-bar chip whose dropdown is open (nil = none).
    @State private var barDropdown: WorkspaceItem? = nil
    /// The tasks sheet's navigation: nil shows All Tasks (the root), a path
    /// shows that project's page nested under it (Back pops to nil).
    @State private var taskSheetProject: String? = nil
    /// Sidebar popovers (2026-09-22): Tasks and Servers open beside
    /// their sidebar rows instead of in the right sheet.
    @State private var tasksPopoverShown = false
    @State private var serversPopoverShown = false
    /// The server page pushed inside the servers popover (nil = list).
    @State private var popoverServerID: String? = nil
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
    /// Within a project's workspace (chatTarget set): whether the detail
    /// surface shows the selected TERMINAL instead of the chat. The top
    /// bar and side panel stay either way — chat and terminal are two
    /// surfaces of one workspace.
    @State private var detailShowsTerminal = false
    /// The project panel's active page — reset to Chat on every project
    /// click (that's the click's intent); Terminal/Server are one tap away.
    /// The project panel's pushed page: a server id when its page is
    /// drilled into (the mock's chevron row), nil for the chat list.
    /// Everything project-scoped lives INSIDE the panel as a push
    /// (2026-09-21) — the old Chat/Terminal/Server segment bar is gone.
    @State private var projectPanelServer: String?
    /// Extra pages of chats the side panel's CHATS section has revealed —
    /// each "Show more" adds one page of ten. Resets whenever the
    /// workspace leaves the project, so coming back starts at ten again.
    @State private var chatsPagesRevealed = 0
    /// An image/file drag is over the window while a chat surface shows
    /// — the chat area wears the "Drop image anywhere" field.
    @State private var imageDropTargeted = false
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

    /// Everything right of the sidebar: the detail column, the workspace
    /// panel, and the right sheet's width reservation.
    private var contentArea: some View {
        HStack(spacing: 0) {
            detailColumn
                .frame(maxWidth: .infinity)
            // The project workspace panel (2026-09-23): a floating
            // rounded canvas on the right holding whichever workspace
            // items were placed in it. No items — no panel. ALWAYS
            // mounted, width animated to zero when closed (whole pixels
            // per frame): an animated `if` insertion interpolates the
            // HStack through fractional layouts, and the card's rows
            // re-render mid-slide (chatIndex refresh, snippets, titler)
            // — the same baked-subpixel blur the right sheet had.
            workspacePanelColumn(chatTarget?.path)
            // Reserve the sheet's width in the layout. The sheet itself
            // always draws in the overlay flush with the right edge, so
            // pin/unpin animates nothing but this width (and the scrim) —
            // no re-parenting, no jump. The project sidebar reserves even
            // unpinned: chat content centers between the two sidebars.
            // Whole pixels per frame, same rule as the sheet's slide: a
            // fractional reservation makes the centered chat column
            // fractional mid-slide, and text streaming in right then
            // bakes the subpixel phase (soft on a 1x display).
            Color.clear
                .modifier(WholePixelWidth(width: rightPanelReservedWidth))
        }
    }

    private var chromeBackground: Color {
        // Chat mode's chrome matches the chat page, which matches the
        // empty state (2026-09-21) — one content surface everywhere.
        if chatTarget != nil { return Theme.emptyStateBackground }
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
    // Rounded for the same reason as `rightSheetWidth`: fractional
    // widths land text on half pixels and it renders soft.
    @State private var sidebarWidth: CGFloat =
        min(max(CGFloat(HoustonSettings.read().sidebarWidth), 180), 420)
            .rounded()
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
    /// Fixed width (2026-09-21): the sheet is not resizable — one less
    /// source of geometry drift, and the panel's layout is designed for
    /// exactly this width.
    private let rightSheetWidth: CGFloat = 292

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
            contentArea
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
        // Window-wide image drop: an image or file dragged ANYWHERE over
        // the window (sidebar, panel, sky, the composer's own text) lands
        // in the visible chat's composer. A delegate, not a closure — the
        // root body is at the type-checker's limit, and the delegate also
        // gates on the drag's flavor so text drags never light the field.
        .onDrop(of: [.image, .fileURL], delegate: WindowImageDropDelegate(
            targeted: $imageDropTargeted, accepts: chatSurfaceShowing
        ))
        .overlayPreferenceValue(SidebarFlyoutAnchorKey.self, sidebarFlyoutsResolved)
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
        // solar-system empty state, not a dead detail page — unless the
        // workspace was showing that terminal as its surface, in which
        // case the chat underneath comes back (the selection still goes
        // nil; the nil rule below keeps the workspace).
        .onChange(of: terminalPaths) { _, paths in
            if case let .project(path) = selection, !paths.contains(path),
               !terminals.hasPane(for: path) {
                if chatTarget?.path == path { detailShowsTerminal = false }
                selection = nil
            }
        }
        .onChange(of: selection) { _, newValue in
            // Picking a sidebar row means "show me that terminal" — chat
            // mode never follows the selection. EXCEPT a terminal in the
            // workspace's own project: that swaps the surface under the
            // top bar + side panel (`select` set detailShowsTerminal),
            // so the workspace must survive here or the rule in `select`
            // is dead on arrival. A NIL selection never leaves the
            // workspace either: it only ever means "the terminal closed"
            // (the two close paths are its sole writers), and closing the
            // terminal you opened from a chat returns you to that chat.
            if let path = newValue?.projectPath, path != chatTarget?.path {
                chatTarget = nil
            }
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
                // The workspace's terminal surface closed: back to the
                // chat, not to whichever sibling terminal survived.
                if chatTarget?.path == path { detailShowsTerminal = false }
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
    /// the top list (New Chat, New Terminal, Tasks, Servers — same
    /// actions, Servers opens the right sheet, not a flyout) above the
    /// rule, then the table's sections (Terminals, Projects) as flyout
    /// buttons below it.
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
                LucideIcon("square-pen", size: 15)
                    .foregroundStyle(Theme.textSecondary)
            }
            .modifier(railTipHover(.newChat))
            .padding(.top, 14)
            RailButton(
                help: "",
                active: false,
                action: { runAction("new-terminal") }
            ) {
                LucideIcon("square-terminal", size: 15)
                    .foregroundStyle(Theme.textSecondary)
            }
            .modifier(railTipHover(.newTerminal))
            RailButton(
                help: "",
                active: rightPanel == .tasks,
                action: { openAllTasks() }
            ) {
                LucideIcon("list-checks", size: 15)
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
                // Same quiet language as the expanded row: neutral glyph,
                // the count riding its corner in plain gray.
                ServerGlyph(color: Theme.textSecondary, size: 15)
                    .overlay(alignment: .topTrailing) {
                        if !servers.devServers.isEmpty {
                            Text(String(servers.devServers.count))
                                .font(.system(size: 8, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
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
                    LucideIcon(installer.isBusy
                        ? "refresh-ccw"
                        : "circle-arrow-down", size: 15)
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
                icon: "panel-left",
                help: sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar",
                action: toggleSidebarCollapse
            )
            // Settings and tasks ride the strip beside the toggle —
            // bare glyphs, out of the sidebar's row stack. The bell was
            // removed 2026-09-23; EventFeed still drives the menubar dot.
            settingsMenu()
            tasksStripButton
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

    /// Tasks in the titlebar strip (2026-09-23 — was a sidebar row):
    /// same hover chrome as the collapse toggle, opening the tasks menu
    /// straight below the glyph.
    private var tasksStripButton: some View {
        FooterIconButton(
            icon: "list-checks",
            help: "Tasks across all projects",
            action: { tasksPopoverShown.toggle() }
        )
        .overlay(alignment: .topTrailing) {
            if tracked.attentionCount > 0 {
                Circle()
                    .fill(Theme.dotDegraded)
                    .frame(width: 5, height: 5)
                    .offset(x: -1, y: 2)
            }
        }
        .anchorPreference(key: SidebarFlyoutAnchorKey.self, value: .bounds) {
            ["tasks": $0]
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
                            .fill(Theme.menuFill)
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
                        .fill(Theme.menuFill)
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
                        .fill(Theme.menuFill)
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

    /// Layout width the right sheet takes. The chats panel is a floating
    /// CARD that still owns its layout slot (per the mock — content sits
    /// beside it, never under it), so it reserves card + insets unless
    /// collapsed; other panels reserve only when pinned.
    private var rightPanelReservedWidth: CGFloat {
        guard let rightPanel else { return 0 }
        if case .chats = rightPanel {
            return chatsPanelCollapsed ? 0 : rightSheetWidth + 24
        }
        return rightPanelDocked ? rightSheetWidth : 0
    }

    /// Docked chrome/geometry for the sheet: the chats panel always
    /// renders as the floating card (the mock); everything else follows
    /// the user's pin choice.
    private var sheetDocked: Bool {
        if case .chats = effectiveRightPanel { return false }
        return rightPanelDocked
    }

    private func setChatsPanelCollapsed(_ collapsed: Bool) {
        withAnimation(sheetSpring) { chatsPanelCollapsed = collapsed }
        updateSettings { $0.chatsPanelCollapsed = collapsed }
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
        // A tucked chats panel slides out like a closed sheet but stays
        // "open" in state — the handle brings it back instantly.
        let open = rightPanel != nil
        ZStack(alignment: .topTrailing) {
        // Floating: a detached card hugging the window's top-right
        // corner (12px insets, 2026-09-22 — was 32px and 80% height).
        // Docked: the full-height strip, part of the page. The
        // GeometryReader spans the window but only the sheet itself is
        // hit-testable.
        GeometryReader { geo in
            rightSheet
                // `.rounded()`: a fractional card frame invites
                // half-pixel layout inside it.
                .frame(height: sheetDocked
                    ? geo.size.height : (geo.size.height * 0.86).rounded())
                .padding(.top, sheetDocked ? 0 : 12)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: .topTrailing
                )
        }
        // Slide on WHOLE PIXELS only (the real root of the blur, found
        // 2026-09-21 after three partial fixes): opening fires async work
        // that publishes mid-slide — chatIndex.refresh, every row's
        // snippet parse, titler results — and any row that re-renders in
        // that window rasterizes its glyphs at the sheet's then-FRACTIONAL
        // x. Nothing re-invalidates those rasters once the spring settles
        // on an integral position, so the baked subpixel phase stays: a
        // full smeared pixel on a 1x display (the external monitor), near
        // invisible at 2x — which is why it was intermittent and display-
        // dependent. The left sidebar never blurred because its content is
        // leading-anchored (x stays integral while width animates); this
        // sheet is trailing-anchored, fractional the whole way in. The
        // animatable modifier rounds the inset EVERY FRAME, so there is no
        // instant at which a re-render can bake a fractional phase.
        .modifier(WholePixelTrailingInset(
            inset: open ? 0 : -(rightSheetWidth + 40)))
        .allowsHitTesting(open)
        // The project sidebar tracks the project view: entering one (any
        // chatTarget — home or a chat) summons it, wherever the target
        // was set from (row click, rekey, banner route); leaving closes
        // it. Attached here, not the root body — the sheet layer is
        // always mounted, and one more root modifier tips the
        // type-checker's expression limit.
        .onChange(of: chatTarget) { old, new in
            // The workspace sub-sidebar tracks chatTarget directly now
            // (2026-09-22); a legacy chats sheet just closes.
            if case .chats = rightPanel { closeRightPanel() }
            // Leaving the project (or the workspace) folds the CHATS
            // section back to its first page.
            if old?.path != new?.path { chatsPagesRevealed = 0 }
        }
        // Once the close animation lands, drop the sheet's render
        // fallback — a closed sheet keeps building `lastRightPanel`'s
        // content on every body evaluation otherwise.
        .onChange(of: rightPanel) { _, panel in
            guard panel != nil else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if rightPanel == nil { lastRightPanel = nil }
                }
                return
            }
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
                        icon: rightPanelDocked
                            ? "pin-off" : "pin",
                        help: rightPanelDocked
                            ? "Float over the content"
                            : "Dock beside the content",
                        bare: true,
                        circleSize: 32,
                        action: { toggleRightPanelPinned() }
                    )
                    ControlIconButton(
                        icon: "x",
                        help: "Close",
                        circleSize: 32,
                        action: closeRightPanel
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            // ZStack: while a push runs, the outgoing and incoming pages
            // must overlap in the same slot — bare ConditionalContent in
            // the VStack let them stack instead of sliding over each other.
            ZStack(alignment: .top) { rightSheetContent }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, 10)
                // Docked, the right edge gets breathing room to mirror the
                // left-side gap against the terminal; floating keeps the
                // tight edge.
                .padding(.trailing, sheetDocked ? 16 : 10)
                .padding(.top, serverChromeHidden ? 10 : 0)
                .padding(.bottom, 10)
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
            cornerRadius: sheetDocked ? 0 : 16))
        .overlay(
            RoundedRectangle(cornerRadius: sheetDocked ? 0 : 16)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                .opacity(sheetDocked ? 0 : 1)
        )
        .padding(.trailing, sheetDocked ? 0 : 12)
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
            LucideIcon("chevron-right", size: 10)
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
    ///
    /// Whole-pixel slides, not `.move` (2026-09-21): `.move` interpolates
    /// through fractional offsets, so a row re-rendering mid-push (store
    /// tick, snippet landing) bakes a subpixel glyph phase that survives
    /// the settle — the same blur family as the sheet's own slide — and
    /// an interrupted `.move` froze content AT a fractional offset. The
    /// rounded slide keeps every frame on the pixel grid; a freeze lands
    /// sharp. 352 clears the 320pt sheet fully; the card's clip hides the
    /// overshoot.
    static let pageParent = AnyTransition.modifier(
        active: WholePixelSlide(x: -352), identity: WholePixelSlide(x: 0))
    static let pageChild = AnyTransition.modifier(
        active: WholePixelSlide(x: 352), identity: WholePixelSlide(x: 0))

    @ViewBuilder
    private var rightSheetContent: some View {
        switch effectiveRightPanel {
        case .git:
            // Terminal view resolves via the selection; the workspace
            // column's Branches section opens it from chat view, where
            // only chatTarget knows the project.
            if let path = selection?.projectPath ?? chatTarget?.path {
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
            ScrollView {
                serversListPanel { sid in
                    withAnimation(sheetSpring) { rightPanel = .server(sid) }
                }
            }
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
            // No .move transition here, deliberately: the panel isn't a
            // push/pop pair member, and an interrupted move (a tab reset
            // or store tick mid-slide) left the content frozen at a
            // FRACTIONAL offset — the whole panel rendered soft/blurry
            // until the next real layout pass (e.g. a divider drag).
            chatListPanel(for: project)
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
            TipCard(text: tip.label)
                .offset(x: railWidth + 8, y: railTipTop(tip))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Vertical center of a rail row's tooltip: the rows stack from the
    /// panel top in 36pt steps (30pt button + 6 spacing), with the rule
    /// block (5pt + 6 spacing) between the top quartet and the sections;
    /// the ~23pt tip card centers on the 30pt button.
    private func railTipTop(_ tip: RailTipItem) -> CGFloat {
        let rowTop = sidebarTuckTop + 14 + tip.row * 36
            + (tip.row >= 4 ? 11 : 0)
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
        // Panel top + inner padding (14), then the top quartet (four 30pt
        // buttons + 6pt spacings) and the rule block (5pt + 6 spacing)
        // sit above the first flyout button; each further row is 36pt.
        return sidebarTuckTop + 14 + 4 * 36 + 11 + index * 36
    }

    @ViewBuilder
    private func railIcon(_ section: RailSection) -> some View {
        switch section {
        case .terminals:
            LucideIcon("square-terminal", size: 15)
                .foregroundStyle(Theme.textSecondary)
        case .servers:
            ServerGlyph(color: Theme.textSecondary, size: 15)
        case .projects:
            LucideIcon("package", size: 15)
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
        // Down THEN left (2026-09-23), with a soft handoff: the second
        // phase starts as the first is settling (~75% through, in its
        // spring tail), not 0.1s in — early overlap read as one skewed
        // diagonal, a hard stop read as two mechanical steps. Low bounce
        // so the tail doesn't wobble under the handoff.
        if collapsed {
            withAnimation(.spring(duration: 0.32, bounce: 0.06)) {
                sidebarTopTucked = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard seq == collapseStageSeq else { return }
                withAnimation(.spring(duration: 0.36, bounce: 0.06)) {
                    sidebarCollapsed = true
                }
            }
        } else {
            // Reverse: right (width) first, the top pops up as it settles.
            withAnimation(.spring(duration: 0.36, bounce: 0.06)) {
                sidebarCollapsed = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) {
                guard seq == collapseStageSeq else { return }
                withAnimation(.spring(duration: 0.32, bounce: 0.06)) {
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
                    LucideIcon("square-terminal", size: 22)
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
                    LucideIcon("package", size: 22)
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
                    RowActionIcon(symbol: "square-terminal", help: "New terminal") {
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
            LucideIcon(icon, size: 13)
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


    /// New Chat, New Terminal, Tasks, Servers — a plain list at the TOP
    /// of the sidebar (2026-09-21 — the tile grid is gone; these read
    /// like the table's own rows). Tasks and Servers open the right
    /// sheet; New Chat opens a project-less chat (home stands in for its
    /// path until the composer's chip sets one); New Terminal opens the
    /// home shell — the standing affordance now that an empty Terminals
    /// section no longer renders.
    private var sidebarTopCluster: some View {
        VStack(spacing: 2) {
            TopListRow(
                icon: "square-pen",
                label: "New Chat",
                active: chatTarget == ChatTarget(
                    path: NSHomeDirectory(), sessionFile: nil),
                help: "Start a new chat",
                action: {
                    chatTarget = ChatTarget(
                        path: NSHomeDirectory(), sessionFile: nil)
                }
            )
            TopListRow(
                icon: "square-terminal",
                label: "New Terminal",
                help: "Open a terminal",
                action: { runAction("new-terminal") }
            )
            // Tasks moved into the titlebar strip beside the bell
            // (2026-09-23) — see `tasksStripButton`.
            TopListRow(
                icon: "server",
                label: "Servers",
                active: serversPopoverShown,
                serverIcon: true,
                count: servers.devServers.count,
                help: "Dev servers",
                action: {
                    popoverServerID = nil
                    serversPopoverShown.toggle()
                }
            )
            // The servers flyout is a CUSTOM card (no NSPopover — its
            // edge arrow is unwanted), anchored to this row: the anchor
            // resolves in the ROOT's coordinate space at the overlay, so
            // the card lands beside the row regardless of clipping,
            // padding, or safe-area shifts along the way.
            .anchorPreference(key: SidebarFlyoutAnchorKey.self, value: .bounds) {
                ["servers": $0]
            }
        }
        // No cluster padding — RowChrome's own `rowInset` is the only
        // horizontal inset, so these align exactly with the table's rows.
        // One section gap's worth before the table — the same 20pt a
        // header box puts between the table's own sections.
        .padding(.bottom, 20)
    }

    /// The server list: running then stopped, each row handed to
    /// `onOpen` — the right sheet pushes its server page, the sidebar
    /// popover pushes in place.
    private func serversListPanel(onOpen: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !servers.devServers.isEmpty {
                sheetSectionLabel("RUNNING")
                ForEach(servers.devServers, id: \.id) { server in
                    SheetListRow(
                        title: server.project ?? server.command,
                        subtitle: "localhost:" + String(server.port),
                        onTap: { onOpen(server.id) },
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
                        onTap: { onOpen(recent.id) },
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

    // MARK: - Sidebar popovers (Tasks / Servers)

    /// The servers flyout (2026-09-22 mock): a CUSTOM card beside the
    /// sidebar's Servers row — no NSPopover, so no edge arrow. Page one
    /// lists ACTIVE servers only; a click pushes the server's compact
    /// card (back circle + name header, Browser/Inspector rows, sharing
    /// toggles, Stop). No scrolling, no pinning, no remove — the flyout
    /// is unassociated with the right sheet.
    /// Root overlay: resolves the sidebar rows' anchors into the root's
    /// coordinate space and floats the open card beside its row.
    @ViewBuilder
    func sidebarFlyoutsResolved(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if serversPopoverShown, let anchor = anchors["servers"] {
                    serversFlyoutLayer(proxy[anchor])
                }
                if tasksPopoverShown, let anchor = anchors["tasks"] {
                    tasksFlyoutLayer(proxy[anchor], in: proxy.size)
                }
                if let sid = subServerFlyoutID,
                   let anchor = anchors["subserver:" + sid]
                       ?? anchors["barchip:servers"] {
                    subServerFlyoutLayer(proxy[anchor], sid, in: proxy.size)
                }
                if let item = barDropdown, let path = chatTarget?.path,
                   let anchor = anchors["barchip:" + item.rawValue] {
                    barDropdownLayer(
                        proxy[anchor], item, path: path, in: proxy.size
                    )
                }
            }
        }
    }

    /// A bar chip's dropdown: shadcn popover chrome (tight padding,
    /// card fill, hairline, soft shadow) holding the item's rows, headed
    /// by its label and the EXPAND control that moves the item into the
    /// side panel.
    private func barDropdownLayer(
        _ chipFrame: CGRect, _ item: WorkspaceItem, path: String,
        in bounds: CGSize
    ) -> some View {
        let width: CGFloat = 260
        let x = min(max(12, chipFrame.minX), bounds.width - width - 12)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Theme.quick) { barDropdown = nil }
                }
            VStack(alignment: .leading, spacing: 2) {
                // Same header grammar and control size as the side
                // panel's module cards: caps title, then the square
                // add + move controls in the corner.
                HStack(spacing: 6) {
                    Text(item.rawValue.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(Theme.heading)
                        .padding(.leading, 8)
                    Spacer(minLength: 8)
                    PanelControlButton(
                        icon: "plus", help: addHelp(item),
                        action: {
                            withAnimation(Theme.quick) { barDropdown = nil }
                            addAction(item, path: path)
                        }
                    )
                    PanelControlButton(
                        icon: "dock-right", help: "Move into the side panel",
                        action: {
                            withAnimation(sheetSpring) {
                                barDropdown = nil
                                moveToPanel(item)
                            }
                        }
                    )
                }
                .frame(height: 28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        dropdownRows(item, path: path)
                    }
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusFloat)
                    .fill(Theme.menuFill)
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
            .offset(x: x, y: chipFrame.maxY + 8)
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    /// The dropdown's rows — same row grammar as the side panel, with
    /// every action also dismissing the dropdown (except a server row,
    /// which hands off to the server card anchored at the chip).
    @ViewBuilder
    private func dropdownRows(_ item: WorkspaceItem, path: String) -> some View {
        switch item {
        case .branches:
            if let branch = BranchPeek.branch(path) {
                SubSidebarRow(
                    title: branch,
                    dot: git.rowStatuses[path]?.isDirty == true
                        ? Theme.dotDegraded : Theme.dotActive,
                    selected: false
                ) {
                    withAnimation(Theme.quick) { barDropdown = nil }
                    toggleRightPanel(.git)
                }
            } else {
                dropdownEmpty("Not a git repository")
            }
        case .servers:
            let live = servers.devServers.filter { $0.cwd == path }
            if live.isEmpty {
                SubSidebarRow(
                    title: "Start server", dot: Theme.dotIdle,
                    muted: true, selected: false
                ) {
                    withAnimation(Theme.quick) { barDropdown = nil }
                    startProjectDevServer(path)
                }
            }
            ForEach(live, id: \.id) { server in
                SubSidebarRow(
                    title: "Localhost:" + String(server.port),
                    dot: Theme.dotActive,
                    selected: subServerFlyoutID == server.id
                ) {
                    // Hand off to the server card; it anchors at the
                    // chip once the dropdown goes.
                    withAnimation(Theme.quick) {
                        barDropdown = nil
                        subServerFlyoutID = server.id
                    }
                }
            }
        case .terminals:
            if (terminals.tabs[path] ?? []).isEmpty {
                dropdownEmpty("No terminals open")
            }
            ForEach(terminals.tabs[path] ?? [], id: \.id) { tab in
                let isMain = terminals.tabs[path]?.first?.id == tab.id
                SubSidebarRow(
                    title: tab.customName ?? name(of: path),
                    selected: false
                ) {
                    withAnimation(Theme.quick) { barDropdown = nil }
                    select(isMain
                        ? .project(path) : .shell(path: path, tab: tab.id))
                }
            }
        case .chats:
            if listedChats(for: path).isEmpty {
                dropdownEmpty("No chats yet")
            }
            ForEach(listedChats(for: path)) { ref in
                SubSidebarRow(
                    title: chatTitler.displayTitle(ref),
                    busy: {
                        guard let phase = ChatSessionHub.shared
                            .sessions[ref.filePath]?.phase else { return false }
                        return phase != .idle
                    }(),
                    selected: chatTarget?.sessionFile == ref.filePath
                ) {
                    withAnimation(Theme.quick) { barDropdown = nil }
                    openChat(project: path, file: ref.filePath)
                }
            }
        }
    }

    private func dropdownEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
    }

    /// A running server's card, floated beside its anchor. Anchors near
    /// the right edge (the workspace panel's rows, the bar chips) open
    /// to the LEFT of the anchor; only when neither side fits does it
    /// drop below, right-aligned.
    private func subServerFlyoutLayer(
        _ rowFrame: CGRect, _ sid: String, in bounds: CGSize
    ) -> some View {
        let cardWidth: CGFloat = 300
        let rightX = rowFrame.maxX + 10
        let leftX = rowFrame.minX - cardWidth - 10
        let x: CGFloat
        let y: CGFloat
        if rightX + cardWidth + 12 <= bounds.width {
            x = rightX
            y = max(8, rowFrame.minY - 8)
        } else if leftX >= 12 {
            x = leftX
            y = max(8, rowFrame.minY - 8)
        } else {
            x = min(rowFrame.maxX, bounds.width - 12) - cardWidth
            y = rowFrame.maxY + 8
        }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { subServerFlyoutID = nil }
            Group {
                if let server = liveServer(for: sid) {
                    ServerFlyoutCard(server: server, share: share, relay: relay)
                } else {
                    rightSheetPlaceholder("This server is no longer listening.")
                }
            }
            .padding(18)
            .frame(width: 300)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusFloat)
                    .fill(Theme.menuFill)
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
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .offset(x: -8)))
        }
    }

    /// The tasks flyout: same card chrome and placement grammar as the
    /// servers flyout, wrapping the tasks navigator. The card may run to
    /// ~80% of the window's height before its list scrolls.
    private func tasksFlyoutLayer(
        _ rowFrame: CGRect, in bounds: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { tasksPopoverShown = false }
            tasksPopoverContent(maxHeight: bounds.height * 0.8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .fill(Theme.menuFill)
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
                // Straight below the strip glyph, left edges aligned.
                .offset(
                    x: max(8, rowFrame.minX - 4),
                    y: rowFrame.maxY + 8
                )
                .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }

    @ViewBuilder
    private func serversFlyoutLayer(_ rowFrame: CGRect) -> some View {
        if serversPopoverShown {
            ZStack(alignment: .topLeading) {
                // Scrim: any click outside dismisses (and is consumed).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        serversPopoverShown = false
                        popoverServerID = nil
                    }
                Group {
                    if let sid = popoverServerID,
                       let server = liveServer(for: sid) {
                        ServerFlyoutCard(
                            server: server, share: share, relay: relay,
                            onBack: {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    popoverServerID = nil
                                }
                            }
                        )
                    } else {
                        serversFlyoutList
                    }
                }
                .padding(18)
                .frame(width: 300)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusFloat)
                        .fill(Theme.menuFill)
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
                .offset(
                    x: rowFrame.maxX + 10,
                    y: max(8, rowFrame.minY - 8)
                )
                .transition(.opacity.combined(with: .offset(x: -8)))
            }
        }
    }

    /// Page one: active servers only — name over its green localhost
    /// address, chevron trailing.
    private var serversFlyoutList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Servers")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 8)
            if servers.devServers.isEmpty {
                Text("No servers running")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 4)
            }
            ForEach(servers.devServers, id: \.id) { server in
                ServerFlyoutListRow(server: server) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        popoverServerID = server.id
                    }
                }
            }
        }
    }

    /// The tasks popover (2026-09-23): no navigator, no breadcrumbs —
    /// one flat list of every task grouped by project. The right sheet's
    /// tasks page keeps the full navigator.
    private func tasksPopoverContent(maxHeight: CGFloat) -> some View {
        // Height comes from the content (the list caps itself at the
        // window-relative maximum); only the width is pinned here.
        TasksMenuList(tracked: tracked, maxHeight: maxHeight)
            .frame(width: 300)
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
            // The bar keeps its place under every open pane — including
            // the workspace's terminal surface; its components only
            // appear while a session runs. Only the chat surface goes
            // without it.
            if chatTarget == nil || detailShowsTerminal,
               let path = selection?.projectPath, terminals.hasPane(for: path),
               chatTarget == nil || chatTarget?.path == path,
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
        // Branch button: live git state at a glance, sheet on click.
        Button {
            toggleRightPanel(.git)
        } label: {
            HStack(spacing: 5) {
                LucideIcon("git-branch", size: 12)
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
                    LucideIcon("chevron-down", size: 10)
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
                LucideIcon("play", size: 13)
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
                item.image = SVGIcon.template(named: "lucide/circle-arrow-down")
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

    /// True while the detail surface is a chat (sky, draft, or
    /// transcript) — i.e. a composer is mounted to receive a drop. The
    /// same test `detailContent` makes when it picks the terminal card.
    private func chatSurfaceShowing() -> Bool {
        guard let chatTarget else { return false }
        if detailShowsTerminal, let path = selection?.projectPath,
           path == chatTarget.path, terminals.hasPane(for: path) {
            return false
        }
        return true
    }

    @ViewBuilder
    private var detailContent: some View {
        // Chat mode swaps the surface, not the session: panes stay mounted
        // in TerminalSessionManager, so shells and agents keep running
        // underneath — and the chat can belong to a different project than
        // the selected terminal.
        if let chatTarget {
            // The project workspace: top bar + (via the root HStack) the
            // side panel, with EITHER the chat or the selected terminal
            // as the surface underneath — two surfaces, one window.
            VStack(spacing: 0) {
                chatHeaderBar(chatTarget.path)
                if detailShowsTerminal,
                   let path = selection?.projectPath,
                   path == chatTarget.path,
                   terminals.hasPane(for: path) {
                    terminalCard(path)
                } else {
                    ChatBrowserView(
                        projectPath: chatTarget.path,
                        initialSessionFile: chatTarget.sessionFile,
                        projects: store.pinnedProjects
                    )
                    .id(chatTarget)
                    // The window-wide drop's target hint, drawn over the
                    // chat area wherever the drag actually is. Not a drop
                    // target itself — the root's onDrop does the catching.
                    .overlay {
                        if imageDropTargeted {
                            ImageDropField()
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: imageDropTargeted)
                }
            }
        } else {
            selectionContent
        }
    }

    /// The terminal as a rounded card on the page chrome (2026-09-14):
    /// the terminal theme's background fills only the card.
    private func terminalCard(_ path: String) -> some View {
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
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case let .project(path), let .shell(path, _):
            if terminals.hasPane(for: path) {
                terminalCard(path)
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
        // Hidden entirely while no terminal is open (2026-09-23) — the
        // top cluster's New Terminal is the standing affordance, so an
        // empty section was just a dangling header.
        if !terminalPaths.isEmpty {
            out.append(.header("Terminals"))
            for path in terminalPaths {
                let list = terminals.tabs[path] ?? []
                out.append(.row(
                    id: .project(path),
                    title: list.first?.customName ?? name(of: path)
                ))
                // Extra terminals in the same directory: full peer rows,
                // same name — rename is there for anyone who wants to
                // tell them apart.
                for tab in list.dropFirst() {
                    out.append(.row(
                        id: .shell(path: path, tab: tab.id),
                        title: tab.customName ?? name(of: path)
                    ))
                }
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
        detailShowsTerminal = false
    }

    /// A project click: its chat home in the center, its chat list in the
    /// right sheet (2026-09-20 layout — chats live in the right sidebar,
    /// not nested under the project row).
    private func openProjectChats(_ path: String) {
        // Already inside one of this project's chats: keep it; the click
        // just summons the workspace panel.
        if chatTarget?.path != path {
            chatTarget = ChatTarget(path: path, sessionFile: nil)
        }
        // A project click always lands with the side panel up and the
        // Chats module in it — even if Chats was pinned to the top bar.
        moveToPanel(.chats)
        detailShowsTerminal = false
        chatIndex.refresh(path, force: true)
    }

    /// The project panel (2026-09-21 mock): its own header — folder glyph
    /// + project name, new chat / terminal / pin / close — over the
    /// project's server row(s), then the chat list. Project-scoped pages
    /// (a server's page) push INSIDE the panel with the sheet's push
    /// grammar; the global drawers (Tasks, Servers) stay their own
    /// sheets, opened from the sidebar's top list.
    /// The project panel (2026-09-22 mock): folder + NAME header with
    /// one circular chevron (collapse), Git/server PILLS under it, the
    /// chat list, and "+ Chat / + Terminal" pills pinned at the bottom.
    /// Collapsed, only the header bar survives (see
    /// `collapsedProjectBar`).
    private func chatListPanel(for path: String) -> some View {
        let onRoot = !projectPanelGit && projectPanelServer == nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LucideIcon("folder", size: 17)
                    .foregroundStyle(Theme.text)
                Text(name(of: path).uppercased())
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ControlIconButton(
                    icon: "chevron-up",
                    help: "Collapse the panel",
                    circleSize: 30,
                    action: { setChatsPanelCollapsed(true) }
                )
            }
            .padding(.top, 2)
            .padding(.horizontal, 4)

            // Git + live server, as status pills — the panel's places to
            // drill into, one row under the name.
            if onRoot {
                projectStatusPills(for: path)
                    .padding(.top, 14)
                    .padding(.horizontal, 2)
            }

            // ZStack: the chat home and a pushed page (a server's, or
            // git) overlap in the same slot while a push runs — same
            // grammar as the sheet's own page swaps.
            ZStack(alignment: .top) {
                if projectPanelGit {
                    projectGitDetail(path)
                        .transition(Self.pageChild)
                } else if let sid = projectPanelServer {
                    projectServerDetail(sid)
                        .transition(Self.pageChild)
                } else {
                    projectChatPage(for: path)
                        .transition(Self.pageParent)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)

            // New chat / terminal live at the panel's foot (per the
            // mock), only on the root page.
            if onRoot {
                HStack(spacing: 10) {
                    footPill("+ Chat") { newChat(in: path) }
                    footPill("+ Terminal") {
                        _ = terminals.pane(for: path)
                        select(.project(path))
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// One status pill row: Git always, then each live server (or the
    /// last known one, dimmed). Each pill pushes its page.
    private func projectStatusPills(for path: String) -> some View {
        let live = servers.devServers.filter { $0.cwd == path }
        let recent = live.isEmpty
            ? servers.recents.first(where: { $0.projectPath == path })
            : nil
        return HStack(spacing: 10) {
            statusPill("Git", running: true) {
                withAnimation(sheetSpring) {
                    projectPanelServer = nil
                    projectPanelGit = true
                }
            }
            ForEach(live, id: \.id) { server in
                statusPill(
                    "Localhost:" + String(server.port), running: true
                ) { pushProjectServer(server.id) }
            }
            if let recent {
                statusPill(
                    "Localhost:" + String(recent.port), running: false
                ) { pushProjectServer(recent.id) }
            }
            Spacer(minLength: 0)
        }
    }

    /// The mock's pill: status dot + label on the recessed tile fill.
    private func statusPill(
        _ label: String, running: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(running
                        ? Theme.dotActive
                        : Theme.textSecondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(running ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.tileFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// The foot's "+ Chat" / "+ Terminal" pill.
    private func footPill(
        _ label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Theme.tileFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Project workspace panel (2026-09-23 floating canvas)

    // Widened 224 → 256 for the module cards (2026-09-23 mock).
    private static let subSidebarWidth: CGFloat = 256
    /// Measured content height — the card hugs it, capped at the window.
    @State private var workspaceContentHeight: CGFloat = 0
    /// Which workspace items live in the side panel; the rest ride the
    /// top bar as chips. Every item is in exactly ONE of the two homes.
    @State private var workspaceItems: Set<WorkspaceItem> = Set(
        HoustonSettings.read().workspacePanelItems
            .compactMap(WorkspaceItem.init)
    )

    private func moveToPanel(_ item: WorkspaceItem) {
        withAnimation(sheetSpring) { _ = workspaceItems.insert(item) }
        persistWorkspaceItems()
    }

    private func moveToBar(_ item: WorkspaceItem) {
        withAnimation(sheetSpring) { _ = workspaceItems.remove(item) }
        persistWorkspaceItems()
    }

    /// Each section's "+" — the same action its side-panel card header
    /// runs, so the bar dropdown and the card behave alike.
    private func addAction(_ item: WorkspaceItem, path: String) {
        switch item {
        case .branches: toggleRightPanel(.git)
        case .servers: startProjectDevServer(path)
        case .terminals: newTerminal(in: path)
        case .chats: newChat(in: path)
        }
    }

    private func addHelp(_ item: WorkspaceItem) -> String {
        switch item {
        case .branches: "Open git — branches and changes"
        case .servers: "Start the dev server"
        case .terminals: "Open a terminal in this project"
        case .chats: "Start a new chat"
        }
    }

    private func persistWorkspaceItems() {
        updateSettings {
            $0.workspacePanelItems = workspaceItems.map(\.rawValue).sorted()
        }
    }

    /// The workspace panel's layout slot: the card hangs top-right and
    /// the rest of the slot is empty air, so the panel reads as floating.
    /// The slot's right edge is pinned (the sheet reservation sits after
    /// it), so the trailing-anchored card holds a FIXED integral x while
    /// the width animates — opening reads as a leftward reveal, and no
    /// frame can rasterize the rows at a fractional offset.
    private func workspacePanelColumn(_ path: String?) -> some View {
        let open = path != nil && !workspaceItems.isEmpty
        return GeometryReader { geo in
            if let path {
                workspaceCard(path, maxHeight: geo.size.height - 36)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: .topTrailing
                    )
                    // Air on BOTH sides — the card floats, never touching
                    // the window edge; 24 off the right edge to match the
                    // top bar's stand-off.
                    .padding(.trailing, 24)
                    .frame(width: Self.subSidebarWidth + 24 + 14)
            }
        }
        .modifier(WholePixelWidth(
            width: open ? Self.subSidebarWidth + 24 + 14 : 0))
        .clipped()
    }

    /// The floating workspace panel (2026-09-23 mock): each module is its
    /// OWN rounded card — TERMINALS, CHATS… — stacked with a gap, on the
    /// dropdown surface color. Each card's header carries the caps title
    /// and, in its top-right corner, the always-visible square controls
    /// (add, move to the top bar). The stack is sized to CONTENT (capped
    /// at the window) and scrolls past the cap.
    private func workspaceCard(_ path: String, maxHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if workspaceItems.contains(.branches) {
                    moduleCard { subBranchesSection(path) }
                }
                if workspaceItems.contains(.servers) {
                    moduleCard { subServersSection(path) }
                }
                if workspaceItems.contains(.terminals) {
                    moduleCard { subTerminalsSection(path) }
                }
                if workspaceItems.contains(.chats) {
                    moduleCard { subChatsSection(path) }
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspacePanelHeightKey.self,
                    value: proxy.size.height
                )
            })
        }
        .frame(width: Self.subSidebarWidth)
        .frame(height: min(max(workspaceContentHeight, 120), maxHeight))
        .onPreferenceChange(WorkspacePanelHeightKey.self) {
            workspaceContentHeight = $0
        }
        .padding(.top, 24)
        .task(id: path) { chatIndex.refresh(path, force: true) }
    }

    /// One module's card: a tight uniform inset, the rows' own 8px
    /// padding carrying the text alignment (hover pills run nearly edge
    /// to edge, like a Popover's items).
    private func moduleCard<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusFloat)
                    .fill(Theme.menuFill)
            )
    }

    /// The chat view's top bar: the project title plus a labeled chip
    /// for every workspace item NOT currently in the side panel.
    /// Clicking a chip moves that item into the panel; the panel
    /// section's arrow sends it back here.
    private func chatHeaderBar(_ path: String) -> some View {
        HStack(spacing: 14) {
            // The project name is a switcher: pick another project and
            // the whole workspace retargets to it.
            Menu {
                ForEach(store.pinnedProjects, id: \.self) { project in
                    Toggle(displayProjectName(project), isOn: Binding(
                        get: { project == path },
                        set: { _ in switchWorkspaceProject(to: project) }
                    ))
                }
            } label: {
                HStack(spacing: 5) {
                    Text(displayProjectName(path))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    LucideIcon("chevron-down", size: 12)
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch project")
            ForEach(
                WorkspaceItem.allCases.filter { !workspaceItems.contains($0) },
                id: \.self
            ) { item in
                barChip(item, path: path)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        // The bar HUGS its content — just slightly wider than the text —
        // and floats centered, a pill, not a strip.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .fill(Theme.sidebarFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 2)
    }

    /// A workspace item's top-bar chip: icon + label (Branches and Chats
    /// also carry a status dot). Clicking moves the item into the side
    /// panel.
    @ViewBuilder
    private func barChip(_ item: WorkspaceItem, path: String) -> some View {
        Group {
            switch item {
            case .branches:
                headerChip(
                    icon: "git-branch",
                    label: BranchPeek.branch(path) ?? "Branches",
                    dotColor: git.rowStatuses[path]?.isDirty == true
                        ? Theme.dotDegraded : Theme.dotActive
                ) { toggleBarDropdown(item) }
            case .servers:
                let live = servers.devServers.first { $0.cwd == path }
                headerChip(
                    icon: "server",
                    label: live.map { "Localhost:" + String($0.port) } ?? "Servers"
                ) { toggleBarDropdown(item) }
            case .terminals:
                if (terminals.tabs[path] ?? []).isEmpty {
                    // No terminals yet: the chip IS the create affordance —
                    // one click opens a terminal in this directory (it
                    // lands in the sidebar like any other). Label only:
                    // no icon, no dot.
                    headerChip(
                        icon: nil,
                        label: "+ New Terminal"
                    ) { newTerminal(in: path) }
                } else {
                    headerChip(
                        icon: "square-terminal",
                        label: "Terminals"
                    ) { toggleBarDropdown(item) }
                }
            case .chats:
                let busy = (chatIndex.chats[path] ?? []).contains {
                    guard let phase = ChatSessionHub.shared
                        .sessions[$0.filePath]?.phase else { return false }
                    return phase != .idle
                }
                headerChip(
                    icon: "message-square-text",
                    label: "Chats",
                    dotColor: busy ? Theme.dotActive : Theme.dotIdle
                ) { toggleBarDropdown(item) }
            }
        }
        // The chip anchors its dropdown (and, for Servers, the server
        // card once the dropdown hands off to it).
        .anchorPreference(key: SidebarFlyoutAnchorKey.self, value: .bounds) {
            ["barchip:" + item.rawValue: $0]
        }
    }

    private func toggleBarDropdown(_ item: WorkspaceItem) {
        withAnimation(Theme.quick) {
            barDropdown = barDropdown == item ? nil : item
        }
    }

    /// Retarget the workspace to another project: its chat landing, its
    /// side panel sections, its top bar.
    private func switchWorkspaceProject(to path: String) {
        guard chatTarget?.path != path else { return }
        chatTarget = ChatTarget(path: path, sessionFile: nil)
        detailShowsTerminal = false
        chatIndex.refresh(path, force: true)
    }

    /// "houston" the folder reads as "Houston" the header.
    private func displayProjectName(_ path: String) -> String {
        let raw = name(of: path)
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Icon and dot are both optional: only Branches and Chats carry a
    /// status dot, and the "+ New Terminal" create chip is label-only.
    private func headerChip(
        icon: String?, label: String, dotColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    LucideIcon(icon, size: 13)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func subBranchesSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SubSectionHeader(
                title: "BRANCHES", addHelp: "Open git — branches and changes",
                onAdd: { toggleRightPanel(.git) },
                onMoveToBar: { moveToBar(.branches) }
            )
            if let branch = BranchPeek.branch(path) {
                SubSidebarRow(
                    title: branch,
                    dot: git.rowStatuses[path]?.isDirty == true
                        ? Theme.dotDegraded : Theme.dotActive,
                    selected: effectiveRightPanel == .git
                ) { toggleRightPanel(.git) }
            }
        }
    }

    @ViewBuilder
    private func subServersSection(_ path: String) -> some View {
        let live = servers.devServers.filter { $0.cwd == path }
        let recent = live.isEmpty
            ? servers.recents.first(where: { $0.projectPath == path })
            : nil
        VStack(alignment: .leading, spacing: 2) {
            SubSectionHeader(
                title: "SERVERS", addHelp: "Start the dev server",
                onAdd: { startProjectDevServer(path) },
                onMoveToBar: { moveToBar(.servers) }
            )
            ForEach(live, id: \.id) { server in
                SubSidebarRow(
                    title: "Localhost:" + String(server.port),
                    dot: Theme.dotActive,
                    selected: subServerFlyoutID == server.id
                ) {
                    withAnimation(Theme.quick) {
                        subServerFlyoutID = server.id
                    }
                }
                .anchorPreference(
                    key: SidebarFlyoutAnchorKey.self, value: .bounds
                ) { ["subserver:" + server.id: $0] }
            }
            if let recent {
                SubSidebarRow(
                    title: "Localhost:" + String(recent.port),
                    dot: Theme.dotIdle, muted: true,
                    selected: false
                ) { toggleRightPanel(.server(recent.id)) }
            }
        }
    }

    private func subTerminalsSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SubSectionHeader(
                title: "TERMINALS", addHelp: "Open a terminal in this project",
                onAdd: { newTerminal(in: path) },
                onMoveToBar: { moveToBar(.terminals) }
            )
            ForEach(terminals.tabs[path] ?? [], id: \.id) { tab in
                let isMain = terminals.tabs[path]?.first?.id == tab.id
                SubSidebarRow(
                    title: tab.customName ?? name(of: path),
                    selected: selection == (isMain
                        ? .project(path) : .shell(path: path, tab: tab.id)),
                    // The tab-prune onChange re-points a selection whose
                    // tab closed, same as the main sidebar's ✕.
                    onClose: { terminals.closeTab(path: path, tabID: tab.id) }
                ) {
                    select(isMain
                        ? .project(path) : .shell(path: path, tab: tab.id))
                }
            }
        }
    }

    @ViewBuilder
    private func subChatsSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SubSectionHeader(
                title: "CHATS", addHelp: "Start a new chat",
                onAdd: { newChat(in: path) },
                onMoveToBar: { moveToBar(.chats) }
            )
            // Ten at a time — a long-lived project has hundreds, and the
            // panel is a card that hugs its content, so an unbounded list
            // would swallow the workspace. "Show more" reveals the next
            // page; the count is per project and lives with the view.
            let all = listedChats(for: path)
            let shown = Self.chatsPageSize * (1 + chatsPagesRevealed)
            ForEach(all.prefix(shown)) { ref in
                SubSidebarRow(
                    title: chatTitler.displayTitle(ref),
                    busy: ChatSessionHub.shared.sessions[ref.filePath]
                        .map { $0.phase != .idle } ?? false,
                    selected: chatTarget?.sessionFile == ref.filePath
                ) { openChat(project: path, file: ref.filePath) }
                // Same menu as the chat page's rows — one definition.
                .contextMenu { chatContextMenu(project: path, ref: ref) }
            }
            if all.count > shown {
                ShowMoreRow(remaining: all.count - shown) {
                    chatsPagesRevealed += 1
                }
            }
        }
    }

    private static let chatsPageSize = 10

    /// Start the project's own dev server: a terminal plus the detected
    /// dev command (plain terminal when the project declares none).
    private func startProjectDevServer(_ path: String) {
        _ = terminals.pane(for: path)
        select(.project(path))
        if let command = DevCommandDetect.detect(projectPath: path) {
            terminals.send(command.command + "\n", to: path)
        }
    }

    private func pushProjectServer(_ sid: String) {
        withAnimation(sheetSpring) { projectPanelServer = sid }
    }

    /// The pushed server page, in-panel: the SAME compact card the
    /// sidebar's servers flyout shows (2026-09-22) — back-arrow header,
    /// Browser/Inspector rows, sharing toggles, Stop.
    @ViewBuilder
    private func projectServerDetail(_ sid: String) -> some View {
        if let server = liveServer(for: sid) {
            ServerFlyoutCard(
                server: server, share: share, relay: relay,
                onBack: { popProjectServer() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 2)
        } else if let recent = servers.recent(matching: sid) {
            OffServerPanel(
                recent: recent,
                busyPorts: Dictionary(
                    servers.devServers.map { ($0.port, $0.project ?? $0.command) },
                    uniquingKeysWith: { a, _ in a }
                ),
                docked: rightPanelDocked,
                onBack: { popProjectServer() },
                onStart: { command in
                    _ = terminals.pane(for: recent.projectPath)
                    select(.project(recent.projectPath))
                    terminals.send(command + "\n", to: recent.projectPath)
                }
            )
        } else {
            rightSheetPlaceholder("This server is no longer listening.")
        }
    }

    private func popProjectServer() {
        withAnimation(sheetSpring) { projectPanelServer = nil }
    }

    /// The git page, pushed inside the project panel — the same content
    /// the right sheet's Git panel renders, headed by a back chevron
    /// (the panel's project header stays above it).
    private func projectGitDetail(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ControlIconButton(
                    icon: "chevron-left",
                    help: "Back",
                    bare: true,
                    circleSize: 28,
                    action: {
                        withAnimation(sheetSpring) { projectPanelGit = false }
                    }
                )
                capsSheetTitle("GIT")
                Spacer(minLength: 0)
            }
            gitPanel(for: path)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        ) { _ in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chatTitler.displayTitle(ref))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if chatMeta.pinned.contains(file) {
                        LucideIcon("pin", size: 10)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if chatMeta.branches[file] != nil {
                        LucideIcon("git-branch", size: 10)
                            .foregroundStyle(Theme.textSecondary)
                            .help("Branched from another chat")
                    }
                    Spacer(minLength: 8)
                    // Quiet rows (2026-09-21): no timestamp, no hover ✕ —
                    // archive lives in the context menu; only the busy
                    // dot surfaces state.
                    if busy {
                        Circle()
                            .fill(Theme.dotActive)
                            .frame(width: 6, height: 6)
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

    /// Same actions the sidebar's NSMenu carried, as a SwiftUI menu.
    @ViewBuilder
    private func chatContextMenu(project: String, ref: ChatSessionRef) -> some View {
        let file = ref.filePath
        let running = ChatSessionHub.shared.sessions[file]?.running == true
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
        Button("Delete Permanently…") { deleteChat(project: project, file: file) }
            .disabled(running)
        Divider()
        // Another project's store — an export + remove (the CLIs key
        // sessions by directory). Disabled mid-turn: the live session
        // would keep appending to a file that's about to be trashed.
        Menu("Move to Project") {
            ForEach(store.pinnedProjects.filter { $0 != project }, id: \.self) { other in
                Button(displayProjectName(other)) {
                    moveChat(ref, from: project, to: other)
                }
            }
        }
        .disabled(running || store.pinnedProjects.count < 2)
        Divider()
        Button("Share…") { ChatRowActions.share(ref) }
        Menu("Copy") {
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    chatTitler.displayTitle(ref), forType: .string
                )
            }
            Button("Copy Transcript") { ChatRowActions.copyTranscript(ref) }
            Button("Copy Transcript Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file, forType: .string)
            }
        }
        Menu("Fork") {
            Button("Branch Chat") {
                ChatRowActions.duplicate(ref, project: project, asBranch: true)
            }
            Button("Duplicate") { ChatRowActions.duplicate(ref, project: project) }
        }
        Divider()
        // The chat's PROJECT folder in an editor, a terminal, or Finder —
        // installed apps only, so nothing here is a dead item.
        Menu("Open in") {
            ForEach(Actions.ExternalApp.allCases.filter(\.installed)) { app in
                Button(app.title) { Actions.open(path: project, in: app) }
            }
            Divider()
            Button("Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file)]
                )
            }
        }
    }

    /// Move a chat to another project: the row leaves this list, the
    /// open view (if it was this chat) lands on the destination's copy.
    private func moveChat(_ ref: ChatSessionRef, from project: String, to destination: String) {
        let wasOpen = chatTarget?.sessionFile == ref.filePath
        ChatRowActions.move(ref, from: project, to: destination) { moved in
            guard wasOpen else { return }
            if let moved {
                chatTarget = ChatTarget(path: destination, sessionFile: moved)
            } else {
                chatTarget = ChatTarget(path: project, sessionFile: nil)
            }
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

    /// Delete a chat for good: confirm, shut its live session down, remove
    /// the transcript (not trashed — the menu item says permanently, so it
    /// is), and fall back to the project's chat list if it was open.
    private func deleteChat(project: String, file: String) {
        let alert = NSAlert()
        alert.messageText = "Delete this chat permanently?"
        alert.informativeText = "The transcript is removed from disk. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ChatSessionHub.shared.forget(file: file)
        ChatMetaStore.shared.forget(file)
        CapsuleStore.shared.forget(file: file)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: file))
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
        detailShowsTerminal = false
        chatIndex.refresh(path, force: true)
    }

    /// The project row's terminal button — another plain shell. In the
    /// workspace (chat open on this project) the new terminal also lands
    /// the Terminals section in the side panel, so the created shell is
    /// visible as a row there — and `select` keeps the top bar + side
    /// panel on screen, swapping only the surface underneath.
    private func newTerminal(in path: String) {
        if chatTarget?.path == path {
            moveToPanel(.terminals)
        }
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
                    HeaderPlusButton(icon: "folder-plus", help: "Add a project") {
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
                        LucideIcon("package", size: 14)
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
                            symbol: "square-terminal", help: "New terminal", size: 12
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
        // Selecting a terminal in the CURRENT project keeps the
        // workspace (top bar + side panel) and swaps the surface to the
        // terminal; any other selection leaves the workspace entirely.
        if let target {
            if let path = target.projectPath, chatTarget?.path == path {
                detailShowsTerminal = true
            } else {
                chatTarget = nil
                detailShowsTerminal = false
            }
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
            // ⌘S: the highlighted text becomes a task — in the open
            // workspace's project when there is one, else No project —
            // and the tasks menu opens to show it landed.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .houstonAddSelectionToTasks)
            ) { _ in
                guard let text = ChatThread.capturedSelection()?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return }
                let project = chatTarget?.path
                    ?? selection?.projectPath
                    ?? NSHomeDirectory()
                AnnotationStores.store(for: project).add(comment: text)
                tasksPopoverShown = true
            }
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
        // Closing the workspace's own terminal returns to its chat — never
        // a jump to some other project's terminal.
        if chatTarget?.path == path {
            detailShowsTerminal = false
            selection = nil
            return
        }
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
    case newChat, newTerminal, tasks, servers, terminals, projects

    var label: String {
        switch self {
        case .newChat: "New Chat"
        case .newTerminal: "New Terminal"
        case .tasks: "Tasks"
        case .servers: "Servers"
        case .terminals: "Terminals"
        case .projects: "Projects"
        }
    }

    var row: CGFloat {
        switch self {
        case .newChat: 0
        case .newTerminal: 1
        case .tasks: 2
        case .servers: 3
        case .terminals: 4
        case .projects: 5
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
/// An animated trailing inset that only ever lands on whole pixels: the
/// animatable value is rounded every frame before it reaches layout.
/// Content that (re)renders while an ancestor sits at a fractional x
/// bakes that subpixel phase into its glyph raster and stays soft after
/// the animation settles (a full smeared pixel on a 1x display) — see
/// `rightSheetLayer`. Rounding per frame makes that impossible.
private struct WholePixelTrailingInset: ViewModifier, @MainActor Animatable {
    var inset: CGFloat
    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }
    func body(content: Content) -> some View {
        content.padding(.trailing, inset.rounded())
    }
}

/// Width sibling of `WholePixelTrailingInset`, for the root HStack's
/// sheet-width reservation.
private struct WholePixelWidth: ViewModifier, @MainActor Animatable {
    var width: CGFloat
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    func body(content: Content) -> some View {
        content.frame(width: width.rounded())
    }
}

/// The transition twin of `WholePixelTrailingInset`: a horizontal slide
/// whose offset is rounded every frame, used by the sheet's push/pop
/// grammar (`pageParent`/`pageChild`) in place of `.move`.
private struct WholePixelSlide: ViewModifier, @MainActor Animatable {
    var x: CGFloat
    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(x: x.rounded())
    }
}

private struct SnippetText: View {
    @ObservedObject private var snippets = ChatIndexStore.Snippets.shared
    let file: String

    var body: some View {
        let text = snippets.snippet(for: file) ?? ""
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 11))
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
                LucideIcon(busy
                    ? "refresh-ccw"
                    : "circle-arrow-down", size: 12)
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
/// One row of the sidebar's top list (New Chat / New Terminal / Tasks /
/// Servers): plain rows in the table's own chrome — no tile fill, no
/// box. The server tally is quiet gray text at the trailing edge, and
/// the server glyph stays neutral whatever's running (2026-09-21 — the
/// signal-green treatment came off).
private struct TopListRow: View {
    let icon: String
    let label: String
    var dot: Bool = false
    var active: Bool = false
    /// Draw the hand-drawn server glyph instead of an SF Symbol.
    var serverIcon: Bool = false
    /// Live tally (running dev servers), shown as quiet trailing text.
    var count: Int = 0
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if serverIcon {
                        ServerGlyph(color: Theme.textSecondary, size: 15)
                    } else {
                        LucideIcon(icon, size: 15)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 18)
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle()
                            .fill(Theme.dotDegraded)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                    }
                }
                Text(label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(String(count))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .modifier(RowChrome(hovered: hovered, selected: active))
            // Outside RowChrome: the chrome fills whatever height it is
            // given (table rows get theirs from the table), so a free-
            // standing row must cap itself or it stretches to share the
            // column.
            .frame(height: 30)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct FooterLabeledButton: View {
    let icon: String
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
                LucideIcon(icon, size: label == nil ? 14 : 15)
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
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            LucideIcon(icon, size: 14)
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
                LucideIcon("list-checks", size: 12)
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
                rowIconButton("x", help: "Close terminal", action: onClose)
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
            LucideIcon(symbol, size: 11)
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

/// A workspace sub-sidebar section header: caps label with a "+" that
/// fades in on hover — the section's add affordance.
/// A workspace item lives in exactly ONE of two homes: the chat top bar
/// (as a labeled chip) or the side panel (as a section). Order here is
/// the display order in both.
enum WorkspaceItem: String, CaseIterable {
    case branches, servers, terminals, chats
}

/// A module card's header (2026-09-23 mock): caps title on the left,
/// the square controls in the top-right corner — always visible, not a
/// hover reveal.
private struct SubSectionHeader: View {
    let title: String
    let addHelp: String
    let onAdd: () -> Void
    /// Sends this section back to the top bar.
    var onMoveToBar: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.heading)
            Spacer(minLength: 8)
            PanelControlButton(icon: "plus", help: addHelp, action: onAdd)
            if let onMoveToBar {
                PanelControlButton(
                    icon: "dock-top", help: "Move to the top bar",
                    action: onMoveToBar
                )
            }
        }
        .padding(.leading, 8)
        .frame(height: 28)
    }
}

/// The module cards' corner control (and the top bar dropdowns' — same
/// size everywhere): a 24pt rounded square on the control-chip fill,
/// hover stepping the wash and the glyph up.
struct PanelControlButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.controlChip)
                if hovered {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.rowHovered)
                }
                LucideIcon(icon, size: 13)
                    .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // The tip shows the instant the pointer lands — the system
        // `.help` tooltip waits ~a second, which on a 24pt glyph-only
        // control reads as "no label". It sits ABOVE the button, clear
        // of it and of the pointer (an arrow cursor only ever extends
        // down-right from its hotspot, so nothing above the button can
        // end up under it), trailing-aligned and growing leftward since
        // these controls sit at the right edge of their header. The
        // spacer is the button's height plus the gap — fixed frames, so
        // the placement can't drift with the card's text height.
        .overlay(alignment: .bottomTrailing) {
            if hovered {
                VStack(alignment: .trailing, spacing: 0) {
                    TipCard(text: help)
                    Color.clear.frame(width: 1, height: 24 + 6)
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(help)
    }
}

/// The floating label the rail and the panel controls share: 11pt medium
/// on the menu fill with a hairline and a soft shadow.
struct TipCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.text)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(Theme.menuFill)
                    .shadow(
                        color: Theme.floatShadowColor,
                        radius: 4, x: 0, y: 1
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .strokeBorder(Theme.borderSidebar, lineWidth: 1)
            )
    }
}

/// A workspace sub-sidebar row: optional status dot, 14pt title, hover
/// wash, selected pill — the mock's airy 34pt pitch.
private struct SubSidebarRow: View {
    let title: String
    var dot: Color? = nil
    var muted: Bool = false
    var busy: Bool = false
    var selected: Bool
    /// Hover ✕ at the row's end (terminal rows) — same affordance as the
    /// main sidebar's terminal rows.
    var onClose: (() -> Void)? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if busy {
                Circle().fill(Theme.dotActive).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(muted ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if hovered, let onClose {
                Button(action: onClose) {
                    LucideIcon("x", size: 12)
                        .foregroundStyle(Theme.text)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close terminal")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(selected
                    ? Theme.rowSelected
                    : hovered ? Theme.rowHovered : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

/// The CHATS section's quiet pager: a text-only row in the secondary
/// ink, brightening on hover — deliberately not a pill, so it reads as a
/// footnote under the list rather than another chat.
private struct ShowMoreRow: View {
    let remaining: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text("Show more")
                .font(.system(size: 12))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show the next \(min(remaining, 10)) chats")
    }
}

/// The root's image/file drop, window-wide. `validateDrop` gates on the
/// drag's flavor AND on a chat surface being visible, so nothing lights
/// up (and nothing is swallowed) while a terminal or the empty state
/// shows; the loader is the composer's own, so a drop here stages
/// exactly like a drop on the composer would.
private struct WindowImageDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    let accepts: () -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        accepts() && info.hasItemsConforming(to: [.image, .fileURL])
    }

    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return ComposerDropLoader.load(info.itemProviders(for: [.image, .fileURL]))
    }
}

/// The chat area's drop hint while an image drag is over the window: a
/// dashed accent frame inset from the edges, icon + line centered.
/// Hit-testing is off so it never becomes a drop target of its own.
private struct ImageDropField: View {
    var body: some View {
        ZStack {
            Theme.emptyStateBackground.opacity(0.72)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Theme.link,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
                .padding(18)
            VStack(spacing: 10) {
                LucideIcon("image-plus", size: 30)
                    .foregroundStyle(Theme.link)
                Text("Drop image anywhere")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("It attaches to your message")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Current branch by reading `.git/HEAD` directly — a tiny file, cached
/// briefly, so the sub-sidebar's render loop never shells out.
@MainActor
enum BranchPeek {
    private static var cache: [String: (name: String, at: Date)] = [:]

    static func branch(_ path: String) -> String? {
        if let hit = cache[path], Date().timeIntervalSince(hit.at) < 5 {
            return hit.name.isEmpty ? nil : hit.name
        }
        let head = (try? String(
            contentsOfFile: path + "/.git/HEAD", encoding: .utf8
        )) ?? ""
        let name: String
        if head.hasPrefix("ref: refs/heads/") {
            name = head.dropFirst("ref: refs/heads/".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if head.isEmpty {
            name = ""
        } else {
            name = "detached"
        }
        cache[path] = (name, Date())
        return name.isEmpty ? nil : name
    }
}

/// The workspace card's measured content height — it hugs content,
/// capped at the window.
struct WorkspacePanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The sidebar flyouts' anchors — Servers and Tasks rows publish their
/// bounds (keyed by name) so the custom cards can resolve them in the
/// root's coordinate space.
struct SidebarFlyoutAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A server in the flyout's list page: name over its green localhost
/// address, chevron trailing, hover chrome.
private struct ServerFlyoutListRow: View {
    let server: DevServer
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.project ?? server.command)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("Localhost:" + String(server.port))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPositive)
            }
            Spacer(minLength: 8)
            LucideIcon("chevron-right", size: 12)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(hovered ? Theme.buttonFill : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

/// A running server as the servers flyout's card (2026-09-22 mock):
/// back circle + prettified name header, Browser/Inspector launch rows
/// with redirect glyphs, hairline-separated Wi-Fi + Live URL toggles,
/// and Stop. No pin, no sheet chrome — the flyout is its own surface.
struct ServerFlyoutCard: View {
    let server: DevServer
    @ObservedObject var share: ShareProxyStore
    @ObservedObject var relay: RelayTunnelStore
    var onBack: (() -> Void)? = nil

    @State private var stopHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let onBack {
                    ControlIconButton(
                        icon: "arrow-left",
                        help: "Back to servers",
                        circleSize: 28,
                        action: onBack
                    )
                }
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
            launchRow(
                "Browser", subtitle: localhost,
                help: "Open in your browser"
            ) { Actions.openExternal(server.url) }
                .padding(.bottom, 12)
            launchRow(
                "Inspector", subtitle: localhost,
                help: "Inspect elements and edit with Claude"
            ) { PreviewWindowController.present(server: server) }
                .padding(.bottom, 14)
            hairline
            toggleRow(
                "Local WiFi sharing", subtitle: wifiSubtitle,
                isOn: Binding(
                    get: { share.enabled },
                    set: { share.setEnabled($0) }
                )
            )
            .padding(.vertical, 14)
            hairline
            toggleRow(
                "Live URL", subtitle: liveSubtitle,
                isOn: Binding(
                    get: { relay.isEnabled(projectLabel) },
                    set: { relay.setEnabled(projectLabel, $0) }
                ),
                disabled: relay.token.isEmpty
            )
            .padding(.top, 14)
            .padding(.bottom, 18)
            Button(action: { Actions.killPid(server.pid) }) {
                HStack(spacing: 7) {
                    LucideIcon("circle-stop", size: 15)
                    Text("Stop Server")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textDanger)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
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
    }

    /// "farm-chic" the folder reads as "Farm Chic" the app.
    private var displayName: String {
        (server.project ?? server.command)
            .split(whereSeparator: { "-_ ".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var localhost: String { "Localhost:" + String(server.port) }

    private var projectLabel: String {
        ShareProxyStore.label(for: server.project ?? server.command)
    }

    private var wifiSubtitle: String {
        if share.enabled && share.running {
            return share.lanURL(forProjectNamed: server.project ?? server.command)
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
        }
        return projectLabel + ".local"
    }

    private var liveSubtitle: String {
        if relay.token.isEmpty { return "Needs a Houston Pro token" }
        if relay.isEnabled(projectLabel) {
            switch relay.states[projectLabel] {
            case let .online(url):
                return url
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
            case .offline: return "Waiting for the dev server…"
            case .connecting, nil: return "Connecting…"
            }
        }
        return projectLabel + "." + RelayTunnelStore.relayHost
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.borderSidebar)
            .frame(height: 1)
    }

    private func launchRow(
        _ title: String, subtitle: String, help: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                SVGIcon(name: "redirect", size: 16)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
        // The whole row launches, not just the glyph.
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private func toggleRow(
        _ title: String, subtitle: String,
        isOn: Binding<Bool>, disabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(PanelSwitchStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
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
                    icon: "chevron-left",
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
                        icon: "chevron-left",
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
                    LucideIcon("circle-stop", size: 16)
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
            LucideIcon("ellipsis", size: 15)
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
                icon: docked ? "pin-off" : "pin",
                help: docked ? "Float over the content" : "Dock beside the content",
                bare: true,
                circleSize: 32,
                action: onTogglePin
            )
            ControlIconButton(
                icon: "x",
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
                    icon: "mouse-pointer-click",
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
                                LucideIcon("qr-code", size: 15)
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
                                LucideIcon("share", size: 15)
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
                            LucideIcon("circle-x", size: 15)
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
                        LucideIcon("plus", size: 14)
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
                            icon: "chevron-left",
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
                            icon: docked ? "pin-off" : "pin",
                            help: docked ? "Float over the content" : "Dock beside the content",
                            bare: true,
                            circleSize: 32,
                            action: onTogglePin
                        )
                        ControlIconButton(
                            icon: "x",
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
                            LucideIcon("play", size: 11)
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
                LucideIcon(icon, size: 17)
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
            LucideIcon("chevron-right", size: 11)
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
            icon: "list-checks",
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
            LucideIcon(symbol, size: size + 2)
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
            LucideIcon(icon, size: 14)
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
            LucideIcon("settings", size: labeled ? 15 : 14)
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
                    LucideIcon("check", size: 12)
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
