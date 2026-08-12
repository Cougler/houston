import Foundation

/// Glance-level git state for a sidebar row's status dot.
enum GitRowStatus: Equatable {
    /// Not a git repository.
    case none
    /// Uncommitted changes in the working tree.
    case dirty
    /// Working tree clean.
    case clean
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

/// One file touched by a commit, with its line counts (nil for binary files).
struct GitCommitFile: Equatable, Identifiable {
    let path: String
    let kind: GitChange.Kind
    let added: Int?
    let deleted: Int?
    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

/// One line of a file diff, prefix (`+`/`-`/space) preserved for alignment.
struct GitDiffLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case added, removed, context, hunk, note
    }

    let id: Int
    let kind: Kind
    let text: String
}

/// The second page of the git panel: everything about one commit.
struct GitCommitDetail: Equatable {
    let sha: String
    let subject: String
    let body: String
    let author: String
    let date: String
    let files: [GitCommitFile]

    var totalAdded: Int { files.compactMap(\.added).reduce(0, +) }
    var totalDeleted: Int { files.compactMap(\.deleted).reduce(0, +) }
}

/// Everything Houston knows about a project's git state.
struct GitInfo: Equatable {
    let isRepo: Bool
    /// Branch name, "detached · <sha>", or "no commits yet".
    let branchLabel: String
    let changes: [GitChange]
    let hasUpstream: Bool
    let ahead: Int
    let behind: Int
    let commits: [GitCommit]
    /// Browseable remote (https), when origin is set.
    let remoteURL: String?

    static let notARepo = GitInfo(
        isRepo: false, branchLabel: "", changes: [], hasUpstream: false,
        ahead: 0, behind: 0, commits: [], remoteURL: nil
    )

    /// The line under the branch name — only what the section labels don't
    /// already say (uncommitted and to-push counts live on their sections).
    var headerSubtext: String {
        guard isRepo else { return "" }
        var parts: [String] = []
        if changes.isEmpty && ahead == 0 && !commits.isEmpty && hasUpstream {
            parts.append("everything saved to the remote")
        }
        if behind > 0 { parts.append("\(behind) commit\(behind == 1 ? "" : "s") to pull") }
        if !hasUpstream && !commits.isEmpty { parts.append("no remote yet") }
        return parts.joined(separator: " · ")
    }
}
