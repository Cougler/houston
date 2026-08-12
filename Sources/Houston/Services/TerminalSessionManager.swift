import AppKit
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// Owns the single libghostty runtime and every terminal pane Houston hosts.
///
/// `TerminalController` initialises the ghostty app runtime, so there is
/// exactly one for the process. Panes are cheap surfaces created against it.
///
/// **Panes own their `AppTerminalView`, not SwiftUI.** A pane's surface is a
/// live PTY; if SwiftUI were allowed to own the view it would destroy and
/// recreate it whenever the layout re-rendered or the selection changed,
/// killing the claude process each time. `TerminalHostView` therefore only
/// *adopts* a project's existing view tree as a subview.
///
/// **Splits.** A project owns a list of panes arranged in an `NSSplitView`
/// tree under `roots[path]` — splitting wraps the focused pane's view in a
/// new split alongside a fresh pane, closing a split unwraps it. The tree is
/// plain AppKit (frames + autoresizing), so re-parenting on selection change
/// stays a no-op for the PTYs.
/// One sidebar terminal for a project: an independent view tree holding a
/// pane or an `NSSplitView` arrangement of panes. A project's first tab is
/// its main terminal; additional tabs appear as nested "Shell N" rows under
/// it in the sidebar, each hosting its own shell in the same directory.
@MainActor
final class TerminalTab: Identifiable {
    nonisolated let id = UUID()
    let projectPath: String
    /// The mountable view: the tab's pane, or its split tree.
    let root: NSView
    /// Panes living inside this tab (grows via ⌘D splits).
    fileprivate(set) var panes: [TerminalPane]

    fileprivate init(projectPath: String, root: NSView, panes: [TerminalPane]) {
        self.projectPath = projectPath
        self.root = root
        self.panes = panes
    }
}

@MainActor
final class TerminalSessionManager: NSObject, ObservableObject {

    static let shared = TerminalSessionManager()

    /// Every project's terminal tabs, in creation order. A project with any
    /// tabs has a shell; each tab owns its own on-screen view tree.
    @Published private(set) var tabs: [String: [TerminalTab]] = [:]

    /// Which coding agent is running in each project's panes, by path.
    /// Refreshed by polling the process tree, so it reflects
    /// `claude`/`codex`/etc. typed directly into the shell — not just agents
    /// Houston started.
    @Published private(set) var agents: [String: CodingAgent] = [:]

    /// The project whose terminal is currently displayed — the target for
    /// menu-bar split commands. Set by the window on selection change; not
    /// published (nothing renders from it).
    var activeProjectPath: String?

    /// The displayed tab within that project (nil means its first tab).
    /// Also set by the window on selection change.
    var activeTabID: UUID?

    /// Launchable agents whose CLI is actually installed — what the header's
    /// harness dropdown offers. Empty until detection completes.
    @Published private(set) var installedAgents: [CodingAgent] = []

    private var agentTimer: Timer?
    private var agentScanInFlight = false

    private var _controller: TerminalController?

    /// The one container every project root is mounted into.
    ///
    /// Owned here rather than returned fresh from `makeNSView` because SwiftUI
    /// recreates representables freely (the sidebar republishes every 2s). A
    /// per-render container meant the pane's view was detached and reattached
    /// constantly, and every reattach with a torn-down surface made libghostty
    /// build a **new** one — observed as three shells spawned for a single
    /// pane. One stable container makes re-parenting a no-op.
    let paneContainer: NSView = {
        let v = NSView()
        v.wantsLayer = true
        return v
    }()

    /// Lazily built so Houston doesn't pay ghostty runtime init unless a
    /// terminal is actually opened.
    ///
    /// No `command` is configured, so surfaces launch the user's **default
    /// login shell**. Selecting a project therefore just opens a terminal in
    /// that directory — it does not start an agent. Starting claude is an
    /// explicit act (`start(_:in:)` / the header's play button), which also means
    /// clicking a project that already has a session running elsewhere can no
    /// longer spawn a duplicate agent.
    var controller: TerminalController {
        if let _controller { return _controller }
        // Font, cursor style and padding ride in the base configuration so
        // they hold across any theme; colors come from the theme, which the
        // surface resolves per light/dark appearance automatically.
        let base = TerminalConfiguration()
            .fontSize(13)
            .cursorStyle(.bar)
            .windowPaddingX(24)
            .windowPaddingY(12)
        let c = TerminalController(
            configSource: .none,
            theme: Self.resolvedTheme(named: HoustonSettings.read().terminalTheme),
            terminalConfiguration: base
        )
        _controller = c
        return c
    }

