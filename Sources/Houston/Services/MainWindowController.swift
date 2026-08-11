import AppKit
import SwiftUI

/// The desktop window. Houston keeps its menubar item, but the main surface is
/// now a normal app window (sidebar + terminal), which is also what gets us a
/// real main menu — and therefore working ⌘C/⌘V inside the terminal.
@MainActor
enum MainWindowController {

    private static var controller: NSWindowController?

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
        window.setFrameAutosaveName("HoustonMainWindow")
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 460)

        let wc = NSWindowController(window: window)
        controller = wc

        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
