import AppKit
import GhosttyTerminal
import SwiftUI

/// Ghostty's view forwards right-clicks to the pty and never consults
/// `NSView.menu`, so surfacing Houston's terminal context menu (splits,
/// copy/paste) needs the override. Popping the menu also makes the clicked
/// pane first responder, which is what points the split commands at it.
///
/// Also the drop target: files dropped on the terminal insert their
/// shell-escaped paths at the prompt; image data and promised files
/// (drags from browsers, Photos, screenshots) are written to a temp file
/// first and that path is inserted — so an image can go straight to a
/// running agent.
final class HoustonTerminalView: AppTerminalView {
    var contextMenu: NSMenu?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.dropTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HoustonTerminalView is never decoded")
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking into the terminal counts as "outside" the right sheet —
        // ghostty consumes the click, so the dismiss rides a notification.
        NotificationCenter.default.post(name: .houstonTerminalClicked, object: nil)
        super.mouseDown(with: event)
    }

    // MARK: - Drag & drop

    private static let dropTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types += NSFilePromiseReceiver.readableDraggedTypes
            .map { NSPasteboard.PasteboardType($0) }
        types += NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        // The drop is an intent to type here next — focus like a click does.
        window?.makeFirstResponder(self)

        // Real files (Finder, most apps): insert their paths directly.
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            insert(paths: urls.map(\.path))
            return true
        }

        // Promised files (browsers, Photos): receive into a temp folder,
        // then insert as they land. The completion arrives on the queue we
        // pass — main — but isn't statically isolated, hence the unsafe box.
        if let receivers = pb.readObjects(
            forClasses: [NSFilePromiseReceiver.self]
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            let dir = Self.dropDirectory()
            nonisolated(unsafe) let view = self
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: dir, options: [:], operationQueue: .main
                ) { url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { view.insert(paths: [url.path]) }
                }
            }
            return true
        }

        // Raw image data with no file behind it: write a PNG, insert that.
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let url = Self.dropDirectory()
                .appendingPathComponent("dropped-image.png")
            guard (try? png.write(to: url)) != nil else { return false }
            insert(paths: [url.path])
            return true
        }
        return false
    }

    private func accepts(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self])
        || NSImage.canInit(with: pb)
    }

    /// Escaped, space-separated, with a trailing space so the next path (or
    /// the user's typing) doesn't fuse onto it. No newline — dropping never
    /// executes anything.
    private func insert(paths: [String]) {
        guard !paths.isEmpty else { return }
        sendText(paths.map(Self.shellEscaped).joined(separator: " ") + " ")
    }

    private static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "/._-~+@%:,="))
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A fresh folder per drop, so same-named files from consecutive drops
    /// never collide.
    private static func dropDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoustonDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
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

    /// Input sent before the surface exists, delivered on attach.
    ///
    /// A fresh pane has no surface until its view is mounted in a window
    /// with a real size (`rebuildIfReady` bails while detached), and
    /// `sendText` on a surfaceless view silently drops the bytes. Writing
    /// a command into a just-created pane — the server page's Start — lost
    /// the command and made the button need a second click.
    private var pendingInput = ""
    private var surfaceAttached = false

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
        guard surfaceAttached else {
            pendingInput += text
            return
        }
        deliver(text)
    }

    private func deliver(_ text: String) {
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

extension TerminalPane: TerminalSurfaceLifecycleDelegate {
    /// The surface (and its shell) exists now — release anything queued.
    /// The pty buffers the bytes until the shell reads them, so flushing
    /// right at attach is safe.
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        surfaceAttached = true
        guard !pendingInput.isEmpty else { return }
        let queued = pendingInput
        pendingInput = ""
        deliver(queued)
    }

    func terminalDidDetachSurface() {
        surfaceAttached = false
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