    /// Houston's design-matched terminal: white/#111 over the alabaster ANSI
    /// palette in light, #1E1E1E/#E8E8E8 over afterglow in dark.
    private static var designTheme: TerminalTheme {
        TerminalTheme(
            light: TerminalConfiguration.alabaster
                .background("FFFFFF")
                .foreground("111111")
                .cursorColor("111111"),
            dark: TerminalConfiguration.afterglow
                .background("1E1E1E")
                .foreground("E8E8E8")
                .cursorColor("E8E8E8")
        )
    }

    /// A ghostty catalog theme by name, or the design default for "" and
    /// unknown names.
    private static func resolvedTheme(named name: String) -> TerminalTheme {
        guard !name.isEmpty, let def = GhosttyThemeCatalog.theme(named: name) else {
            return designTheme
        }
        return def.toTerminalTheme()
    }

    /// Restyles running shells live; new shells pick the setting up on their
    /// own.
    func applyTerminalTheme(named name: String) {
        _controller?.setTheme(Self.resolvedTheme(named: name))
    }

    // MARK: - Tabs

    /// Opens a project's shell if it has none. Idempotent: clicking back to a
    /// project re-attaches to its existing tabs rather than opening more.
    @discardableResult
    func pane(for projectPath: String) -> TerminalPane? {
        if let existing = tabs[projectPath]?.first?.panes.first { return existing }
        guard let tab = makeTab(projectPath) else { return nil }
        tabs[projectPath] = [tab]
        return tab.panes.first
    }

    /// A further shell in the same directory, as its own sidebar row nested
    /// under the project's terminal. Only meaningful once the project has one.
    @discardableResult
    func newTab(in projectPath: String) -> TerminalTab? {
        guard tabs[projectPath]?.isEmpty == false,
              let tab = makeTab(projectPath) else { return nil }
        tabs[projectPath]?.append(tab)
        return tab
    }

    private func makeTab(_ projectPath: String) -> TerminalTab? {
        // Defensive: only ever open a shell in a real directory. A sidebar row
        // whose selection tag wasn't a path once got this far and spawned a
        // shell with a bogus cwd.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        let pane = TerminalPane(projectPath: projectPath, controller: controller)
        pane.view.contextMenu = terminalContextMenu(path: projectPath)
        let root = NSView()
        fill(root, with: pane.view)
        revealAfterBoot(pane)
        return TerminalTab(projectPath: projectPath, root: root, panes: [pane])
    }

    func hasPane(for projectPath: String) -> Bool {
        !(tabs[projectPath]?.isEmpty ?? true)
    }

    /// Runs an agent's CLI in the project's focused pane, opening a shell if
    /// needed. Explicit by design — see `controller`.
    func start(_ agent: CodingAgent, in projectPath: String) {
        guard let binary = agent.binary else { return }
        if tabs[projectPath]?.isEmpty ?? true { pane(for: projectPath) }
        actionPane(in: projectPath)?.send(binary + "\n")
    }

    /// Writes into the project's focused pane (used by the skills panel).
    func send(_ text: String, to projectPath: String) {
        actionPane(in: projectPath)?.send(text)
    }

    // MARK: - Splits

