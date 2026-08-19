import AppKit
import Foundation

extension Notification.Name {
    /// Settings changed by a path outside MainWindowView (the menu-bar
    /// Settings menu) — the window re-reads and applies.
    static let houstonSettingsChanged = Notification.Name("HoustonSettingsChanged")
    /// The menu bar asked for the Claude status-bar consent prompt.
    static let houstonShowStatusFeedPrompt = Notification.Name("HoustonShowStatusFeedPrompt")
    /// A macOS notification was clicked — select this project
    /// (`userInfo["path"]`).
    static let houstonOpenProject = Notification.Name("HoustonOpenProject")
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
    /// The first-launch welcome card has been dismissed.
    var welcomeSeen: Bool
    /// The sidebar is collapsed to the three-icon rail.
    var sidebarCollapsed: Bool

    static var defaults: HoustonSettings {
        HoustonSettings(
            projectsDirs: ["~/Apps".expandingTildePath],
            pinnedProjects: [],
            collapsedFolders: [],
            appearance: "system",
            terminalTheme: "",
            statusLinePromptDeclined: false,
            statusBarDisabled: false,
            statusBarCollapsed: false,
            statusBarHiddenItems: [],
            welcomeSeen: false,
            sidebarCollapsed: false
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
        if let seen = json["welcomeSeen"] as? Bool {
            s.welcomeSeen = seen
        }
        if let railed = json["sidebarCollapsed"] as? Bool {
            s.sidebarCollapsed = railed
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
        obj["statusLinePromptDeclined"] = s.statusLinePromptDeclined
        obj["statusBarDisabled"] = s.statusBarDisabled
        obj["statusBarCollapsed"] = s.statusBarCollapsed
        obj["statusBarHiddenItems"] = s.statusBarHiddenItems
        obj["welcomeSeen"] = s.welcomeSeen
        obj["sidebarCollapsed"] = s.sidebarCollapsed

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
