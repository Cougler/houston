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
    /// The window's one field editor — every NSTextField-backed SwiftUI
    /// `TextField` (the chat composer included) edits through it. Created
    /// lazily on the main thread the first time a field asks.
    private var fieldEditor: NoDropFieldEditor?

    /// Covers AppKit-native fields only. SwiftUI's `TextField` (the chat
    /// composer) ignores this and edits through its OWN
    /// `_SystemTextFieldFieldEditor` — see `windowDidUpdate`.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let fieldEditor { return fieldEditor }
        let editor = NoDropFieldEditor()
        editor.isFieldEditor = true
        fieldEditor = editor
        return editor
    }

    /// An image dropped on the focused composer was swallowed: AppKit's
    /// field editor accepts file drags and inserts the raw path as text,
    /// so the window-wide image drop never saw it. The delegate hook above
    /// can't stop that for a SwiftUI `TextField` — probed 2026-10-01 (macOS
    /// 26): the first responder is SwiftUI's private
    /// `_SystemTextFieldFieldEditor`, registered for 19 drag types, and
    /// the delegate's editor is never used (that hook had been dead since
    /// it was written). The editor is shared by every field in the window
    /// and created lazily, so it's patched the first time it shows up as
    /// first responder.
    func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else { return }
        FieldEditorDropGuard.apply(to: editor)
    }

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

/// Makes a live field editor refuse every drag, so a drop over a focused
/// text field falls through to the SwiftUI `.onDrop` beneath (the
/// composer's text drop, then the root's window-wide image drop).
/// The editor is SwiftUI's private class, so it can't be subclassed
/// statically: a runtime subclass overrides the two registration hooks
/// (`acceptableDragTypes` is what NSTextView registers,
/// `updateDragTypeRegistration` re-runs on every container change, so
/// overriding one alone gets undone) and the instance is re-classed in
/// place. Verified in a standalone probe to stay at zero drag types
/// through typing, selection changes and re-registration.
@MainActor
private enum FieldEditorDropGuard {
    private static var subclasses: [String: AnyClass] = [:]
    private static let suffix = "_HoustonNoDrop"

    static func apply(to editor: NSTextView) {
        // object_getClass, not type(of:): KVO may have put its own
        // subclass in the way and that one must stay the instance's class.
        guard let base = object_getClass(editor) else { return }
        let baseName = String(cString: class_getName(base))
        if baseName.hasSuffix(suffix) { return }
        let cls: AnyClass
        if let known = subclasses[baseName] {
            cls = known
        } else {
            guard let made = objc_allocateClassPair(base, baseName + suffix, 0)
            else { return }
            let acceptable: @convention(block) (AnyObject) -> NSArray = { _ in NSArray() }
            class_addMethod(
                made, #selector(getter: NSTextView.acceptableDragTypes),
                imp_implementationWithBlock(acceptable), "@@:"
            )
            let update: @convention(block) (NSTextView) -> Void = {
                $0.unregisterDraggedTypes()
            }
            class_addMethod(
                made, #selector(NSTextView.updateDragTypeRegistration),
                imp_implementationWithBlock(update), "v@:"
            )
            objc_registerClassPair(made)
            subclasses[baseName] = made
            cls = made
        }
        object_setClass(editor, cls)
        editor.unregisterDraggedTypes()
    }
}

/// A field editor that is never a drag destination — see
/// `WindowFrameSaver.windowWillReturnFieldEditor`. Both hooks are
/// overridden: `acceptableDragTypes` is what NSTextView registers, and
/// `updateDragTypeRegistration` is re-run on every text-container change,
/// so an override of the first alone could be undone by the second.
private final class NoDropFieldEditor: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }
}