    /// Splits the focused pane within its tab: a fresh shell opens beside
    /// (`vertical`) or below it, and takes keyboard focus — Ghostty's
    /// behaviour.
    func split(path: String? = nil, vertical: Bool) {
        guard let path = path ?? activeProjectPath,
              let tab = actionTab(in: path),
              let target = actionPane(in: path) else { return }

        let newPane = TerminalPane(projectPath: path, controller: controller)
        newPane.view.contextMenu = terminalContextMenu(path: path)
        tab.panes.append(newPane)

        let targetView = target.view
        let splitView = NSSplitView()
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        splitView.frame = targetView.frame
        splitView.autoresizingMask = targetView.autoresizingMask
        // Wrap the target in place: its slot (root child or split cell)
        // becomes a two-cell split of [target, new].
        targetView.superview?.replaceSubview(targetView, with: splitView)
        splitView.addSubview(targetView)
        splitView.addSubview(newPane.view)
        newPane.view.autoresizingMask = [.width, .height]
        newPane.view.translatesAutoresizingMaskIntoConstraints = true

        revealAfterBoot(newPane)
        // Halve once laid out — freshly added cells otherwise size unevenly.
        DispatchQueue.main.async {
            let span = vertical ? splitView.bounds.width : splitView.bounds.height
            if span > 0 { splitView.setPosition(span / 2, ofDividerAt: 0) }
            newPane.view.window?.makeFirstResponder(newPane.view)
        }
    }

    /// Closes the focused split within its tab, unwrapping its `NSSplitView`
    /// when only one cell remains. Closing a tab's last pane closes the tab;
    /// closing the project's last tab closes its shell entirely.
    func closeFocusedSplit(path: String? = nil) {
        guard let path = path ?? activeProjectPath,
              let tab = actionTab(in: path) else { return }
        guard tab.panes.count > 1 else {
            closeTab(path: path, tabID: tab.id)
            return
        }
        guard let target = actionPane(in: path) else { return }

        let targetView = target.view
        if let split = targetView.superview as? NSSplitView {
            targetView.removeFromSuperview()
            if split.subviews.count == 1, let survivor = split.subviews.first {
                survivor.frame = split.frame
                survivor.autoresizingMask = split.autoresizingMask
                split.superview?.replaceSubview(split, with: survivor)
            }
        }
        target.teardown()
        tab.panes.removeAll { $0 === target }
        if let next = tab.panes.last {
            DispatchQueue.main.async {
                next.view.window?.makeFirstResponder(next.view)
            }
        }
    }

    /// Ends one tab and releases its surfaces. The last tab going ends the
    /// project's shell.
    func closeTab(path: String, tabID: UUID) {
        guard var list = tabs[path],
              let index = list.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = list.remove(at: index)
        tab.panes.forEach { $0.teardown() }
        tab.root.removeFromSuperview()
        if list.isEmpty {
            tabs.removeValue(forKey: path)
        } else {
            tabs[path] = list
        }
    }

    /// Ends every tab of a project and releases its surfaces.
    func closePane(for projectPath: String) {
        guard let list = tabs[projectPath] else { return }
        for tab in list {
            tab.panes.forEach { $0.teardown() }
            tab.root.removeFromSuperview()
        }
        tabs.removeValue(forKey: projectPath)
    }

    // MARK: - Mounting

