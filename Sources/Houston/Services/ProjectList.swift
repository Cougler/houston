import AppKit
import Foundation

/// `ProjectList.isProject` stats up to a handful of marker files, and the
/// sidebar re-derives row keys on every 2s tick — cache the verdict per path.
@MainActor
enum ProjectKindCache {
    private static var cache: [String: Bool] = [:]

    static func isProject(_ path: String) -> Bool {
        if let hit = cache[path] { return hit }
        let result = ProjectList.isProject(path)
        cache[path] = result
        return result
    }
}

/// A project's own logo for its sidebar row, found at the well-known spots
/// (app icons, web favicons). The verdict — image or "none" — is cached per
/// path for the app's lifetime; rows render it synchronously.
@MainActor
enum ProjectLogoCache {
    private static var cache: [String: NSImage?] = [:]

    /// Checked in order; the first that loads wins. Favicons first — a
    /// square mark reads at 14pt where a wordmark logo doesn't — with app
    /// icons as the fallback for native projects that have no favicon.
    private static let candidates = [
        "public/favicon.png", "public/favicon.ico", "public/favicon.svg",
        "app/favicon.ico", "src/app/favicon.ico",
        "static/favicon.png", "favicon.png", "favicon.ico", "favicon.svg",
        "public/apple-touch-icon.png",
        "AppIcon.png", "app-icon.png", "icon.png",
        "app/icon.png", "src/app/icon.png",
        "assets/icon.png", "public/icon.png",
        // Last resort for projects that ship only a logo (no favicon).
        "public/logo.svg", "public/logo.png", "assets/logo.png",
        "static/logo.png", "logo.svg", "logo.png",
    ]

    static func logo(for path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        // Swift-package apps keep their icon in the resource bundle
        // (Houston: Sources/Houston/Resources/icons/AppIcon.png).
        let name = (path as NSString).lastPathComponent.capitalized
        let all = candidates + [
            "Sources/\(name)/Resources/icons/AppIcon.png",
            "Sources/\(name)/Resources/AppIcon.png",
        ]
        var found: NSImage?
        for candidate in all {
            let full = (path as NSString).appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: full),
                  let image = NSImage(contentsOfFile: full),
                  image.isValid else { continue }
            // A dark monochrome glyph vanishes on the dark sidebar — mark
            // it template so it tints with the appearance (white in dark).
            if isDarkMonochrome(image) { image.isTemplate = true }
            found = image
            break
        }
        cache[path] = found
        return found
    }

    /// True when the icon is a dark glyph on transparency: mostly dark
    /// opaque pixels with real transparent coverage (a solid dark square
    /// would tint into a slab, so full-bleed images never qualify).
    private static func isDarkMonochrome(_ image: NSImage) -> Bool {
        let side = 16
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var opaque = 0, dark = 0
        for i in 0..<(side * side) {
            let alpha = Int(pixels[i * 4 + 3])
            guard alpha > 40 else { continue }
            opaque += 1
            let r = Int(pixels[i * 4]) * 255 / alpha
            let g = Int(pixels[i * 4 + 1]) * 255 / alpha
            let b = Int(pixels[i * 4 + 2]) * 255 / alpha
            if max(r, g, b) < 90 { dark += 1 }
        }
        guard opaque > 0 else { return false }
        let coverage = Double(opaque) / Double(side * side)
        return coverage < 0.95 && Double(dark) / Double(opaque) > 0.9
    }
}

enum ProjectList {
    /// Files/directories whose presence marks a folder as being a project
    /// itself, rather than a parent folder *of* projects.
    private static let projectMarkers = [
        ".git", "package.json", "Package.swift", "Cargo.toml",
        "pyproject.toml", "go.mod", "Gemfile", "composer.json",
    ]

    /// Whether the folder is itself a project — used by "Add Folder" to
    /// decide between pinning it as one row and treating it as a parent
    /// group. Without this, picking a single project listed its `src`/
    /// `node_modules` innards as if they were projects.
    static func isProject(_ path: String) -> Bool {
        let fm = FileManager.default
        for marker in projectMarkers
        where fm.fileExists(atPath: (path as NSString).appendingPathComponent(marker)) {
            return true
        }
        // Xcode projects: any *.xcodeproj bundle at the top level.
        if let entries = try? fm.contentsOfDirectory(atPath: path),
           entries.contains(where: { $0.hasSuffix(".xcodeproj") }) {
            return true
        }
        return false
    }

    /// Lists immediate subdirectories of `projectsDir`. Skips dotfiles and
    /// non-directories.
    static func scan(projectsDir: String) -> [Project] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectsDir, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return []
        }
        var projects: [Project] = []
        for name in entries.sorted() {
            if name.hasPrefix(".") { continue }
            let full = (projectsDir as NSString).appendingPathComponent(name)
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date
            projects.append(
                Project(
                    id: full,
                    name: name,
                    path: full,
                    modifiedMs: mtime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
                )
            )
        }
        return projects
    }

    /// Every project Houston knows about: pinned projects plus scans of
    /// every parent folder, deduped by path (pinned wins), sorted by name.
    /// For pickers living outside the sidebar (e.g. the tasks sheet).
    static func allProjects(settings: HoustonSettings) -> [Project] {
        let fm = FileManager.default
        var seen = Set<String>()
        var projects: [Project] = []
        for path in settings.pinnedProjects {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(path).inserted else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            projects.append(Project(
                id: path,
                name: (path as NSString).lastPathComponent,
                path: path,
                modifiedMs: mtime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            ))
        }
        for dir in settings.projectsDirs {
            for project in scan(projectsDir: dir) where seen.insert(project.path).inserted {
                projects.append(project)
            }
        }
        return projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
