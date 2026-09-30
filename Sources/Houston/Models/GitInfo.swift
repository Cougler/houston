import Foundation

/// Glance-level git state for a sidebar row's status dot.
enum GitRowStatus: Equatable {
    /// Not a git repository.
    case none
    /// Uncommitted changes in the working tree, with line counts vs HEAD
    /// (untracked files not included).
    case dirty(added: Int, removed: Int)
    /// Working tree clean.
    case clean

    var isDirty: Bool {
        if case .dirty = self { return true }
        return false
    }
}

/// One uncommitted change in a working tree.
struct GitChange: Equatable, Identifiable {
    enum Kind: Equatable {
        case modified, added, deleted, renamed, untracked
    }

    let path: String
    let kind: Kind
    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

struct GitCommit: Equatable, Identifiable {
    let sha: String
    let subject: String
    let timeAgo: String
    /// True when this commit only exists locally (not pushed upstream).
    let isUnpushed: Bool
    var id: String { sha }
}

/// Everything Houston knows about a project's git state.
struct GitInfo: Equatable {
    let isRepo: Bool
    /// Branch name, "detached · <sha>", or "no commits yet".
    let branchLabel: String
    /// Local branch names, for the panel's switcher.
    let branches: [String]
    let changes: [GitChange]
    let hasUpstream: Bool
    let ahead: Int
    let behind: Int
    let commits: [GitCommit]
    /// Browseable remote (https), when origin is set.
    let remoteURL: String?

    static let notARepo = GitInfo(
        isRepo: false, branchLabel: "", branches: [], changes: [],
        hasUpstream: false, ahead: 0, behind: 0, commits: [], remoteURL: nil
    )
}
