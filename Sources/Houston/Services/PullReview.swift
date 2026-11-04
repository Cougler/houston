import Combine
import Foundation

/// What one review run concluded — the CLI's structured output, decoded.
/// The shape is pinned by `ReviewVerdict.schema` (`--json-schema`), so
/// a run either yields this or fails; there is no prose to parse.
struct ReviewVerdict: Codable, Equatable {
    enum Decision: String, Codable {
        case approve
        case requestChanges = "request_changes"
        case comment
        case needsHuman = "needs_human"

        var words: String {
            switch self {
            case .approve: "Looks good"
            case .requestChanges: "Changes needed"
            case .comment: "Comments only"
            case .needsHuman: "Needs you"
            }
        }
    }

    struct Finding: Codable, Equatable, Identifiable {
        enum Severity: String, Codable { case blocker, major, minor, nit }
        let severity: Severity
        let file: String?
        let line: Int?
        let title: String
        let detail: String
        var id: String { "\(file ?? "")#\(line ?? 0):\(title)" }
    }

    let decision: Decision
    /// 1 (trivial) … 5 (dangerous).
    let risk: Int
    /// 0 … 100.
    let confidence: Int
    let summary: String
    let findings: [Finding]
    /// Why a person should look, when the model says so (may be empty).
    let humanReasons: [String]

