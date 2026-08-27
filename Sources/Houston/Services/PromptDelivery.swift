import AppKit
import Foundation

/// One-stop prompt submission from anywhere in Houston: ensure the
/// project's terminal pane exists, type the prompt (submitted), and surface
/// the main window on that project. Used by the web preview's inspector and
/// the native App Inspector.
@MainActor
enum PromptDelivery {
    static func send(_ prompt: String, toProject path: String) {
        let manager = TerminalSessionManager.shared
        // send() is a silent no-op without a pane — create the shell first.
        if !manager.hasPane(for: path) { manager.pane(for: path) }
        manager.send(prompt + "\n", to: path)
        // present() is idempotent and makes sure MainWindowView exists to
        // catch the selection notification.
        MainWindowController.present()
        NotificationCenter.default.post(
            name: .houstonOpenProject, object: nil, userInfo: ["path": path]
        )
    }
}
