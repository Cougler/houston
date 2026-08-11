import AppKit
import Foundation

/// Houston's settings. Unknown keys in the JSON are preserved on write.
struct HoustonSettings {
    /// Parent folders whose subdirectories are the sidebar's projects.
    var projectsDirs: [String]
    /// Project folders currently collapsed in the sidebar.
    var collapsedFolders: [String]
    /// "system" | "light" | "dark".
    var appearance: String
    /// A ghostty theme name for the terminal, or "" for Houston's default
    /// (design-matched light/dark).
    var terminalTheme: String

    static var defaults: HoustonSettings {
        HoustonSettings(
            projectsDirs: ["~/Apps".expandingTildePath],
            collapsedFolders: [],
            appearance: "system",
            terminalTheme: ""
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
        // string as the migration fallback.
        let candidates = (json["projectsDirs"] as? [String])
            ?? (json["projectsDir"] as? String).map { [$0] }
            ?? []
        let dirs = candidates
            .map(\.expandingTildePath)
            .filter { ($0 as NSString).isAbsolutePath }
        if !dirs.isEmpty { s.projectsDirs = dirs }
        if let collapsed = json["collapsedFolders"] as? [String] {
            s.collapsedFolders = collapsed
        }
        if let a = json["appearance"] as? String, ["system", "light", "dark"].contains(a) {
            s.appearance = a
        }
        if let t = json["terminalTheme"] as? String {
            s.terminalTheme = t
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
        obj["collapsedFolders"] = s.collapsedFolders
        obj["appearance"] = s.appearance
        obj["terminalTheme"] = s.terminalTheme

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
