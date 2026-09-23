import AppKit
import Foundation

extension Notification.Name {
    /// Settings changed by a path outside MainWindowView (the menu-bar
    /// Settings menu) — the window re-reads and applies.
    static let houstonSettingsChanged = Notification.Name("HoustonSettingsChanged")
    /// Run a CLI login flow (e.g. `claude /login`) in a home-directory
    /// terminal pane — posted by ProviderAuthStore, handled by the window.
    static let houstonRunLoginCommand = Notification.Name("HoustonRunLoginCommand")
    /// The menu bar asked for the Claude status-bar consent prompt.
    static let houstonShowStatusFeedPrompt = Notification.Name("HoustonShowStatusFeedPrompt")
    /// The menu bar's "All Themes…" asked for the searchable theme picker,
    /// which lives on the window's footer gear.
    static let houstonShowThemePicker = Notification.Name("HoustonShowThemePicker")
    /// A macOS notification was clicked — select this project
    /// (`userInfo["path"]`).
    static let houstonOpenProject = Notification.Name("HoustonOpenProject")
    /// A left click landed in a terminal pane. The ghostty view consumes
    /// clicks before SwiftUI sees them, so dismissing the floating right
    /// sheet on terminal clicks needs this side channel.
    static let houstonTerminalClicked = Notification.Name("HoustonTerminalClicked")

    // Keyboard shortcuts (MainMenu) → the window, which owns the selection
    // these act on.
    /// ⌘T — a new terminal tab in the selected project's directory.
    static let houstonNewTerminalTab = Notification.Name("HoustonNewTerminalTab")
    /// ⌘⌥↑ / ⌘⌥↓ — step through the open terminals (`userInfo["delta"]`).
    static let houstonCycleTerminal = Notification.Name("HoustonCycleTerminal")
    /// ⌘1–⌘9 — jump straight to the Nth terminal (`userInfo["index"]`, 0-based).
    static let houstonSelectTerminalIndex = Notification.Name("HoustonSelectTerminalIndex")
    /// ⌘B — collapse/expand the sidebar.
    static let houstonToggleSidebar = Notification.Name("HoustonToggleSidebar")
    /// ⌘G — the Git sheet.
    static let houstonToggleGitPanel = Notification.Name("HoustonToggleGitPanel")
    /// ⌘↩ — launch the header's selected agent in the current project.
    static let houstonLaunchAgent = Notification.Name("HoustonLaunchAgent")
    /// ⌘O — the sidebar footer's "Open Folder…" picker.
    static let houstonOpenFolder = Notification.Name("HoustonOpenFolder")
    /// ⌘R — rename the selected terminal's sidebar row.
    static let houstonRenameTerminal = Notification.Name("HoustonRenameTerminal")
}

/// Houston's settings. Unknown keys in the JSON are preserved on write.
struct HoustonSettings {
    /// Parent folders whose subdirectories are the sidebar's projects.
    var projectsDirs: [String]
    /// Individual project folders added directly — shown as their own rows,
    /// never expanded into their subdirectories.
    var pinnedProjects: [String]
    /// "system" | "light" | "dark".
    var appearance: String
    /// A ghostty theme name for the terminal, or "" for Houston's default
    /// (design-matched light/dark).
    var terminalTheme: String
    /// Catalog themes most recently picked, newest first, capped at 10 —
    /// the theme picker's Recents section.
    var recentTerminalThemes: [String]
    /// The user said "Not Now" to the status-bar offer — never re-prompt;
    /// enabling stays available from the footer gear.
    var statusLinePromptDeclined: Bool
    /// The status bar is turned off entirely.
    var statusBarDisabled: Bool
    /// The status bar is collapsed to just the model.
    var statusBarCollapsed: Bool
    /// Status-bar items switched off individually. Known keys:
    /// "model", "context", "mcp", "peak", "limits".
    var statusBarHiddenItems: [String]
    /// The first-launch onboarding has been dismissed (replayable from the
    /// footer gear). A fresh key on purpose — existing installs see the
    /// paginated onboarding once, even if they saw the old welcome card.
    var onboardingSeen: Bool
    /// The capsule-view explainer was suppressed via its "don't show
    /// this again" checkbox.
    var capsuleHintDismissed: Bool
    /// The share proxy (`<project>.localhost` / `<project>.local`) is
    /// switched off. Stored inverted so the default JSON absence means on.
    var sharingDisabled: Bool
    /// Houston Pro token for the public share relay (gohouston.live).
    /// Empty = no entitlement; the web-share UI shows its locked state.
    var relayToken: String
    /// Project labels (ShareProxyStore.label form) with "Share to the web"
    /// switched on.
    var relayEnabled: [String]
    /// Optional 4-digit viewer code per project label ("" or absent = no
    /// code). Rides the tunnel handshake; the relay enforces it.
    var relayPins: [String: String]
    /// The sidebar is collapsed to the three-icon rail.
    var sidebarCollapsed: Bool
    /// Expanded sidebar width in points (user-dragged).
    var sidebarWidth: Double
    /// Right sheet (Git/Capsules/etc.) width in points (user-dragged).
    var rightSheetWidth: Double
    /// The right sheet's last pin choice — a sheet opens pinned (docked)
    /// or floating based on how the user last left it.
    var rightPanelDocked: Bool
    /// The project (chats) panel collapse — it docks always, and this
    /// remembers whether the user last had it tucked away.
    var chatsPanelCollapsed: Bool = false
    /// Which workspace items live in the side panel (the rest ride the
    /// top bar as chips). Empty = no panel at all.
    var workspacePanelItems: [String] = ["terminals", "chats"]
    /// Last window frame as [x, y, w, h]; empty until first saved. Lives
    /// here (not just NSWindow frame autosave) because settings.json is the
    /// store that survives updates AND is shared by debug and packaged
    /// builds — UserDefaults domains differ between the two.
    var windowFrame: [Double]
    /// Last web-preview window frame as [x, y, w, h]; one shared frame for
    /// all preview windows (last moved wins), same rationale as
    /// `windowFrame`.
    var previewWindowFrame: [Double]
    /// Stopped dev servers kept as gray sidebar rows, keyed by project path.
    /// String-valued dicts ("path", "name", "port") so the JSON round-trips
    /// through the same reader/writer as everything else.
    var recentServers: [[String: String]]
    /// Chat bubble fill for the user's side, "RRGGBB"; "" = brand default.
    var chatBubbleColor: String
    /// Chat text color inside the user bubble, "RRGGBB"; "" = white.
    var chatTextColor: String
    /// Project paths that have ever hosted a dev server Houston attributed.
    /// Detection treats these like pinned projects, so a server keeps its
    /// sidebar row even when its project is no longer pinned or under a
    /// `projectsDirs` folder — the recents list alone can't carry this,
    /// because a recent is deleted the moment its server comes back up.
    var knownServerPaths: [String]

