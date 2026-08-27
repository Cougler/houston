import AppKit
import SwiftUI
import UserNotifications

/// Houston is a normal windowed app with a menubar item that toggles the
/// window. The old menubar popover (a port of the Electron build's tabbed UI)
/// was removed — the desktop window covers the same ground and having both
/// meant two UIs over the same data.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let trayImage = loadTrayImage() {
                trayImage.isTemplate = true
                button.image = trayImage
                button.imagePosition = .imageOnly
            } else {
                button.title = "Houston"
            }
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.action = #selector(statusBarClicked(_:))
            button.target = self
        }

        // Banner clicks route back here (`didReceive`). No bundle id means
        // no notification center (debug builds) — badges still work.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        MainWindowController.present()
        Self.logLifecycle("launched")
        UpdateChecker.shared.start()
    }

    /// Amber dot beside the menubar glyph while any session needs the user.
    func setNeedsAttentionBadge(_ on: Bool) {
        guard let button = statusItem?.button else { return }
        if on {
            button.attributedTitle = NSAttributedString(
                string: " ●",
                attributes: [
                    .foregroundColor: NSColor(hex: 0xD97706),
                    .font: NSFont.systemFont(ofSize: 8),
                    .baselineOffset: 2,
                ]
            )
            button.imagePosition = .imageLeft
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = button.image == nil ? .noImage : .imageOnly
        }
    }

    /// A clean quit (⌘Q, menubar Quit, logout) passes through here; a signal
    /// kill doesn't. So when Houston "was just closed" with no crash report,
    /// this log tells the two apart: a `terminating` line means someone quit
    /// it, its absence means an outside kill. Added after an unexplained
    /// close on 2026-08-16 that left no crash report and no kill in any
    /// session transcript.
    func applicationWillTerminate(_ notification: Notification) {
        Self.logLifecycle("terminating")
    }

    private static func logLifecycle(_ event: String) {
        let dir = ("~/Library/Application Support/Houston" as NSString)
            .expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let url = URL(fileURLWithPath: dir).appendingPathComponent("lifecycle.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event) pid=\(ProcessInfo.processInfo.processIdentifier)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Re-open the window when the Dock icon is clicked and nothing is visible.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { MainWindowController.present() }
        return true
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showStatusMenu()
        } else {
            MainWindowController.present()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Open Houston",
            action: #selector(openWindow),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Inspect an App…") {
            // The status menu runs a modal tracking loop via performClick —
            // defer window creation until it unwinds.
            DispatchQueue.main.async { AXInspector.shared.begin() }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Check for Updates…") {
            UpdateChecker.shared.checkInteractively()
        })
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Houston",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openWindow() {
        MainWindowController.present()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content
            .userInfo["path"] as? String
        Task { @MainActor in
            MainWindowController.present()
            if let path {
                NotificationCenter.default.post(
                    name: .houstonOpenProject,
                    object: nil,
                    userInfo: ["path": path]
                )
            }
        }
        completionHandler()
    }

    /// Merges `tray.png` (22×22) and `tray@2x.png` (44×44) into one image with a
    /// 22pt logical size, so AppKit picks the right rep per scale factor.
    private func loadTrayImage() -> NSImage? {
        guard let url1x = Bundle.module.url(
            forResource: "tray", withExtension: "png", subdirectory: "icons"
        ) else { return nil }

        let image = NSImage()
        if let rep1x = NSImageRep(contentsOf: url1x) { image.addRepresentation(rep1x) }
        if let url2x = Bundle.module.url(
            forResource: "tray@2x", withExtension: "png", subdirectory: "icons"
        ), let rep2x = NSImageRep(contentsOf: url2x) {
            image.addRepresentation(rep2x)
        }
        guard !image.representations.isEmpty else { return nil }
        image.size = NSSize(width: 22, height: 22)
        return image
    }
}
