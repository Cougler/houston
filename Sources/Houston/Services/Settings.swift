import AppKit
import Foundation

extension Notification.Name {
    /// Settings changed by a path outside MainWindowView (the menu-bar
    /// Settings menu) — the window re-reads and applies.
    static let houstonSettingsChanged = Notification.Name("HoustonSettingsChanged")
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
}

/// Houston's settings. Unknown keys in the JSON are preserved on write.
struct HoustonSettings {
    /// Parent folders whose subdirectories are the sidebar's projects.
    var projectsDirs: [String]
    /// Individual project folders added directly — shown as their own rows,
    /// never expanded into their subdirectories.
    var pinnedProjects: [String]
    /// Project folders currently collapsed in the sidebar.
    var collapsedFolders: [String]
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

    static var defaults: HoustonSettings {
        HoustonSettings(
            projectsDirs: ["~/Apps".expandingTildePath],
            pinnedProjects: [],
            collapsedFolders: [],
            appearance: "system",
            terminalTheme: "",
            recentTerminalThemes: [],
            statusLinePromptDeclined: false,
            statusBarDisabled: false,
            statusBarCollapsed: false,
            statusBarHiddenItems: [],
            onboardingSeen: false,
            sharingDisabled: false,
            relayToken: "",
            relayEnabled: [],
            relayPins: [:],
            sidebarCollapsed: false,
            sidebarWidth: Double(Theme.sidebarWidth),
            windowFrame: [],
            previewWindowFrame: [],
            recentServers: []
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

    static func read() -> HoustonSettings {
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
        if let collapsed = json["collapsedFolders"] as? [String] {
            s.collapsedFolders = collapsed
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
            s.relayPins = pins
        }
        if let railed = json["sidebarCollapsed"] as? Bool {
            s.sidebarCollapsed = railed
        }
        // Bounds mirror MainWindowView.sidebarRange — a corrupt value must
        // not restore an unusable sidebar.
        if let w = json["sidebarWidth"] as? Double, (180...420).contains(w) {
            s.sidebarWidth = w
        }
        if let f = json["windowFrame"] as? [Double], f.count == 4,
           f[2] >= 400, f[3] >= 300 {
            s.windowFrame = f
        }
        if let f = json["previewWindowFrame"] as? [Double], f.count == 4,
           f[2] >= 500, f[3] >= 400 {
            s.previewWindowFrame = f
        }
        if let recents = json["recentServers"] as? [[String: String]] {
            s.recentServers = recents
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
        obj["collapsedFolders"] = s.collapsedFolders
        obj["appearance"] = s.appearance
        obj["terminalTheme"] = s.terminalTheme
        obj["recentTerminalThemes"] = s.recentTerminalThemes
        obj["statusLinePromptDeclined"] = s.statusLinePromptDeclined
        obj["statusBarDisabled"] = s.statusBarDisabled
        obj["statusBarCollapsed"] = s.statusBarCollapsed
        obj["statusBarHiddenItems"] = s.statusBarHiddenItems
        obj["onboardingSeen"] = s.onboardingSeen
        obj["sharingDisabled"] = s.sharingDisabled
        obj["relayToken"] = s.relayToken
        obj["relayEnabled"] = s.relayEnabled
        obj["relayPins"] = s.relayPins
        obj["sidebarCollapsed"] = s.sidebarCollapsed
        obj["sidebarWidth"] = s.sidebarWidth
        obj["windowFrame"] = s.windowFrame
        obj["previewWindowFrame"] = s.previewWindowFrame
        obj["recentServers"] = s.recentServers

        let dir = ("~/Library/Application Support/Houston" as String).expandingTildePath
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }
}