    static var defaults: HoustonSettings {
        HoustonSettings(
            // Empty, deliberately: folder groups are gone (2026-09-09) and
            // a ~/Apps default made every fresh install auto-pin the
            // user's whole Apps folder as a "project" via the migration.
            projectsDirs: [],
            pinnedProjects: [],
            appearance: "system",
            terminalTheme: "",
            recentTerminalThemes: [],
            statusLinePromptDeclined: false,
            statusBarDisabled: false,
            statusBarCollapsed: false,
            statusBarHiddenItems: [],
            onboardingSeen: false,
            capsuleHintDismissed: false,
            sharingDisabled: false,
            relayToken: "",
            relayEnabled: [],
            relayPins: [:],
            sidebarCollapsed: false,
            sidebarWidth: Double(Theme.sidebarWidth),
            rightSheetWidth: 364,
            rightPanelDocked: false,
            windowFrame: [],
            previewWindowFrame: [],
            recentServers: [],
            chatBubbleColor: "",
            chatTextColor: "",
            knownServerPaths: []
        )
    }

    /// The `NSApp.appearance` override for this setting — nil follows the
    /// system.
    var nsAppearance: NSAppearance? {
        switch appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    static var fileURL: URL {
        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
    }

    /// Parsed-settings cache behind the file's mtime. `read()` runs on 4s
    /// and 5s store timers and ~10× per MainWindowView init, all on the
    /// main thread — a stat is microseconds, the read+parse it replaces
    /// is not. Guarded: `read()`/`write()` are called from the main
    /// thread and detached store tasks alike.
    nonisolated(unsafe) private static var cached: (mtime: Date, value: HoustonSettings)?
    private static let cacheLock = NSLock()

    static func read() -> HoustonSettings {
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        cacheLock.lock()
        if let cached, cached.mtime == mtime ?? .distantPast {
            let hit = cached.value
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        let value = parse()
        cacheLock.lock()
        cached = (mtime ?? .distantPast, value)
        cacheLock.unlock()
        return value
    }

    private static func parse() -> HoustonSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaults
        }
        var s = defaults
        // "projectsDirs" (array) with the pre-multi-folder "projectsDir"
        // string as the migration fallback. An empty array is an explicit
        // choice and must stick — falling back to the default here meant
        // removing the last folder silently resurrected ~/Apps.
        if let candidates = (json["projectsDirs"] as? [String])
            ?? (json["projectsDir"] as? String).map({ [$0] }) {
            s.projectsDirs = candidates
                .map(\.expandingTildePath)
                .filter { ($0 as NSString).isAbsolutePath }
        }
        if let pinned = json["pinnedProjects"] as? [String] {
            s.pinnedProjects = pinned
                .map(\.expandingTildePath)
                .filter { ($0 as NSString).isAbsolutePath }
        }
        if let a = json["appearance"] as? String, ["system", "light", "dark"].contains(a) {
            s.appearance = a
        }
        if let t = json["terminalTheme"] as? String {
            s.terminalTheme = t
        }
        if let recents = json["recentTerminalThemes"] as? [String] {
            s.recentTerminalThemes = Array(recents.prefix(10))
        }
        if let declined = json["statusLinePromptDeclined"] as? Bool {
            s.statusLinePromptDeclined = declined
        }
        if let disabled = json["statusBarDisabled"] as? Bool {
            s.statusBarDisabled = disabled
        }
        if let barCollapsed = json["statusBarCollapsed"] as? Bool {
            s.statusBarCollapsed = barCollapsed
        }
        if let hidden = json["statusBarHiddenItems"] as? [String] {
            s.statusBarHiddenItems = hidden
        }
        if let seen = json["onboardingSeen"] as? Bool {
            s.onboardingSeen = seen
        }
        if let dismissed = json["capsuleHintDismissed"] as? Bool {
            s.capsuleHintDismissed = dismissed
        }
        if let off = json["sharingDisabled"] as? Bool {
            s.sharingDisabled = off
        }
        if let tok = json["relayToken"] as? String {
            s.relayToken = tok
        }
        if let enabled = json["relayEnabled"] as? [String] {
            s.relayEnabled = enabled
        }
        if let pins = json["relayPins"] as? [String: String] {
            // Digits only, mirroring setPin — a hand-edited pin with
            // CR/LF would otherwise split the relay handshake request.
            s.relayPins = pins.filter {
                !$0.value.isEmpty && $0.value.count <= 8
                    && $0.value.allSatisfy(\.isNumber)
            }
        }
        if let railed = json["sidebarCollapsed"] as? Bool {
            s.sidebarCollapsed = railed
        }
        // Bounds mirror MainWindowView.sidebarRange — a corrupt value must
        // not restore an unusable sidebar.
        if let w = json["sidebarWidth"] as? Double, (180...420).contains(w) {
            s.sidebarWidth = w
        }
        // Bounds mirror MainWindowView.rightSheetRange.
        if let w = json["rightSheetWidth"] as? Double, (300...600).contains(w) {
            s.rightSheetWidth = w
        }
        if let docked = json["rightPanelDocked"] as? Bool {
            s.rightPanelDocked = docked
        }
        if let collapsed = json["chatsPanelCollapsed"] as? Bool {
            s.chatsPanelCollapsed = collapsed
        }
        if let items = json["workspacePanelItems"] as? [String] {
            s.workspacePanelItems = items
        }
        if let f = json["windowFrame"] as? [Double], f.count == 4,
           f[2] >= 400, f[3] >= 300 {
            s.windowFrame = f
        }
        if let f = json["previewWindowFrame"] as? [Double], f.count == 4,
           f[2] >= 500, f[3] >= 400 {
            s.previewWindowFrame = f
        }
        if let bubble = json["chatBubbleColor"] as? String {
            s.chatBubbleColor = bubble
        }
        if let text = json["chatTextColor"] as? String {
            s.chatTextColor = text
        }
        if let recents = json["recentServers"] as? [[String: String]] {
            s.recentServers = recents
        }
        if let known = json["knownServerPaths"] as? [String] {
            s.knownServerPaths = known
        }
        return s
    }

