import Foundation

/// Reads a project's git state by shelling out to `git`. Read-only — nothing
/// here mutates a repository. Blocks — call off the main thread.
enum GitDetect {

    static func snapshot(projectPath: String) -> GitInfo {
        guard git(["rev-parse", "--is-inside-work-tree"], in: projectPath) == "true" else {
            return .notARepo
        }

        let changes = parseStatus(
            git(["status", "--porcelain"], in: projectPath) ?? ""
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
            changes: changes,
            hasUpstream: hasUpstream,
            ahead: ahead,
            behind: behind,
            commits: commits,
            remoteURL: browseableRemote(in: projectPath)
        )
    }

    /// Cheap per-row status for the sidebar dot.
    static func rowStatus(projectPath: String) -> GitRowStatus {
        guard git(["rev-parse", "--is-inside-work-tree"], in: projectPath) == "true" else {
            return .none
        }
        let porcelain = git(["status", "--porcelain"], in: projectPath) ?? ""
        return porcelain.isEmpty ? .clean : .dirty
    }

    /// Everything about one commit, for the panel's detail page.
    static func commitDetail(sha: String, in projectPath: String) -> GitCommitDetail? {
        guard let meta = git(
            [
                "show", "--no-patch",
                "--date=format:%b %-d, %Y at %H:%M",
                "--format=%an\u{1f}%ad\u{1f}%s\u{1f}%b",
                sha,
            ],
            in: projectPath
        ), !meta.isEmpty else { return nil }
        let fields = meta.components(separatedBy: "\u{1f}")
        guard fields.count >= 4 else { return nil }

        // Kinds from --name-status, counts from --numstat, joined by path.
        var kinds: [String: GitChange.Kind] = [:]
        if let status = git(["show", "--name-status", "--format=", sha], in: projectPath) {
            for line in status.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count >= 2 else { continue }
                let code = parts[0]
                let path = String(parts.last ?? "")
                kinds[path] = if code.hasPrefix("A") { .added }
                    else if code.hasPrefix("D") { .deleted }
                    else if code.hasPrefix("R") { .renamed }
                    else { .modified }
            }
        }
        var files: [GitCommitFile] = []
        if let numstat = git(["show", "--numstat", "--format=", sha], in: projectPath) {
            for line in numstat.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let path = String(parts[2])
                files.append(
                    GitCommitFile(
                        path: path,
                        kind: kinds[path] ?? .modified,
                        added: Int(parts[0]),   // "-" for binary → nil
                        deleted: Int(parts[1])
                    )
                )
            }
        }

        return GitCommitDetail(
            sha: sha,
            subject: fields[2],
            body: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
            author: fields[0],
            date: fields[1],
            files: files
        )
    }

    /// The changed lines of one uncommitted file, for the diff page.
    static func fileDiff(change: GitChange, in projectPath: String) -> [GitDiffLine] {
        // `diff HEAD` covers staged + unstaged in one view; fall back for
        // unborn-HEAD repos, then to the raw file for untracked ones.
        var raw = git(["diff", "HEAD", "--", change.path], in: projectPath) ?? ""
        if raw.isEmpty {
            raw = git(["diff", "--cached", "--", change.path], in: projectPath) ?? ""
        }
        if raw.isEmpty {
            raw = git(["diff", "--", change.path], in: projectPath) ?? ""
        }
        if raw.isEmpty {
            return wholeFileAsAdded(change, in: projectPath)
        }
        if raw.contains("Binary files ") {
            return [GitDiffLine(id: 0, kind: .note, text: "Binary file — no text diff")]
        }

        var lines: [GitDiffLine] = []
        for line in raw.components(separatedBy: "\n") {
            if lines.count >= maxDiffLines {
                lines.append(GitDiffLine(id: lines.count, kind: .note, text: "… diff truncated"))
                break
            }
            if line.hasPrefix("diff --git") || line.hasPrefix("index ")
                || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("similarity") || line.hasPrefix("rename ")
                || line.hasPrefix("\\") {
                continue
            }
            let kind: GitDiffLine.Kind = if line.hasPrefix("@@") { .hunk }
                else if line.hasPrefix("+") { .added }
                else if line.hasPrefix("-") { .removed }
                else { .context }
            lines.append(GitDiffLine(id: lines.count, kind: kind, text: line))
        }
        return lines
    }

    private static let maxDiffLines = 1500

    /// Untracked files have no diff — show the whole file as new lines.
    private static func wholeFileAsAdded(
        _ change: GitChange,
        in projectPath: String
    ) -> [GitDiffLine] {
        let full = (projectPath as NSString).appendingPathComponent(change.path)
        guard let contents = try? String(contentsOfFile: full, encoding: .utf8) else {
            return [GitDiffLine(id: 0, kind: .note, text: "No preview available")]
        }
        var lines: [GitDiffLine] = []
        for line in contents.components(separatedBy: "\n") {
            if lines.count >= maxDiffLines {
                lines.append(GitDiffLine(id: lines.count, kind: .note, text: "… truncated"))
                break
            }
            lines.append(GitDiffLine(id: lines.count, kind: .added, text: "+" + line))
        }
        return lines
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