    enum CodingKeys: String, CodingKey {
        case decision, risk, confidence, summary, findings
        case humanReasons = "human_reasons"
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["decision","risk","confidence","summary","findings","human_reasons"],
     "properties":{
      "decision":{"type":"string","enum":["approve","request_changes","comment","needs_human"],
        "description":"approve: mergeable as is. request_changes: concrete problems to fix first. comment: nothing blocking, remarks only. needs_human: too large, too risky, or outside what a reviewer can judge from the code."},
      "risk":{"type":"integer","minimum":1,"maximum":5,"description":"1 trivial, 2 low, 3 moderate, 4 high, 5 dangerous (data loss, security, payments, auth, migrations, build/release)."},
      "confidence":{"type":"integer","minimum":0,"maximum":100,"description":"How sure you are of the decision."},
      "summary":{"type":"string","description":"Two to four plain sentences: what the change does and whether it is right."},
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["severity","title","detail"],
        "properties":{
          "severity":{"type":"string","enum":["blocker","major","minor","nit"]},
          "file":{"type":"string"},
          "line":{"type":"integer"},
          "title":{"type":"string","description":"One line."},
          "detail":{"type":"string","description":"What is wrong and what would fix it."}}}},
      "human_reasons":{"type":"array","items":{"type":"string"},"description":"Each a short sentence on why a person must look. Empty when none."}}}
    """

    /// The verdict as a markdown comment (the pasteboard / a future post).
    func markdown(model: String) -> String {
        var out = "**\(decision.words)** · risk \(risk)/5 · confidence \(confidence)%\n\n\(summary)\n"
        if !findings.isEmpty {
            out += "\n"
            for f in findings {
                var loc = ""
                if let file = f.file { loc = " `\(file)" + (f.line.map { ":\($0)" } ?? "") + "`" }
                out += "- **\(f.severity.rawValue)**\(loc) — \(f.title)\n  \(f.detail)\n"
            }
        }
        if !humanReasons.isEmpty {
            out += "\nNeeds a human because:\n" + humanReasons.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        out += "\n_Reviewed by \(model) via Houston._\n"
        return out
    }
}

/// One review of one PR head: what ran, what it cost, what it found.
struct ReviewRun: Codable, Equatable, Identifiable {
    let id: UUID
    let number: Int
    let headSHA: String
    let model: String
    let startedAt: Date
    var finishedAt: Date?
    var durationMs: Int?
    var costUSD: Double?
    var turns: Int?
    var verdict: ReviewVerdict?
    var error: String?
    /// The files the reviewer opened, in order — the audit trail.
    var steps: [String] = []
    /// What the PR changes (numstat against the merge base): lines and
    /// paths — what the policy's thresholds are measured on.
    var linesChanged: Int?
    var changedPaths: [String]?
    /// The policy stopped the review before the model ran (too large).
    var skipped: String?
}

/// Progress of a run that's still going.
struct LiveReview: Equatable {
    var startedAt: Date
    var activity: String = "Checking out the pull request"
    var thinkingTokens: Int?
    var steps: [String] = []
    var phase: Phase = .preparing
    enum Phase: Equatable { case preparing, reviewing, cleaningUp }
}

/// Phase 2 of the ticket work (2026-11-04): ONE headless review of a
/// pull request by ONE Claude model, in a throwaway worktree, with the
/// verdict as structured output. The worker is `claude -p` — one
/// process, one PR, one answer — not a chat session: there's no
/// conversation to keep warm, no permission UI (the run is read-only
/// by flag: `--permission-mode dontAsk` plus an allowlist of Read /
/// Grep / Glob / `git diff|log|show`), and the result is a JSON object,
/// not a transcript. Nothing is posted anywhere; the verdict lands in
/// the PR page and on disk.
@MainActor
final class PullReviewStore: ObservableObject {
    static let shared = PullReviewStore()

    /// Finished runs per `slug#number`, newest first.
    @Published private(set) var runs: [String: [ReviewRun]] = [:]
    @Published private(set) var live: [String: LiveReview] = [:]

    private var loaded: Set<String> = []

    /// A chat model choice's label + flag, as the review needs them.
    struct Model: Hashable {
        let label: String
        let arg: String?
    }

    func load(_ key: String) {
        guard !loaded.contains(key) else { return }
        loaded.insert(key)
        if let saved = Self.read(key) { runs[key] = saved }
    }

    func latest(_ key: String) -> ReviewRun? { runs[key]?.first }

    func isRunning(_ key: String) -> Bool { live[key] != nil }

    /// Fetch the PR head into a sibling worktree, run the reviewer there,
    /// record the verdict, remove the worktree.
    func start(
        project: String, repo: GitHubRepo, item: InboxItem, baseRef: String, model: Model,
        maxLines: Int? = nil
    ) {
        let key = repo.slug + "#" + String(item.number)
        guard live[key] == nil else { return }
        load(key)
        live[key] = LiveReview(startedAt: Date())
        let number = item.number
        let title = item.title
        let body = item.body
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await PullReviewRunner.run(
                project: project, repo: repo, number: number, title: title, body: body,
                baseRef: baseRef, model: model, key: key, maxLines: maxLines,
                onProgress: { update in
                    Task { @MainActor in self?.apply(key, update) }
                }
            )
            await self?.finish(key, outcome)
        }
    }

    private func apply(_ key: String, _ update: (inout LiveReview) -> Void) {
        guard var current = live[key] else { return }
        update(&current)
        live[key] = current
    }

    private func finish(_ key: String, _ outcome: PullReviewRunner.Outcome) {
        let steps = live[key]?.steps ?? []
        live[key] = nil
        var run = outcome.run
        run.steps = steps
        var list = runs[key] ?? []
        list.insert(run, at: 0)
        if list.count > 20 { list.removeLast(list.count - 20) }
        runs[key] = list
        Self.write(key, list)
    }

    func cancel(_ key: String) {
        PullReviewRunner.cancel(key)
    }

    // MARK: disk

    private static var dir: String {
        ("~/Library/Application Support/Houston/inbox/reviews" as String).expandingTildePath
    }

    private static func path(_ key: String) -> String {
        dir + "/" + String(key.map { $0.isLetter || $0.isNumber ? $0 : "-" }) + ".json"
    }

    private static func read(_ key: String) -> [ReviewRun]? {
        guard let data = FileManager.default.contents(atPath: path(key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([ReviewRun].self, from: data)
    }

    private static func write(_ key: String, _ runs: [ReviewRun]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(runs) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(key)), options: .atomic)
    }
}

/// The blocking half: git plumbing + the `claude -p` process. Runs on a
/// detached task; reports through the closures.
enum PullReviewRunner {
    struct Outcome: Sendable {
        var run: ReviewRun
    }

    typealias Progress = @Sendable (@escaping @Sendable (inout LiveReview) -> Void) -> Void

    /// Running processes by review key, for Stop.
    nonisolated(unsafe) private static var processes: [String: Process] = [:]
    private static let lock = NSLock()

    static func cancel(_ key: String) {
        lock.lock()
        let process = processes[key]
        lock.unlock()
        process?.terminate()
    }

    private static func register(_ key: String, _ process: Process?) {
        lock.lock()
        processes[key] = process
        lock.unlock()
    }

    /// Bytes appended from a pipe's readability handler.
    private final class ByteBox: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let allowedTools = [
        "Read", "Grep", "Glob",
        "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(git status:*)",
    ]

    static func run(
        project: String, repo: GitHubRepo, number: Int, title: String, body: String,
        baseRef: String, model: PullReviewStore.Model, key: String,
        maxLines: Int? = nil,
        onProgress: @escaping Progress
    ) async -> Outcome {
        let startedAt = Date()
        var run = ReviewRun(
            id: UUID(), number: number, headSHA: "", model: model.label, startedAt: startedAt
        )
        let mainRepo = GitWorktrees.mainRepo(ofWorktree: project) ?? project
        let ref = "refs/houston/pr/\(number)"

        // 1. Fetch the PR head and the base.
        let fetch = GitActions.run(["fetch", "--quiet", "origin", "+refs/pull/\(number)/head:\(ref)"], in: mainRepo)
        guard fetch.ok else {
            run.error = "Couldn't fetch the pull request: " + fetch.output
            run.finishedAt = Date()
            return Outcome(run: run)
        }
        _ = GitActions.run(["fetch", "--quiet", "origin", baseRef], in: mainRepo)
        let head = GitActions.run(["rev-parse", ref], in: mainRepo)
        run = ReviewRun(
            id: run.id, number: number, headSHA: head.ok ? String(head.output.prefix(40)) : "",
            model: model.label, startedAt: startedAt
        )
        let mergeBase = GitActions.run(["merge-base", ref, "origin/" + baseRef], in: mainRepo)
        let base = mergeBase.ok ? mergeBase.output : nil

        // 2. A detached worktree beside the project.
        let worktree = GitWorktrees.siblingPath(repo: mainRepo, branch: "pr-\(number)")
        let add = GitActions.run(["worktree", "add", "--detach", "--quiet", worktree, ref], in: mainRepo)
        guard add.ok else {
            run.error = "Couldn't create a worktree: " + add.output
            run.finishedAt = Date()
            return Outcome(run: run)
        }
        defer {
            _ = GitActions.run(["worktree", "remove", "--force", worktree], in: mainRepo)
            _ = GitActions.run(["update-ref", "-d", ref], in: mainRepo)
        }

        // 3. What changed, for the policy (numstat: added, removed, path).
        if let base {
            let numstat = GitActions.run(["diff", "--numstat", base, "HEAD"], in: worktree)
            var lines = 0
            var paths: [String] = []
            for row in numstat.output.split(separator: "\n") {
                let cols = row.split(separator: "\t", maxSplits: 2).map(String.init)
                guard cols.count == 3 else { continue }
                lines += (Int(cols[0]) ?? 0) + (Int(cols[1]) ?? 0)
                paths.append(cols[2])
            }
            run.linesChanged = lines
            run.changedPaths = paths
            if let maxLines, lines > maxLines {
                run.skipped = "\(lines) lines changed, over the \(maxLines)-line limit for an automatic review."
                run.finishedAt = Date()
                return Outcome(run: run)
            }
        }

        // The diff the reviewer starts from (capped; it can run git for more).
        var diff = base.map { GitActions.run(["diff", "--stat=120", $0, "HEAD"], in: worktree).output } ?? ""
        if let base {
            let full = GitActions.run(["diff", base, "HEAD"], in: worktree).output
            diff += "\n\n" + (full.count > 40_000 ? String(full.prefix(40_000)) + "\n…(diff truncated; run git diff for the rest)" : full)
        }

        onProgress { $0.phase = .reviewing; $0.activity = "Reading the pull request" }

        // 4. The reviewer.
        guard let claude = AgentTransport.resolveBinary("claude") else {
            run.error = "The claude CLI isn't installed."
            run.finishedAt = Date()
            return Outcome(run: run)
        }
        let prompt = prompt(
            repo: repo, number: number, title: title, body: body,
            baseRef: baseRef, base: base, diff: diff
        )
        var args = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "dontAsk",
            "--max-turns", "40",
            "--json-schema", ReviewVerdict.schema,
            "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch",
            "--allowedTools",
        ] + allowedTools
        if let arg = model.arg { args = ["--model", arg] + args }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: worktree)
        process.environment = AgentTransport.spawnEnvironment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            run.error = "Couldn't start claude: " + error.localizedDescription
            run.finishedAt = Date()
            return Outcome(run: run)
        }
        register(key, process)
        defer { register(key, nil) }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()

        let errText = ByteBox()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errText.append(data) }
        }

        // 5. Stream events: tool_use → activity + step list; result → verdict.
        var buffer = Data()
        var sawResult = false
        let handle = stdout.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = json["type"] as? String else { continue }
                switch type {
                case "assistant":
                    let message = json["message"] as? [String: Any]
                    for block in message?["content"] as? [[String: Any]] ?? [] {
                        guard block["type"] as? String == "tool_use",
                              let name = block["name"] as? String else { continue }
                        let input = block["input"] as? [String: Any]
                        let words = name == "StructuredOutput"
                            ? "Writing the verdict"
                            : ChatAgentSession.toolActivity(name, input)
                        onProgress {
                            $0.activity = words
                            $0.thinkingTokens = nil
                            if name != "StructuredOutput" { $0.steps.append(words) }
                        }
                    }
                case "system":
                    if json["subtype"] as? String == "thinking_tokens",
                       let tokens = json["estimated_tokens"] as? Int {
                        onProgress { $0.thinkingTokens = tokens }
                    }
                case "result":
                    sawResult = true
                    run.durationMs = json["duration_ms"] as? Int
                    run.costUSD = json["total_cost_usd"] as? Double
                    run.turns = json["num_turns"] as? Int
                    if let structured = json["structured_output"],
                       let data = try? JSONSerialization.data(withJSONObject: structured),
                       let verdict = try? JSONDecoder().decode(ReviewVerdict.self, from: data) {
                        run.verdict = verdict
                    } else {
                        let subtype = json["subtype"] as? String ?? "unknown"
                        let text = (json["result"] as? String)
                            ?? (json["errors"] as? [String])?.joined(separator: "\n")
                            ?? ""
                        run.error = "The review ended without a verdict (\(subtype))."
                            + (text.isEmpty ? "" : "\n" + String(text.prefix(600)))
                    }
                default:
                    break
                }
            }
        }
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil
        onProgress { $0.phase = .cleaningUp; $0.activity = "Removing the worktree" }

        if !sawResult, run.error == nil {
            let err = errText.text.trimmingCharacters(in: .whitespacesAndNewlines)
            run.error = process.terminationReason == .uncaughtSignal
                ? "Stopped."
                : "claude exited (\(process.terminationStatus))." + (err.isEmpty ? "" : "\n" + String(err.suffix(600)))
        }
        run.finishedAt = Date()
        return Outcome(run: run)
    }

    static func prompt(
        repo: GitHubRepo, number: Int, title: String, body: String,
        baseRef: String, base: String?, diff: String
    ) -> String {
        var p = """
        You are reviewing pull request #\(number) in \(repo.slug): "\(title)".

        You are in a throwaway worktree checked out at the PR's head commit (detached). \
        The base branch is `\(baseRef)`\(base.map { " and the merge base is `\($0.prefix(12))`" } ?? ""). \
        You can read any file and run `git diff`, `git log`, `git show` and `git status`. \
        You cannot edit files or run tests or builds — read the tests instead and say what they do and don't cover.

        Review it the way a careful senior engineer on this project would:
        - Read the whole diff, then the surrounding code the diff touches, so you judge the change in context, not in isolation.
        - Look for real defects first: wrong behaviour, missed edge cases, races, resource leaks, security and data-loss risks, broken contracts with callers.
        - Then design: does it fit how this codebase already does things (read the project's CLAUDE.md or README if present)?
        - Then tests: are the risky parts covered?
        - Skip style remarks unless the project has a stated rule.
        - Be concrete: name files and lines, say what is wrong and what would fix it. No praise padding.
        - Decide `needs_human` when the change is too large to judge, touches money, auth, security, migrations, releases or deletion, changes behaviour the PR description doesn't mention, or you are not confident. Say why in human_reasons.
        - Risk is about blast radius if the change is wrong, not about how good the code is.

        When you're done, give your verdict ONLY through the structured output tool.

        """
        if !body.trimmingCharacters(in: .whitespaces).isEmpty {
            p += "\n## Pull request description\n\n\(body.prefix(6000))\n"
        }
        if !diff.isEmpty {
            p += "\n## Diff against the merge base\n\n```diff\n\(diff)\n```\n"
        }
        return p
    }
}
