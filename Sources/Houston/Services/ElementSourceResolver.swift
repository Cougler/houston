import Foundation

/// Maps the URLs/paths `inspect.js` reports (script stack URLs, stylesheet
/// hrefs, framework dev-metadata file names) onto real files under the
/// project root, and composes the prompts sent to the project's terminal.
enum ElementSourceResolver {

    /// "http://localhost:5173/src/main.ts:10:20?t=123" → the file under
    /// `projectRoot`, or nil when it isn't a project file.
    static func resolve(_ raw: String?, projectRoot: String) -> ResolvedSource? {
        guard var path = raw?.trimmingCharacters(in: .whitespaces), !path.isEmpty else {
            return nil
        }

        // Peel a trailing :line(:col) — digits only, so ports (which sit
        // before the path, inside the origin) are never mistaken for lines.
        var line: Int?
        for _ in 0..<2 {
            if let colon = path.lastIndex(of: ":"),
               colon != path.startIndex,
               let n = Int(path[path.index(after: colon)...]) {
                line = n
                path = String(path[..<colon])
            }
        }

        // Strip query (Vite's ?t= cache-buster) and fragment.
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }

        // Strip an http(s)://host[:port] origin prefix.
        for scheme in ["http://", "https://"] where path.hasPrefix(scheme) {
            let rest = path.dropFirst(scheme.count)
            if let slash = rest.firstIndex(of: "/") {
                path = String(rest[slash...])
            } else {
                return nil // origin only, no path
            }
        }

        // Vite serves files outside its root as /@fs/<absolute path>.
        if path.hasPrefix("/@fs/") {
            path = String(path.dropFirst("/@fs".count))
        }

        // Dev-server plumbing, not project source.
        for noise in ["/@vite/", "/node_modules/", "/@react-refresh", "/@id/"] {
            if path.contains(noise) { return nil }
        }

        let root = (projectRoot as NSString).standardizingPath
        var candidates: [String] = []
        if (path as NSString).isAbsolutePath {
            candidates.append(path) // data-vite-dev-id / _debugSource absolutes
            candidates.append(root + path) // server-relative "/src/App.tsx"
            candidates.append(root + "/public" + path)
        } else {
            candidates.append(root + "/" + path)
        }

        let fm = FileManager.default
        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let relative = standardized.hasPrefix(root + "/")
                ? String(standardized.dropFirst(root.count + 1))
                : standardized
            return ResolvedSource(absolutePath: standardized, relativePath: relative, line: line)
        }
        return nil
    }

    /// Resolve everything a web capture reported against the project root:
    /// (structure, styles, script). The framework metadata's line number
    /// wins over anything peeled off the path.
    static func resolveSources(
        for element: InspectedElement, projectRoot: String
    ) -> (structure: ResolvedSource?, styles: [ResolvedSource], script: ResolvedSource?) {
        let structure = resolve(element.structure?.file, projectRoot: projectRoot)
            .map { resolved in
                ResolvedSource(
                    absolutePath: resolved.absolutePath,
                    relativePath: resolved.relativePath,
                    line: element.structure?.line ?? resolved.line
                )
            }
        var styles: [ResolvedSource] = []
        for match in element.styles where !match.inline {
            guard let resolved = resolve(match.source, projectRoot: projectRoot),
                  !styles.contains(resolved) else { continue }
            styles.append(resolved)
        }
        let script = element.scripts
            .compactMap { resolve($0.source, projectRoot: projectRoot) }
            .first
        return (structure, styles, script)
    }

    /// The one-shot prompt for the live "Send to Claude" flow. No trailing
    /// newline — the caller appends "\n" to submit.
    static func composePrompt(
        element: InspectedElement,
        structure: ResolvedSource?,
        styleFiles: [ResolvedSource],
        scriptFile: ResolvedSource?,
        instruction: String
    ) -> String {
        itemBody(
            element: element, structure: structure, styleFiles: styleFiles,
            scriptFile: scriptFile, instruction: instruction, includePage: true
        )
    }

    /// One numbered prompt covering every open annotation.
    static func composeBatchPrompt(
        items: [(element: InspectedElement, structure: ResolvedSource?,
                 styleFiles: [ResolvedSource], scriptFile: ResolvedSource?,
                 instruction: String)]
    ) -> String {
        guard !items.isEmpty else { return "" }
        let page = items[0].element.pageURL
        var lines = ["Make the following \(items.count) changes to the running app at \(page):"]
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). " + itemBody(
                element: item.element, structure: item.structure,
                styleFiles: item.styleFiles, scriptFile: item.scriptFile,
                instruction: item.instruction, includePage: false
            ))
        }
        return lines.joined(separator: "\n")
    }

    private static func itemBody(
        element: InspectedElement,
        structure: ResolvedSource?,
        styleFiles: [ResolvedSource],
        scriptFile: ResolvedSource?,
        instruction: String,
        includePage: Bool
    ) -> String {
        var context: [String] = []
        if let structure { context.append("defined at \(structure.display)") }
        if !styleFiles.isEmpty {
            let files = styleFiles.map(\.relativePath).uniqued().prefix(3)
            context.append("styled in \(files.joined(separator: ", "))")
        }
        if let scriptFile, scriptFile.relativePath != structure?.relativePath {
            context.append("handlers in \(scriptFile.relativePath)")
        }

        var s = includePage
            ? "In the running app at \(element.pageURL), the element "
            : "The element "
        s += "<\(element.summary)> (selector `\(element.selector)`)"
        if !context.isEmpty { s += " — " + context.joined(separator: ", ") }
        s += ": \(instruction)"
        if structure == nil {
            s += " The element's HTML is: `\(element.outerHTML)` — locate it in the codebase first."
        }
        return s
    }
}

private extension Sequence where Element: Hashable {
    /// Order-preserving dedupe.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
