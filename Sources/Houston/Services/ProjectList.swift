import Foundation

enum ProjectList {
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
