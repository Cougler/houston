import AppKit
import SwiftUI

/// The desktop window. Houston keeps its menubar item, but the main surface is
/// now a normal app window (sidebar + terminal), which is also what gets us a
/// real main menu — and therefore working ⌘C/⌘V inside the terminal.
@MainActor
enum MainWindowController {

    private static var controller: NSWindowController?
    /// Retained here because `NSWindow.delegate` is weak.
    private static let frameSaver = WindowFrameSaver()

    static func present() {
        if let controller {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1018, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? 0x1E1E1E : 0xFFFFFF)
        }
        // Own the whole window: content runs edge-to-edge under a transparent,
        // title-less title bar so the header and its controls are ours to place
        // instead of being handed to `.toolbar`. The traffic lights stay in the
        // standard position and float over the content — `MainWindowView`
        // reserves `trafficLightInset` at the top of the sidebar for them.
        window.title = "Houston"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // `contentViewController`, not a bare `contentView`: an NSHostingView
        // assigned directly doesn't track the window's size, so the SwiftUI
        // tree sized itself to fit and sat centred with dead space around it.
        let host = NSHostingController(rootView: MainWindowView())
        host.sizingOptions = []
        window.contentViewController = host
        // Assigning `contentViewController` resizes the window to the view's
        // fitting size — with no sizing options that's ~1×1, an invisible
        // window. Re-assert the default size, center, and only then attach
        // the autosave name (which restores a previous session's frame when
        // one exists — the debug build's saved frame is what masked this).
        window.setContentSize(NSSize(width: 1018, height: 660))
        window.center()
        window.setFrameAutosaveName("HoustonMainWindow")
        // A saved frame from a run that hit the collapse would restore the
        // 1×1 window right back — never honour a degenerate frame.
        if window.frame.width < 400 || window.frame.height < 300 {
            window.setContentSize(NSSize(width: 1018, height: 660))
            window.center()
        }
        // settings.json's frame wins over the UserDefaults autosave: it
        // survives updates and is shared by debug and packaged builds,
        // whose defaults domains differ. The autosave stays as a fallback
        // for pre-existing installs with nothing in settings yet.
        let saved = HoustonSettings.read().windowFrame
        if saved.count == 4 {
            let frame = NSRect(x: saved[0], y: saved[1], width: saved[2], height: saved[3])
            // Only restore a frame some screen can actually show.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            }
        }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 460)

        // Persist the frame as it changes (delegate, not NotificationCenter
        // closures — NSWindowDelegate is main-actor, so no Sendable dance).
        window.delegate = frameSaver


        let wc = NSWindowController(window: window)
        controller = wc

        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Writes the window frame into settings.json whenever a move or live
/// resize ends, so size and position survive relaunches AND updates —
/// unlike the UserDefaults autosave, settings.json is one store shared by
/// debug and packaged builds.
@MainActor
private final class WindowFrameSaver: NSObject, NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        save(notification)
    }

    func windowDidMove(_ notification: Notification) {
        save(notification)
    }

    private func save(_ notification: Notification) {
        // The same degenerate-frame guard as restore — never persist a
        // collapsed window.
        guard let window = notification.object as? NSWindow,
              window.frame.width >= 400, window.frame.height >= 300 else { return }
        var s = HoustonSettings.read()
        s.windowFrame = [
            window.frame.origin.x, window.frame.origin.y,
            window.frame.width, window.frame.height,
        ]
        HoustonSettings.write(s)
    }
}
