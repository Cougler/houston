import AppKit
import GhosttyTheme

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
        appMenu.addItem(ClosureMenuItem("Check for Updates…") {
            UpdateChecker.shared.checkInteractively()
        })
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

        // Settings menu — the footer gear's options, reachable from the menu
        // bar. Rebuilt on every open so it always reflects the settings file.
        let settingsItem = NSMenuItem()
        let settingsMenu = NSMenu(title: "Settings")
        settingsMenu.delegate = SettingsMenuBuilder.shared
        settingsItem.submenu = settingsMenu
        main.addItem(settingsItem)

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

/// Builds the menu-bar Settings menu fresh each time it opens, straight from
/// the settings file — no state to fall out of sync. Mutations write the file
/// and post `.houstonSettingsChanged`; the window re-reads and applies.
@MainActor
final class SettingsMenuBuilder: NSObject, NSMenuDelegate {
    static let shared = SettingsMenuBuilder()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = HoustonSettings.read()

        let appearance = NSMenu(title: "Appearance")
        for (label, tag) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let item = ClosureMenuItem(label) {
                Self.update { $0.appearance = tag }
                NSApp.appearance = HoustonSettings.read().nsAppearance
            }
            item.state = s.appearance == tag ? .on : .off
            appearance.addItem(item)
        }
        menu.addItem(submenu: appearance)

        let theme = NSMenu(title: "Terminal Theme")
        let houston = ClosureMenuItem("Houston") { Self.update { $0.terminalTheme = "" } }
        houston.state = s.terminalTheme.isEmpty ? .on : .off
        theme.addItem(houston)
        theme.addItem(.separator())
        for definition in GhosttyThemeCatalog.allThemes {
            let item = ClosureMenuItem(definition.name) {
                Self.update { $0.terminalTheme = definition.name }
            }
            item.state = s.terminalTheme == definition.name ? .on : .off
            theme.addItem(item)
        }
        menu.addItem(submenu: theme)

        let bar = NSMenu(title: "Status Bar")
        let hide = ClosureMenuItem("Hide") {
            Self.update { $0.statusBarCollapsed.toggle() }
        }
        hide.state = s.statusBarCollapsed ? .on : .off
        bar.addItem(hide)
        let disable = ClosureMenuItem("Disable") {
            Self.update { $0.statusBarDisabled.toggle() }
        }
        disable.state = s.statusBarDisabled ? .on : .off
        bar.addItem(disable)
        bar.addItem(.separator())
        for (label, key) in [
            ("Model", "model"), ("Context", "context"), ("MCP", "mcp"),
            ("Peak Hours", "peak"), ("Rate Limits", "limits"),
        ] {
            let item = ClosureMenuItem(label) {
                Self.update {
                    if $0.statusBarHiddenItems.contains(key) {
                        $0.statusBarHiddenItems.removeAll { $0 == key }
                    } else {
                        $0.statusBarHiddenItems.append(key)
                    }
                }
            }
            item.state = s.statusBarHiddenItems.contains(key) ? .off : .on
            bar.addItem(item)
        }
        menu.addItem(submenu: bar)

        menu.addItem(.separator())
        if StatusLineFeed.state == .houston {
            menu.addItem(ClosureMenuItem("Disable Claude Status Bar") {
                StatusLineFeed.restore()
                NotificationCenter.default.post(name: .houstonSettingsChanged, object: nil)
            })
        } else {
            menu.addItem(ClosureMenuItem("Enable Claude Status Bar…") {
                NotificationCenter.default.post(
                    name: .houstonShowStatusFeedPrompt, object: nil
                )
            })
        }
    }

    private static func update(_ mutate: (inout HoustonSettings) -> Void) {
        var s = HoustonSettings.read()
        mutate(&s)
        HoustonSettings.write(s)
        NotificationCenter.default.post(name: .houstonSettingsChanged, object: nil)
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem()
        item.title = submenu.title
        item.submenu = submenu
        addItem(item)
    }
}
