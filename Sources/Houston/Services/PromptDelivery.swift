import AppKit
import Foundation

/// One-stop prompt submission from anywhere in Houston: ensure the
/// project's terminal pane exists, type the prompt (submitted), and surface
/// the main window on that project. Used by the web preview's inspector.
@MainActor
enum PromptDelivery {
    static func send(_ prompt: String, toProject path: String) {
        let manager = TerminalSessionManager.shared
        // send() is a silent no-op without a pane — create the shell first.
        if !manager.hasPane(for: path) { manager.pane(for: path) }
        if manager.agents[path] == nil {
            // No agent in the pane — the prompt would land at the shell
            // prompt as plain text. Launch claude with it as the argument.
            let quoted = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
            manager.send("claude " + quoted + "\n", to: path)
        } else {
            manager.send(prompt + "\n", to: path)
        }
        // present() is idempotent and makes sure MainWindowView exists to
        // catch the selection notification.
        MainWindowController.present()
        NotificationCenter.default.post(
            name: .houstonOpenProject, object: nil, userInfo: ["path": path]
        )
    }

    /// A chat hit a "not signed in" error: put the user in front of the
    /// provider's login flow in the project's terminal. Claude Code signs
    /// in through its /login dialog (sent straight into a running claude,
    /// or `claude /login` at the shell); Codex through `codex login`. A
    /// pane busy with a *different* agent gets a fresh tab so the command
    /// can't land inside the wrong REPL.
    static func login(_ harness: ChatHarness, project path: String) {
        let manager = TerminalSessionManager.shared
        if !manager.hasPane(for: path) { _ = manager.pane(for: path) }
        let command = harness == .claude ? "claude /login\n" : "codex login\n"
        let running = manager.agents[path]
        var tabID: UUID?
        if harness == .claude, running == .claude {
            manager.send("/login\n", to: path)
        } else if running == nil {
            manager.send(command, to: path)
        } else if let tab = manager.newTab(in: path) {
            tab.panes.first?.send(command)
            tabID = tab.id
        } else {
            manager.send(command, to: path)
        }
        MainWindowController.present()
        var info: [String: Any] = ["path": path]
        if let tabID { info["tab"] = tabID.uuidString }
        NotificationCenter.default.post(
            name: .houstonOpenProject, object: nil, userInfo: info
        )
    }
}
