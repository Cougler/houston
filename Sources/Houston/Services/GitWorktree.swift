import Foundation

/// One linked worktree: a second checkout of a repo in its own folder,
/// sharing the repo's history. Houston puts them next to the project
/// (`~/Apps/houston-fix-crash`) and nests them under it in the sidebar.
struct GitWorktree: Hashable, Identifiable {
    let path: String
    /// Checked-out branch; nil when detached.
    let branch: String?
    var id: String { path }

    /// What rows call it: the branch, else the folder.
    var label: String { branch ?? (path as NSString).lastPathComponent }
}

/// Worktree plumbing. Listing reads `.git` files directly (no spawn — it
/// runs on the sidebar's poll); create/remove/merge shell out to `git`
/// and block, so call those off the main thread.
enum GitWorktrees {

    // MARK: - Reading (spawn-free)

    /// The directory holding a checkout's HEAD: `<path>/.git` for a main
    /// checkout, the `gitdir:` target for a linked worktree (whose `.git`
    /// is a one-line FILE, not a directory).
    static func gitDir(of path: String) -> String? {
        let dotGit = path + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue { return dotGit }
        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = raw.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)
        // `worktree.useRelativePaths` writes the pointer relative to the
        // worktree itself.
        return target.hasPrefix("/")
            ? target
            : ((path as NSString).appendingPathComponent(target) as NSString)
                .standardizingPath
    }

    /// The branch a checkout has out, from its HEAD file. nil = detached
    /// or not a repo.
    static func branch(of path: String) -> String? {
        guard let dir = gitDir(of: path) else { return nil }
        return branch(headFile: dir + "/HEAD")
    }

    private static func branch(headFile: String) -> String? {
        guard let head = try? String(contentsOfFile: headFile, encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return head.dropFirst("ref: refs/heads/".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For a linked worktree, the main checkout it belongs to; nil for a
    /// main checkout or a non-repo. `.git/worktrees/<name>` is the linked
    /// worktree's gitdir, so the main checkout is what precedes it.
    static func mainRepo(ofWorktree path: String) -> String? {
        guard let dir = gitDir(of: path), dir != path + "/.git",
              let range = dir.range(of: "/.git/worktrees/") else { return nil }
        return String(dir[..<range.lowerBound])
    }

    /// Linked worktrees of a main checkout, from `.git/worktrees/*`. A
    /// worktree whose folder is gone (deleted by hand, not yet pruned) is
    /// skipped.
    static func linked(of repoPath: String) -> [GitWorktree] {
        let admin = repoPath + "/.git/worktrees"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: admin) else { return [] }
        var out: [GitWorktree] = []
        for name in names.sorted() {
            let entry = admin + "/" + name
            guard let raw = try? String(contentsOfFile: entry + "/gitdir", encoding: .utf8)
            else { continue }
            var pointer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pointer.hasPrefix("/") {
                pointer = ((entry as NSString).appendingPathComponent(pointer) as NSString)
                    .standardizingPath
            }
            // The pointer names the worktree's `.git` file.
            let path = (pointer as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: path) else { continue }
            out.append(GitWorktree(path: path, branch: branch(headFile: entry + "/HEAD")))
        }
        return out
    }

    // MARK: - Mutating (spawns)

    struct Failure: Error {
        let message: String
    }

    /// `git worktree add` beside the main checkout. An existing local
    /// branch is checked out; a new name becomes a branch off `from`'s
    /// HEAD. Returns the new folder.
    static func create(branch: String, from path: String) -> Result<String, Failure> {
        guard git(["check-ref-format", "--branch", branch], in: path).ok else {
            return .failure(Failure(message: "\"\(branch)\" isn't a valid branch name."))
        }
        let repo = mainRepo(ofWorktree: path) ?? path
        let dest = siblingPath(repo: repo, branch: branch)
        let exists = git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], in: path).ok
        let args = exists
            ? ["worktree", "add", dest, branch]
            : ["worktree", "add", "-b", branch, dest]
        let result = git(args, in: path)
        return result.ok ? .success(dest) : .failure(Failure(message: result.output))
    }

    /// `<parent>/<repo>-<branch>`, with the branch's slashes flattened and
    /// a numeric suffix when the name is taken.
    static func siblingPath(repo: String, branch: String) -> String {
        let parent = (repo as NSString).deletingLastPathComponent
        let base = (repo as NSString).lastPathComponent
        let slug = branch
            .replacingOccurrences(of: "/", with: "-")
            .filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        var candidate = parent + "/" + base + "-" + (slug.isEmpty ? "worktree" : slug)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = parent + "/" + base + "-" + slug + "-" + String(n)
            n += 1
        }
        return candidate
    }

    /// Uncommitted changes (including untracked files) in a checkout.
    static func isDirty(_ path: String) -> Bool {
        let result = git(["status", "--porcelain"], in: path)
        return result.ok && !result.output.isEmpty
    }

    /// Deletes the worktree's folder. The branch survives — it may hold
    /// work that never merged. `force` discards uncommitted changes.
    static func remove(_ worktree: String, force: Bool) -> Result<Void, Failure> {
        let repo = mainRepo(ofWorktree: worktree) ?? worktree
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktree)
        let result = git(args, in: repo)
        return result.ok ? .success(()) : .failure(Failure(message: result.output))
    }

    enum MergeOutcome {
        case merged
        /// Conflicts: the merge was aborted, so the main checkout is back
        /// exactly as it was.
        case conflicts
        case failed(String)
    }

    /// Merges the worktree's branch into whatever the main checkout has
    /// out. Conflicts abort rather than leave the main checkout mid-merge
    /// behind the user's back.
    static func merge(branch: String, into repo: String) -> MergeOutcome {
        let result = git(["merge", "--no-edit", branch], in: repo)
        if result.ok { return .merged }
        if git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo).ok {
            _ = git(["merge", "--abort"], in: repo)
            return .conflicts
        }
        return .failed(result.output)
    }

    /// Safe delete (`-d`): only succeeds once the branch is merged.
    @discardableResult
    static func deleteMergedBranch(_ branch: String, in repo: String) -> Bool {
        git(["branch", "-d", branch], in: repo).ok
    }

    /// Runs git, capturing stdout + stderr together — the error text is
    /// what the alert shows.
    private static func git(_ args: [String], in path: String) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return (false, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output)
    }
}
