import AppKit

@MainActor
enum Actions {
    /// Opens the given absolute path in Finder. Used by row taps in the
    /// Projects tab.
    static func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a folder window in Finder (no selection). Used by the skills
    /// panel's empty state to open `~/.claude/skills`.
    static func openFolder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    /// Opens a file in a code editor — VS Code when installed, else whatever
    /// the system considers the default app for the file.
    static func openInEditor(path: String) {
        let url = URL(fileURLWithPath: path)
        if let vscode = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.microsoft.VSCode"
        ) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: vscode,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens an arbitrary URL in the user's default browser (or `open`-handler).
    static func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Sends SIGTERM to a pid. Best-effort — no-op if the process is already
    /// gone or the caller lacks permission. Used by the Servers tab "Stop"
    /// action.
    static func killPid(_ pid: Int32) {
        kill(pid, SIGTERM)
    }

    /// Modal directory chooser. Returns the picked absolute path, or nil if
    /// the user cancelled. The popover is briefly resigned-frontmost while the
    /// panel is open so it doesn't get dismissed by the activation change.
    static func pickDirectory(title: String, defaultPath: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let defaultPath {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
