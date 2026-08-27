import Foundation

/// Accessibility facts captured when the user clicks a UI element in App
/// Inspector mode. AX-shaped, unlike `InspectedElement` which is
/// DOM-shaped. Strings and geometry only — no AX types leak out of the
/// capture code, so this crosses actor boundaries freely.
struct InspectedAXElement: Codable, Equatable, Sendable {
    struct Ancestor: Codable, Equatable, Sendable {
        let role: String
        let title: String?
        let identifier: String?
    }

    struct AppInfo: Codable, Equatable, Sendable {
        let name: String
        let bundleID: String?
        let bundlePath: String?
        let pid: pid_t
    }

    /// kAXRoleAttribute, e.g. "AXButton".
    let role: String
    let subrole: String?
    /// Human wording ("button") — kAXRoleDescriptionAttribute.
    let roleDescription: String?
    let title: String?
    /// Stringified and truncated to ~200 chars; never read for secure
    /// text fields.
    let value: String?
    let placeholder: String?
    let help: String?
    /// kAXIdentifierAttribute — the string most likely to appear verbatim
    /// in the app's source.
    let identifier: String?
    let enabled: Bool
    /// Global CG coordinates (top-left origin).
    let frame: CGRect
    let windowTitle: String?
    /// Innermost-first, capped at 8, stops at the window.
    let ancestors: [Ancestor]
    let app: AppInfo

    /// "button “Check for Updates…”" — the popover/prompt headline.
    var summary: String {
        var s = roleDescription ?? Self.deAX(role)
        if let snippet = title ?? value ?? placeholder, !snippet.isEmpty {
            let capped = snippet.count > 40 ? snippet.prefix(40) + "…" : snippet[...]
            s += " “\(capped)”"
        }
        return s
    }

    /// "AXButton" → "button".
    static func deAX(_ role: String) -> String {
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.isEmpty ? role : stripped.lowercased()
    }
}
