import AppKit
import SwiftUI

/// One web-preview window per dev server. Keyed by port, not `DevServer.id`
/// ("pid:port") — a server restart changes the pid, and the window should
/// keep meaning "the thing at localhost:5173".
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {

    /// The registry is also the retain: `NSWindow.delegate` is weak, so
    /// each controller lives here until its window closes.
    private static var open: [Int: PreviewWindowController] = [:]

    private let model: WebPreviewModel

    static func present(server: DevServer) {
        if let existing = open[server.port] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PreviewWindowController(server: server)
        open[server.port] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(server: DevServer) {
        model = WebPreviewModel(server: server)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            // Standard visible title bar — unlike the main window, there is
            // no sidebar chrome to own, and a free title beats hand-drawn.
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(server.project ?? server.command) — localhost:\(String(server.port))"
        window.backgroundColor = NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? 0x1E1E1E : 0xFFFFFF)
        }
        let host = NSHostingController(rootView: WebPreviewView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        // Assigning `contentViewController` resizes the window to the view's
        // fitting size — with no sizing options that's ~1×1. Same documented
        // trap as MainWindowController: re-assert size after assignment.
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.center()
        let saved = HoustonSettings.read().previewWindowFrame
        if saved.count == 4 {
            let frame = NSRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            }
        }
        // All preview windows share one saved frame — a second concurrent
        // window steps aside instead of stacking exactly on the first.
        if let front = Self.open.values.first?.window {
            window.cascadeTopLeft(from: NSPoint(
                x: front.frame.minX, y: front.frame.maxY
            ))
        }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 400)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: - NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, window.frame.width >= 500, window.frame.height >= 400 else { return }
        var s = HoustonSettings.read()
        s.previewWindowFrame = [
            window.frame.origin.x, window.frame.origin.y,
            window.frame.width, window.frame.height,
        ]
        HoustonSettings.write(s)
    }

    func windowWillClose(_ notification: Notification) {
        model.teardown()
        Self.open[model.server.port] = nil
    }
}
