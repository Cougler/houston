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

        // File menu — the sidebar footer's folder picker, from the keyboard.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openFolder = ClosureMenuItem("Open Folder…") {
            NotificationCenter.default.post(name: .houstonOpenFolder, object: nil)
        }
        openFolder.keyEquivalent = "o"
        openFolder.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(openFolder)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

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
        // project (Ghostty's shortcuts). Everything here goes through
        // notifications or the shared manager: the menu owns no state.
        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        let newTab = ClosureMenuItem("Duplicate Terminal") {
            NotificationCenter.default.post(name: .houstonNewTerminalTab, object: nil)
        }
        newTab.keyEquivalent = "d"
        newTab.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(newTab)
        // ⌘T does the same — hidden alias so browser-tab muscle memory works.
        let newTabAlias = ClosureMenuItem("New Terminal in Project") {
            NotificationCenter.default.post(name: .houstonNewTerminalTab, object: nil)
        }
        newTabAlias.keyEquivalent = "t"
        newTabAlias.keyEquivalentModifierMask = [.command]
        newTabAlias.isHidden = true
        newTabAlias.allowsKeyEquivalentWhenHidden = true
        shellMenu.addItem(newTabAlias)
        let launch = ClosureMenuItem("Launch Agent") {
            NotificationCenter.default.post(name: .houstonLaunchAgent, object: nil)
        }
        launch.keyEquivalent = "\r"
        launch.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(launch)
        let clear = ClosureMenuItem("Clear Terminal") {
            TerminalSessionManager.shared.clearFocused()
        }
        clear.keyEquivalent = "k"
        clear.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(clear)
        let rename = ClosureMenuItem("Rename Terminal…") {
            NotificationCenter.default.post(name: .houstonRenameTerminal, object: nil)
        }
        rename.keyEquivalent = "r"
        rename.keyEquivalentModifierMask = [.command]
        shellMenu.addItem(rename)
        shellMenu.addItem(.separator())
        // ⌘D moved to Duplicate Terminal (2026-09-04) — splits keep the
        // Ghostty-style D mnemonic behind ⌥.
        let splitRight = ClosureMenuItem("Split Right") {
            TerminalSessionManager.shared.split(vertical: true)
        }
        splitRight.keyEquivalent = "d"
        splitRight.keyEquivalentModifierMask = [.command, .option]
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
        shellMenu.addItem(.separator())
        let nextTerminal = ClosureMenuItem("Next Terminal") {
            NotificationCenter.default.post(
                name: .houstonCycleTerminal, object: nil, userInfo: ["delta": 1]
            )
        }
        nextTerminal.keyEquivalent = String(
            Character(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        nextTerminal.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(nextTerminal)
        let prevTerminal = ClosureMenuItem("Previous Terminal") {
            NotificationCenter.default.post(
                name: .houstonCycleTerminal, object: nil, userInfo: ["delta": -1]
            )
        }
        prevTerminal.keyEquivalent = String(
            Character(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        prevTerminal.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(prevTerminal)
        // ⌘1–⌘9 jump straight to the Nth terminal row. Hidden — nine list
        // items would drown the menu — but hidden items only fire their key
        // equivalents with the explicit opt-in flag.
        for n in 1...9 {
            let jump = ClosureMenuItem("Terminal \(n)") {
                NotificationCenter.default.post(
                    name: .houstonSelectTerminalIndex, object: nil,
                    userInfo: ["index": n - 1]
                )
            }
            jump.keyEquivalent = String(n)
            jump.keyEquivalentModifierMask = [.command]
            jump.isHidden = true
            jump.allowsKeyEquivalentWhenHidden = true
            shellMenu.addItem(jump)
        }
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        // View menu — sidebar + the right sheet, from the keyboard.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebar = ClosureMenuItem("Toggle Sidebar") {
            NotificationCenter.default.post(name: .houstonToggleSidebar, object: nil)
        }
        toggleSidebar.keyEquivalent = "b"
        toggleSidebar.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(toggleSidebar)
        let gitSheet = ClosureMenuItem("Git") {
            NotificationCenter.default.post(name: .houstonToggleGitPanel, object: nil)
        }
        gitSheet.keyEquivalent = "g"
        gitSheet.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(gitSheet)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

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

        // Houston + recent picks only — the full ~485-theme catalog ran past
        // the screen as a submenu. The searchable picker lives in the window.
        let theme = NSMenu(title: "Terminal Theme")
        let houston = ClosureMenuItem("Houston") { Self.update { $0.terminalTheme = "" } }
        houston.state = s.terminalTheme.isEmpty ? .on : .off
        theme.addItem(houston)
        let recents = s.recentTerminalThemes
            .filter { GhosttyThemeCatalog.theme(named: $0) != nil }
        if !recents.isEmpty {
            theme.addItem(.separator())
            for name in recents {
                let item = ClosureMenuItem(name) {
                    Self.update { s in
                        s.terminalTheme = name
                        var r = s.recentTerminalThemes.filter { $0 != name }
                        r.insert(name, at: 0)
                        s.recentTerminalThemes = Array(r.prefix(10))
                    }
                }
                item.state = s.terminalTheme == name ? .on : .off
                theme.addItem(item)
            }
        }
        theme.addItem(.separator())
        theme.addItem(ClosureMenuItem("All Themes…") {
            NotificationCenter.default.post(name: .houstonShowThemePicker, object: nil)
        })
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
