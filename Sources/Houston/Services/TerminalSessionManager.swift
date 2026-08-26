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
    /// User-given sidebar name; nil falls back to the directory-based title.
    fileprivate(set) var customName: String?

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
    @Published private(set) var tabs: [String: [TerminalTab]] = [:] {
        didSet { updateNapActivity() }
    }

    /// Held while any terminal exists. App Nap throttles a bundled app that
    /// hasn't seen input for a while, freezing the visible terminal's
    /// rendering until the next click (the shell-spawned debug binary was
    /// never napped, which is why this only surfaced in the packaged build).
    /// `.userInitiatedAllowingIdleSystemSleep` defeats nap without keeping
    /// the whole Mac awake.
    private var napActivity: NSObjectProtocol?

    private func updateNapActivity() {
        let hasPanes = tabs.contains { !$0.value.isEmpty }
        if hasPanes, napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Hosting terminal sessions"
            )
        } else if !hasPanes, let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

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

    /// Houston's design-matched terminal: #111 over the alabaster ANSI
    /// palette in light, #E8E8E8 over afterglow in dark. The background sits
    /// a step *darker* than the chrome in both modes (chrome is #EBEBEB /
    /// #1E1E1E), so the terminal reads as its own recessed surface.
    private static var designTheme: TerminalTheme {
        TerminalTheme(
            light: TerminalConfiguration.alabaster
                .background("E0E0E0")
                .foreground("111111")
                .cursorColor("111111"),
            dark: TerminalConfiguration.afterglow
                .background("181818")
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
        // A brand-new first pane can't have an agent yet, but the polled
        // `agents` map can hold a stale entry from a just-closed session for
        // up to a scan cycle — which flashed the status bar's session items
        // for a couple of seconds on open.
        agents.removeValue(forKey: projectPath)
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
        hookExit(pane)
        let root = NSView()
        fill(root, with: pane.view)
        revealAfterBoot(pane)
        return TerminalTab(projectPath: projectPath, root: root, panes: [pane])
    }

    /// The shell exiting (ctrl-D, `exit`) closes its pane — ghostty's
    /// close-surface callback, routed through the pane's delegate.
    private func hookExit(_ pane: TerminalPane) {
        pane.onShellExit = { [weak self, weak pane] in
            guard let pane else { return }
            self?.closePane(pane)
        }
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

    /// Renames a terminal's sidebar row; nil or empty restores the default.
    /// `TerminalTab` is a class, so republishing needs an explicit nudge.
    func renameTab(path: String, tabID: UUID, to name: String?) {
        guard let tab = tabs[path]?.first(where: { $0.id == tabID }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        objectWillChange.send()
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
        hookExit(newPane)
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

    /// Closes the focused split within its tab — see `closePane(_:)`.
    func closeFocusedSplit(path: String? = nil) {
        guard let path = path ?? activeProjectPath,
              let target = actionPane(in: path) else { return }
        closePane(target)
    }

    /// Closes one specific pane wherever it lives (⇧⌘W on it, or its shell
    /// exiting), unwrapping its `NSSplitView` when only one cell remains.
    /// A tab's last pane closing closes the tab; the project's last tab
    /// closing ends its shell entirely.
    func closePane(_ target: TerminalPane) {
        let path = target.projectPath
        guard let list = tabs[path],
              let tab = list.first(where: { candidate in
                  candidate.panes.contains { $0 === target }
              }) else { return }
        guard tab.panes.count > 1 else {
            closeTab(path: path, tabID: tab.id)
            return
        }

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
            agents.removeValue(forKey: path)
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
        agents.removeValue(forKey: projectPath)
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

    /// Moves keyboard focus into a project's terminal, so selecting a row
    /// means "type here now". If focus already sits in one of the tab's
    /// panes (a split), it stays put. Async because on a first open the
    /// view isn't in the window until the render pass mounts it.
    func focusTerminal(path: String, tab tabID: UUID? = nil) {
        guard let tab = resolveTab(path: path, id: tabID) else { return }
        if let responder = paneContainer.window?.firstResponder as? NSView,
           tab.panes.contains(where: {
               responder === $0.view || responder.isDescendant(of: $0.view)
           }) {
            return
        }
        guard let pane = tab.panes.first else { return }
        pane.hasAutoFocused = true
        Self.focusWhenMounted(pane.view)
    }

    /// A first open mounts the pane on the *next* render pass, and one async
    /// hop isn't always enough — an in-flight animation (the onboarding
    /// dismissal springs, a sheet transition) can push the mount past it,
    /// and the old single-shot `makeFirstResponder` then silently dropped
    /// focus: the terminal looked open but typing went nowhere until the
    /// row was clicked again. Retry briefly instead. A retry can only ever
    /// land on a mounted, displayed pane (unmounted views have no window),
    /// so a stale one after a quick selection change is a harmless no-op.
    private static func focusWhenMounted(_ view: NSView, attempts: Int = 10) {
        DispatchQueue.main.async {
            if let window = view.window, window.makeFirstResponder(view) {
                return
            }
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusWhenMounted(view, attempts: attempts - 1)
            }
        }
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
            let needsSudo = Self.npmGlobalNeedsSudo()
            await MainActor.run {
                self.installedAgents = found
                self.npmNeedsSudo = needsSudo
            }
        }
    }

    /// The npm global prefix is root-owned (stock /usr/local) — installs
    /// there need sudo. On Homebrew/nvm setups the prefix is user-writable
    /// and sudo would just booby-trap `~/.npm` with root-owned cache files.
    private(set) var npmNeedsSudo = false

    private nonisolated static func npmGlobalNeedsSudo() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Login shell so npm resolves through the user's real PATH.
        process.arguments = ["-lc", "npm prefix -g"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard let data = try? out.fileHandleForReading.readToEnd(),
              let prefix = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !prefix.isEmpty else { return false }
        let fm = FileManager.default
        // Global installs write into <prefix>/lib/node_modules.
        let modules = prefix + "/lib/node_modules"
        let target = fm.fileExists(atPath: modules) ? modules : prefix
        return !fm.isWritableFile(atPath: target)
    }

    /// The agent's install command, with `sudo` prepended for npm installs
    /// when the global prefix isn't user-writable. Shown verbatim in the
    /// confirm dialog, so the sudo is never a surprise.
    func installCommand(for agent: CodingAgent) -> String? {
        guard let command = agent.installCommand else { return nil }
        guard npmNeedsSudo, command.hasPrefix("npm ") else { return command }
        return "sudo " + command
    }

    /// Types the agent's install command into the project's focused pane —
    /// in the open, where the user watches it run — then re-probes until the
    /// binary appears so the dropdown unmarks it.
    func install(_ agent: CodingAgent, in projectPath: String) {
        guard let command = installCommand(for: agent) else { return }
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