    /// Shows one tab's pane tree inside `container` (the shared
    /// `paneContainer`); nil `tabID` means the project's first tab.
    /// Re-parenting an existing root is a no-op for the running PTYs.
    func mountRoot(for path: String?, tab tabID: UUID?, in container: NSView) {
        guard let path, let tab = resolveTab(path: path, id: tabID) else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if tab.root.superview === container { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        fill(container, with: tab.root)

        // The terminal claims focus on a tab's first display only —
        // re-grabbing on every selection yanked focus out of the sidebar the
        // instant a row was clicked, so arrow-key navigation never worked.
        if let first = tab.panes.first, !first.hasAutoFocused {
            first.hasAutoFocused = true
            DispatchQueue.main.async {
                first.view.window?.makeFirstResponder(first.view)
            }
        }
    }

    private func resolveTab(path: String, id: UUID?) -> TerminalTab? {
        guard let list = tabs[path] else { return nil }
        guard let id else { return list.first }
        return list.first { $0.id == id }
    }

    // MARK: - Internals

    /// Right-click menu for a terminal pane. Copy/Paste dispatch through the
    /// responder chain to the clicked pane (right-click focuses it first —
    /// see `HoustonTerminalView`), which is also what points the split
    /// commands at it.
    private func terminalContextMenu(path: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        menu.addItem(.separator())
        let right = ClosureMenuItem("Split Right") { [weak self] in
            self?.split(path: path, vertical: true)
        }
        right.keyEquivalent = "d"
        right.keyEquivalentModifierMask = [.command]
        menu.addItem(right)
        let down = ClosureMenuItem("Split Down") { [weak self] in
            self?.split(path: path, vertical: false)
        }
        down.keyEquivalent = "d"
        down.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(down)
        menu.addItem(.separator())
        let close = ClosureMenuItem("Close Split") { [weak self] in
            self?.closeFocusedSplit(path: path)
        }
        close.keyEquivalent = "w"
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(close)
        return menu
    }

    /// The tab a split/close/send should act on: the one holding keyboard
    /// focus, else the displayed one, else the project's first.
    private func actionTab(in path: String) -> TerminalTab? {
        let list = tabs[path] ?? []
        if let responder = paneContainer.window?.firstResponder as? NSView,
           let focused = list.first(where: { responder.isDescendant(of: $0.root) }) {
            return focused
        }
        if let activeTabID, let displayed = list.first(where: { $0.id == activeTabID }) {
            return displayed
        }
        return list.first
    }

    /// The pane within that tab: the one holding keyboard focus, else the
    /// most recently created.
    private func actionPane(in path: String) -> TerminalPane? {
        guard let tab = actionTab(in: path) else { return nil }
        if let responder = paneContainer.window?.firstResponder as? NSView,
           let focused = tab.panes.first(where: {
               responder === $0.view || responder.isDescendant(of: $0.view)
           }) {
            return focused
        }
        return tab.panes.last
    }

    /// Frame-based fill — the whole tree uses autoresizing, so views can move
    /// between root, split cells and the shared container without constraint
    /// surgery.
    private func fill(_ parent: NSView, with child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = true
        child.frame = parent.bounds
        child.autoresizingMask = [.width, .height]
        parent.addSubview(child)
    }

    /// First display of a fresh surface: keep it invisible for a beat while
    /// Metal's first paint and the grid resize settle, then fade in.
    private func revealAfterBoot(_ pane: TerminalPane) {
        let view = pane.view
        view.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak view] in
            guard let view else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                view.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Agent polling

    /// One-shot: resolves which agent CLIs exist on this machine (login-shell
    /// PATH). Runs detached — the lookup spawns a login shell.
    func detectInstalledAgents() {
        guard installedAgents.isEmpty else { return }
        Task.detached(priority: .utility) {
            let found = AgentDetect.installedAgents()
            await MainActor.run { self.installedAgents = found }
        }
    }

    /// Types the agent's install command into the project's focused pane —
    /// in the open, where the user watches it run — then re-probes until the
    /// binary appears so the dropdown unmarks it.
    func install(_ agent: CodingAgent, in projectPath: String) {
        guard let command = agent.installCommand else { return }
        if tabs[projectPath]?.isEmpty ?? true { pane(for: projectPath) }
        actionPane(in: projectPath)?.send(command + "\n")
        Task.detached(priority: .utility) {
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                let found = AgentDetect.installedAgents()
                let done = found.contains(agent)
                await MainActor.run { self.installedAgents = found }
                if done { return }
            }
        }
    }

    /// Starts polling the process tree for agents running in panes. Cheap and
    /// idle when there are no panes.
    func startAgentPolling() {
        guard agentTimer == nil else { return }
        refreshAgents()
        agentTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAgents() }
        }
    }

    /// The scan shells out to `ps` and `lsof`, so it runs detached — on the
    /// main thread it stalled the UI for the duration of both, every tick.
    private func refreshAgents() {
        let paths = Set(tabs.keys)
        guard !paths.isEmpty else {
            if !agents.isEmpty { agents = [:] }
            return
        }
        guard !agentScanInFlight else { return }
        agentScanInFlight = true
        Task.detached(priority: .utility) {
            let found = AgentDetect.snapshot(paths: paths)
            await MainActor.run {
                self.agentScanInFlight = false
                if found != self.agents { self.agents = found }
            }
        }
    }
}
