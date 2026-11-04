import Foundation

/// One markdown document on disk — a project's `docs/<Title>.md` or a
/// file in the global docs folder. The filename IS the title.
struct DocRef: Identifiable, Hashable {
    let path: String
    let modified: Date

    var id: String { path }
    var title: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// The documents feature's file index (2026-10-20). Project documents
/// are plain `.md` files under `<project>/docs/` — in the repo, readable
/// by agents, nothing Houston-specific about them; global documents sit
/// in one folder shared by every project (`HoustonSettings.globalDocsDir`,
/// default `~/Documents/Houston`). Listing is a cheap directory read,
/// polled every 2s while a workspace is open so files an agent writes
/// show up without a relaunch.
@MainActor
final class DocumentStore: ObservableObject {
    static let shared = DocumentStore()

    @Published private(set) var projectDocs: [String: [DocRef]] = [:]
    @Published private(set) var globalDocs: [DocRef] = []

    private var watched: String?
    private var timer: Timer?

    static func docsDir(for project: String) -> String {
        (project as NSString).appendingPathComponent("docs")
    }

    static var globalDir: String {
        let configured = HoustonSettings.read().globalDocsDir
        return configured.isEmpty
            ? "~/Documents/Houston".expandingTildePath
            : configured.expandingTildePath
    }

    /// The directory a document lives in belongs to a project (its
    /// `docs/` folder) or is the global folder.
    static func project(of path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        guard (dir as NSString).lastPathComponent == "docs" else { return nil }
        return (dir as NSString).deletingLastPathComponent
    }

    func docs(for project: String) -> [DocRef] {
        projectDocs[project] ?? []
    }

    /// Follow the workspace: list this project's docs now and keep both
    /// lists fresh while it's open.
    func watch(_ project: String?) {
        watched = project
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        if let project = watched {
            let docs = Self.list(Self.docsDir(for: project))
            if projectDocs[project] != docs { projectDocs[project] = docs }
        }
        let global = Self.list(Self.globalDir)
        if globalDocs != global { globalDocs = global }
    }

    private static func list(_ dir: String) -> [DocRef] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return (ext == "md" || ext == "markdown") && !name.hasPrefix(".")
            }
            .compactMap { name -> DocRef? in
                let path = (dir as NSString).appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: path)
                guard attrs?[.type] as? FileAttributeType != .typeDirectory else { return nil }
                return DocRef(path: path, modified: attrs?[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// A new empty "Untitled" document in the directory (numbered past
    /// an existing one), created on disk so it's listable at once.
    @discardableResult
    func create(in dir: String, title: String = "Untitled") -> DocRef? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var name = title
        var n = 2
        while fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name + ".md")) {
            name = "\(title) \(n)"
            n += 1
        }
        let path = (dir as NSString).appendingPathComponent(name + ".md")
        guard fm.createFile(atPath: path, contents: Data()) else { return nil }
        refresh()
        return DocRef(path: path, modified: Date())
    }

    /// Renames the file to `<title>.md` beside itself; nil if the name
    /// is empty, unchanged, or taken.
    func rename(_ path: String, to title: String) -> String? {
        let clean = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let target = (dir as NSString).appendingPathComponent(clean + ".md")
        guard target != path else { return nil }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target),
              (try? fm.moveItem(atPath: path, toPath: target)) != nil else { return nil }
        refresh()
        return target
    }

    func trash(_ path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        refresh()
    }
}
