import Foundation

/// The payload `inspect.js` posts when the user clicks an element in
/// inspect mode. Everything beyond the selector is best-effort — the page
/// is hostile territory, so every field the JS can't compute arrives
/// null/empty rather than not at all.
struct InspectedElement: Codable, Equatable, Sendable {
    let tagName: String
    let elementID: String?
    let classes: [String]
    /// Computed unique-ish CSS selector — also the anchor for annotation pins.
    let selector: String
    /// Capped ~1KB by the JS.
    let outerHTML: String
    /// textContent snippet, capped ~200 chars.
    let text: String?
    let rect: Rect
    /// Where the element's markup lives, when a framework's dev metadata
    /// says (React ≤18 `_debugSource`, Vue `__file`, Svelte `__svelte_meta`).
    let structure: StructureSource?
    /// Stylesheet rules matching the element, capped at 30.
    let styles: [StyleMatch]
    /// Event handlers the JS could attribute (patched addEventListener,
    /// inline `on*` attributes, React fiber props).
    let scripts: [ScriptHandler]
    let pageURL: String

    enum CodingKeys: String, CodingKey {
        case tagName, classes, selector, outerHTML, text, rect
        case structure, styles, scripts, pageURL
        case elementID = "id"
    }

    struct Rect: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct StructureSource: Codable, Equatable, Sendable {
        let file: String
        let line: Int?
        let column: Int?
        /// "react" | "vue" | "svelte".
        let framework: String
    }

    struct StyleMatch: Codable, Equatable, Sendable {
        let selector: String
        /// Stylesheet href, Vite's `data-vite-dev-id` (an absolute file
        /// path), or "inline <style>".
        let source: String
        /// True for the element's own `style` attribute.
        let inline: Bool
    }

    struct ScriptHandler: Codable, Equatable, Sendable {
        /// Event name — "click", or a React prop name like "onClick".
        let type: String
        /// Script URL (with :line:col) that registered the handler, when
        /// the stack said.
        let source: String?
        /// The handler function's name, when it has one.
        let name: String?
        /// "listener" | "inline" | "reactProp".
        let origin: String
    }

    /// "button#submit.cta.primary" — the panel/annotation headline.
    var summary: String {
        var s = tagName.lowercased()
        if let id = elementID, !id.isEmpty { s += "#\(id)" }
        for cls in classes.prefix(3) { s += ".\(cls)" }
        if classes.count > 3 { s += "…" }
        return s
    }
}

/// A source reference resolved to a real file under the project root.
struct ResolvedSource: Equatable, Sendable {
    let absolutePath: String
    /// Relative to the project root — what the UI shows and prompts cite.
    let relativePath: String
    let line: Int?

    var display: String {
        line.map { "\(relativePath):\($0)" } ?? relativePath
    }
}
