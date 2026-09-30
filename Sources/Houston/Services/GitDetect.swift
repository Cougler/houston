import Foundation

/// Reads a project's git state by shelling out to `git`. Read-only — nothing
/// here mutates a repository. Blocks — call off the main thread.
enum GitDetect {

    static func snapshot(projectPath: String) -> GitInfo {
        guard git(["rev-parse", "--is-inside-work-tree"], in: projectPath) == "true" else {
            return .notARepo
        }

        // -uall: an untracked directory is otherwise one collapsed "Docs/"
        // row — a file-looking entry that previews blank. List the actual
        // files inside instead, so every row opens to real content.
        let changes = parseStatus(
            git(["status", "--porcelain", "-uall"], in: projectPath) ?? ""
        )

        // Branch, falling back to the unborn-branch name (fresh `git init`)
        // and then a detached-HEAD marker.
        var branchLabel = git(["branch", "--show-current"], in: projectPath) ?? ""
        if branchLabel.isEmpty {
            branchLabel = git(["symbolic-ref", "--short", "HEAD"], in: projectPath) ?? ""
        }
        if branchLabel.isEmpty {
            let sha = git(["rev-parse", "--short", "HEAD"], in: projectPath) ?? "?"
            branchLabel = "detached · \(sha)"
        }

        let branches = (git(["branch", "--format=%(refname:short)"], in: projectPath) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        // "<behind>\t<ahead>" — empty output when there is no upstream.
        var hasUpstream = false
        var ahead = 0, behind = 0
        if let counts = git(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            in: projectPath
        ), !counts.isEmpty {
            let parts = counts.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, let b = Int(parts[0]), let a = Int(parts[1]) {
                hasUpstream = true
                behind = b
                ahead = a
            }
        }

        // Newest first, so with an upstream the first `ahead` are unpushed.
        var commits: [GitCommit] = []
        if let log = git(
            ["log", "-n", "15", "--format=%h\u{1f}%s\u{1f}%cr"],
            in: projectPath
        ) {
            for (index, line) in log.split(separator: "\n").enumerated() {
                let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { continue }
                commits.append(
                    GitCommit(
                        sha: String(fields[0]),
                        subject: String(fields[1]),
                        timeAgo: String(fields[2]),
                        // Without an upstream every commit is local-only —
                        // never let it read as "saved to GitHub".
                        isUnpushed: hasUpstream ? index < ahead : true
                    )
                )
            }
        }

        return GitInfo(
            isRepo: true,
            branchLabel: branchLabel,
            branches: branches,
            changes: changes,
            hasUpstream: hasUpstream,
            ahead: ahead,
            behind: behind,
            commits: commits,
            remoteURL: browseableRemote(in: projectPath)
        )
    }

    /// Repo-ness per path, without a spawn on the hot path: a `.git`
    /// entry at the root answers instantly (file or dir — worktrees use
    /// a file), and anything else falls back to one rev-parse cached for
    /// five minutes. Every watched row was paying a `git` spawn per 3s
    /// tick just to re-learn "still not a repo".
    nonisolated(unsafe) private static var repoVerdicts:
        [String: (at: Date, isRepo: Bool)] = [:]
    private static let verdictLock = NSLock()

    private static func isRepo(_ projectPath: String) -> Bool {
        if FileManager.default.fileExists(atPath: projectPath + "/.git") {
            return true
        }
        let now = Date()
        verdictLock.lock()
        if let hit = repoVerdicts[projectPath],
           now.timeIntervalSince(hit.at) < 300 {
            verdictLock.unlock()
            return hit.isRepo
        }
        verdictLock.unlock()
        let verdict = git(["rev-parse", "--is-inside-work-tree"], in: projectPath) == "true"
        verdictLock.lock()
        repoVerdicts[projectPath] = (now, verdict)
        verdictLock.unlock()
        return verdict
    }

    /// Cheap per-row status for the sidebar dot.
    static func rowStatus(projectPath: String) -> GitRowStatus {
        guard isRepo(projectPath) else { return .none }
        let porcelain = git(["status", "--porcelain"], in: projectPath) ?? ""
        guard !porcelain.isEmpty else { return .clean }
        // Line counts vs HEAD (staged + unstaged; binary rows are "-\t-").
        var added = 0, removed = 0
        if let numstat = git(["diff", "--numstat", "HEAD"], in: projectPath) {
            for line in numstat.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count >= 2 else { continue }
                added += Int(parts[0]) ?? 0
                removed += Int(parts[1]) ?? 0
            }
        }
        return .dirty(added: added, removed: removed)
    }

    // MARK: - Parsing

    /// `git status --porcelain`: `XY path` (or `XY old -> new` for renames).
    private static func parseStatus(_ raw: String) -> [GitChange] {
        var changes: [GitChange] = []
        for line in raw.split(separator: "\n") {
            guard line.count > 3 else { continue }
            let code = line.prefix(2)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            let kind: GitChange.Kind
            if code == "??" {
                kind = .untracked
            } else if code.contains("R") {
                kind = .renamed
            } else if code.contains("D") {
                kind = .deleted
            } else if code.contains("A") {
                kind = .added
            } else {
                kind = .modified
            }
            changes.append(GitChange(path: path, kind: kind))
        }
        return changes
    }

    /// origin's URL, normalised to something a browser can open.
    private static func browseableRemote(in path: String) -> String? {
        guard var url = git(["config", "--get", "remote.origin.url"], in: path),
              !url.isEmpty else { return nil }
        if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
        // git@github.com:user/repo → https://github.com/user/repo
        if url.hasPrefix("git@"), let colon = url.firstIndex(of: ":") {
            let host = url.dropFirst(4).prefix(upTo: colon)
            let repoPath = url.suffix(from: url.index(after: colon))
            url = "https://\(host)/\(repoPath)"
        }
        return url.hasPrefix("http") ? url : nil
    }

    private static func git(_ args: [String], in path: String) -> String? {
        ProcScan.run("/usr/bin/git", ["-C", path] + args)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