    @discardableResult
    static func write(_ s: HoustonSettings) -> Bool {
        var obj: [String: Any] = {
            if let data = try? Data(contentsOf: fileURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return existing
            }
            return [:]
        }()
        obj["projectsDirs"] = s.projectsDirs
        obj["pinnedProjects"] = s.pinnedProjects
        obj["appearance"] = s.appearance
        obj["terminalTheme"] = s.terminalTheme
        obj["recentTerminalThemes"] = s.recentTerminalThemes
        obj["statusLinePromptDeclined"] = s.statusLinePromptDeclined
        obj["statusBarDisabled"] = s.statusBarDisabled
        obj["statusBarCollapsed"] = s.statusBarCollapsed
        obj["statusBarHiddenItems"] = s.statusBarHiddenItems
        obj["onboardingSeen"] = s.onboardingSeen
        obj["capsuleHintDismissed"] = s.capsuleHintDismissed
        obj["sharingDisabled"] = s.sharingDisabled
        obj["relayToken"] = s.relayToken
        obj["relayEnabled"] = s.relayEnabled
        obj["relayPins"] = s.relayPins
        obj["sidebarCollapsed"] = s.sidebarCollapsed
        obj["sidebarWidth"] = s.sidebarWidth
        obj["rightSheetWidth"] = s.rightSheetWidth
        obj["rightPanelDocked"] = s.rightPanelDocked
        obj["chatsPanelCollapsed"] = s.chatsPanelCollapsed
        obj["workspacePanelItems"] = s.workspacePanelItems
        obj["windowFrame"] = s.windowFrame
        obj["previewWindowFrame"] = s.previewWindowFrame
        obj["chatBubbleColor"] = s.chatBubbleColor
        obj["chatTextColor"] = s.chatTextColor
        obj["recentServers"] = s.recentServers
        obj["knownServerPaths"] = s.knownServerPaths

        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return false
        }
        // The relay bearer token lives here — keep the file user-only.
        try? fm.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
        cacheLock.lock()
        cached = nil
        cacheLock.unlock()
        return true
    }
}
