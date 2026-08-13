import AppKit
import GhosttyTerminal
import SwiftUI

/// Ghostty's view forwards right-clicks to the pty and never consults
/// `NSView.menu`, so surfacing Houston's terminal context menu (splits,
/// copy/paste) needs the override. Popping the menu also makes the clicked
/// pane first responder, which is what points the split commands at it.
final class HoustonTerminalView: AppTerminalView {
    var contextMenu: NSMenu?

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }
}

/// One terminal pane: a live PTY in a project directory.
///
/// The pane creates and **retains** its `AppTerminalView` for its whole
/// lifetime. Swapping the sidebar selection re-parents this view; it is never
/// rebuilt, so the underlying shell survives navigation.
@MainActor
final class TerminalPane: Identifiable, ObservableObject {
    let id = UUID()
    let projectPath: String

    /// Strongly held — the pane owns the surface, not SwiftUI.
    let view: HoustonTerminalView

    /// Whether this pane has already claimed keyboard focus once.
    ///
    /// Focus is taken when a project's terminal is *first* shown — you just
    /// opened it, you want to type — but not on every subsequent selection.
    /// Re-grabbing it each time meant clicking a sidebar row immediately
    /// yanked focus out of the sidebar, so arrow-key navigation never worked
    /// after a click.
    var hasAutoFocused = false

    /// Fired when the shell process ends (ctrl-D, `exit`) — the manager
    /// closes this pane in response.
    var onShellExit: (() -> Void)?

    init(projectPath: String, controller: TerminalController) {
        self.projectPath = projectPath
        let v = HoustonTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        v.controller = controller
        v.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: projectPath,
            envVars: TerminalEnvironment.surfaceEnv(paneID: id.uuidString)
        )
        view = v
        // Weak on the view's side; the pane owns the view.
        v.delegate = self
    }

    /// Write UTF-8 straight to the pty. This is the embedded replacement for
    /// System Events keystrokes — no Accessibility permission, no focus race,
    /// and it cannot land in the wrong window.
    ///
    /// `sendText` delivers text as a *paste* (`ghostty_surface_text`), and
    /// zsh's bracketed paste turns a pasted trailing "\n" into buffer content
    /// instead of executing it — the command just sat highlighted at the
    /// prompt. A trailing newline is therefore delivered separately through
    /// the `text:\r` binding action, which writes the CR raw to the pty, the
    /// same byte a Return keypress produces.
    func send(_ text: String) {
        guard text.hasSuffix("\n") else {
            view.sendText(text)
            return
        }
        let body = String(text.dropLast())
        if !body.isEmpty { view.sendText(body) }
        if !view.performBindingAction("text:\\r") {
            view.sendText("\r")
        }
    }

    /// Ends the session and frees the surface.
    ///
    /// **Dropping references is not enough** — verified by probe: after
    /// releasing the pane the shell was still running. `TerminalController`
    /// keeps every surface's callback bridge in `retainedBridges`, so the
    /// coordinator never deallocates and `TerminalSurface.deinit` (which
    /// deliberately has no free-on-dealloc safety net) never runs.
    ///
    /// Setting `controller = nil` is the explicit teardown: its `didSet` calls
    /// `rebuildIfReady(removingBridgeFrom:)`, which tears the surface down,
    /// unregisters the bridge, and then bails out of rebuilding because there
    /// is no controller.
    func teardown() {
        view.controller = nil
        view.removeFromSuperview()
        StatusLineFeed.removeSnapshot(paneID: id.uuidString)
    }
}

extension TerminalPane: TerminalSurfaceCloseDelegate {
    /// Ghostty's close-surface callback — the shell exited on its own.
    func terminalDidClose(processAlive: Bool) {
        onShellExit?()
    }
}

/// Hosts a project's pane tree inside SwiftUI without owning its lifetime.
///
/// `makeNSView` returns the manager's shared container. `updateNSView` asks
/// the manager to mount whichever project's tree should currently be visible.
/// Because terminal views are retained by their panes and arranged by the
/// manager's split trees, SwiftUI re-renders and selection changes just
/// re-parent existing surfaces instead of tearing down PTYs.
struct TerminalHostView: NSViewRepresentable {
    let path: String?
    /// Which of the project's tabs to show; nil is its first.
    var tabID: UUID?

    func makeNSView(context: Context) -> NSView {
        // Shared, manager-owned — see TerminalSessionManager.paneContainer for
        // why this must not be created per-render.
        TerminalSessionManager.shared.paneContainer
    }

    func updateNSView(_ container: NSView, context: Context) {
        TerminalSessionManager.shared.mountRoot(for: path, tab: tabID, in: container)
    }
}
