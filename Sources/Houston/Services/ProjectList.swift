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
}
