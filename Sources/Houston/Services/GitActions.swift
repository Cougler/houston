import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Git actions Houston runs ITSELF (2026-10-23): commit, push, pull and
/// merge into the default branch — the four things a user who doesn't
/// speak git needs, phrased in words (`GitQuickActions.swift`) and run
/// directly so the result lands in the card, not a terminal. Everything
/// else stays in the branch menu's command catalog (typed into the
/// terminal). Blocks — call off the main thread.
enum GitActions {
    struct Outcome: Equatable {
        let ok: Bool
        let output: String
    }

    static func run(_ args: [String], in path: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        // Never block on an editor or a credential prompt: a push that
        // needs a password fails fast with the reason instead of hanging.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return Outcome(ok: false, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: process.terminationStatus == 0, output: output)
    }

    /// Paths with uncommitted changes (staged, unstaged, untracked).
    static func changedFiles(in path: String) -> [String] {
        let status = run(["status", "--porcelain", "-uall"], in: path)
        guard status.ok else { return [] }
        return status.output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            var file = String(line.dropFirst(3))
            if let arrow = file.range(of: " -> ") { file = String(file[arrow.upperBound...]) }
            return file
        }
    }

    static func currentBranch(in path: String) -> String? {
        let out = run(["branch", "--show-current"], in: path)
        return out.ok && !out.output.isEmpty ? out.output : nil
    }

    static func hasRemote(in path: String) -> Bool {
        let out = run(["remote"], in: path)
        return out.ok && !out.output.isEmpty
    }

    /// The branch work merges into: origin's HEAD when known, else main
    /// or master if either exists locally.
    static func defaultBranch(in path: String) -> String? {
        let head = run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: path)
        if head.ok, let name = head.output.split(separator: "/").last { return String(name) }
        for candidate in ["main", "master"]
        where run(["rev-parse", "-q", "--verify", "refs/heads/" + candidate], in: path).ok {
            return candidate
        }
        return nil
    }

    /// Stage everything and commit.
    static func commitAll(in path: String, message: String) -> Outcome {
        let add = run(["add", "-A"], in: path)
        guard add.ok else { return add }
        return run(["commit", "-m", message], in: path)
    }

    /// Push the current branch; a branch with no upstream yet gets one.
    static func push(in path: String) -> Outcome {
        let upstream = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path)
        if upstream.ok { return run(["push"], in: path) }
        guard let branch = currentBranch(in: path) else {
            return Outcome(ok: false, output: "Not on a branch.")
        }
        return run(["push", "-u", "origin", branch], in: path)
    }

    /// Fast-forward only: a pull that would need a merge fails with the
    /// reason instead of leaving the checkout mid-merge.
    static func pull(in path: String) -> Outcome {
        run(["pull", "--ff-only"], in: path)
    }

    enum MergeResult: Equatable {
        case merged(into: String)
        /// Conflicts: the merge was aborted and the checkout is back on
        /// its branch, untouched.
        case conflicts(with: String)
        case failed(String)
    }

    /// Bring the current branch's commits into the default branch, then
    /// come back — the user stays where they were. Needs a clean tree.
    static func mergeIntoDefault(in path: String) -> MergeResult {
        guard let branch = currentBranch(in: path) else { return .failed("Not on a branch.") }
        guard let target = defaultBranch(in: path) else {
            return .failed("No main branch to merge into.")
        }
        guard branch != target else { return .failed("Already on \(target).") }
        guard changedFiles(in: path).isEmpty else {
            return .failed("Commit or stash the uncommitted changes first.")
        }
        let out = run(["switch", target], in: path)
        guard out.ok else { return .failed(out.output) }
        let merge = run(["merge", "--no-edit", branch], in: path)
        if !merge.ok {
            if run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: path).ok {
                _ = run(["merge", "--abort"], in: path)
                _ = run(["switch", branch], in: path)
                return .conflicts(with: target)
            }
            _ = run(["switch", branch], in: path)
            return .failed(merge.output)
        }
        _ = run(["switch", branch], in: path)
        return .merged(into: target)
    }

    /// A one-line commit subject for the working tree's changes: the
    /// on-device model from the diff stat and what the chat was asked
    /// (macOS 26); otherwise the prompt itself, trimmed to a subject, or
    /// the file names.
    static func suggestCommitMessage(in path: String, hint: String?) async -> String {
        let files = changedFiles(in: path)
        let stat = run(["diff", "HEAD", "--stat", "--stat-width=80"], in: path).output
        let fallback = fallbackSubject(hint: hint, files: files)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
            let session = LanguageModelSession(instructions: """
            Write ONE git commit subject line for the changes described. \
            Imperative mood, at most 65 characters, no trailing period, no \
            quotes, no preamble — only the line itself.
            """)
            var prompt = "Files changed:\n" + files.prefix(30).joined(separator: "\n")
            if !stat.isEmpty { prompt += "\n\nDiff stat:\n" + String(stat.prefix(1500)) }
            if let hint, !hint.isEmpty {
                prompt += "\n\nThe change was asked for as: " + String(hint.prefix(400))
            }
            if let response = try? await session.respond(to: prompt) {
                let line = response.content
                    .split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.`")) ?? ""
                if line.count >= 6, line.count <= 90 { return line }
            }
        }
        #endif
        return fallback
    }

    static func fallbackSubject(hint: String?, files: [String]) -> String {
        if let hint {
            let line = ChatArchive.condense(hint)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
            if line.count >= 6 {
                let clipped = line.count > 65 ? String(line.prefix(64)).trimmingCharacters(in: .whitespaces) + "…" : line
                return clipped.prefix(1).uppercased() + clipped.dropFirst()
            }
        }
        let names = files.prefix(3).map { ($0 as NSString).lastPathComponent }
        if names.isEmpty { return "Update project" }
        let rest = files.count - names.count
        return "Update " + names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }
}
