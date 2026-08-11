import AppKit

/// A SwiftPM executable gets no main menu for free, and without an Edit menu
/// the standard editing shortcuts are never dispatched — so ⌘C / ⌘V inside the
/// embedded terminal would silently do nothing. This installs the minimum menu
/// needed for a normal-feeling macOS app.
enum MainMenu {
    @MainActor
    static func install(into app: NSApplication) {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Houston",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Houston",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Houston",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit menu — the reason this file exists.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Shell menu — split commands target the focused pane of the visible
        // project (Ghostty's shortcuts).
        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        let splitRight = ClosureMenuItem("Split Right") {
            TerminalSessionManager.shared.split(vertical: true)
        }
        splitRight.keyEquivalent = "d"
        splitRight.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(splitRight)
        let splitDown = ClosureMenuItem("Split Down") {
            TerminalSessionManager.shared.split(vertical: false)
        }
        splitDown.keyEquivalent = "d"
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitDown)
        shellMenu.addItem(.separator())
        let closeSplit = ClosureMenuItem("Close Split") {
            TerminalSessionManager.shared.closeFocusedSplit()
        }
        closeSplit.keyEquivalent = "w"
        closeSplit.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(closeSplit)
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        app.mainMenu = main
        app.windowsMenu = windowMenu
    }
}
