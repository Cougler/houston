import Combine
import Foundation

/// A project's GitHub repository, read from `origin`.
struct GitHubRepo: Hashable {
    let owner: String
    let name: String

    var slug: String { owner + "/" + name }
    var url: String { "https://github.com/" + slug }

    /// `git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r.git`.
    static func parse(remote: String) -> GitHubRepo? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = s.range(of: "github.com") else { return nil }
        s = String(s[host.upperBound...])
        guard let first = s.first, first == ":" || first == "/" else { return nil }
        s.removeFirst()
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return GitHubRepo(owner: parts[0], name: parts[1])
    }

    /// Blocks (runs git) — call off the main thread.
    nonisolated static func detect(in path: String) -> GitHubRepo? {
        let out = GitActions.run(["config", "--get", "remote.origin.url"], in: path)
        guard out.ok else { return nil }
        return parse(remote: out.output)
    }
}

/// One open issue or pull request, as the Inbox lists it. The shape is
/// GitHub's `issues` listing (PRs ride it with a `pull_request` key —
/// verified against the live API 2026-11-04).
struct InboxItem: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case issue, pullRequest }

    let kind: Kind
    let number: Int
    let title: String
    let author: String
    let labels: [String]
    let createdAt: Date
    let updatedAt: Date
    let url: String
    let commentCount: Int
    let draft: Bool
    let body: String
    /// From the `pulls` listing (PRs only): the head commit and base
    /// branch — what a review is keyed by. nil for issues and for a
    /// cache written before 2026-11-04.
    var headSHA: String?
    var baseRef: String?

    var id: Int { number }
    var isPullRequest: Bool { kind == .pullRequest }

    static func from(_ json: [String: Any]) -> InboxItem? {
        guard let number = json["number"] as? Int,
              let title = json["title"] as? String else { return nil }
        let iso = ISO8601DateFormatter()
        let user = json["user"] as? [String: Any]
        let labels = (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return InboxItem(
            kind: json["pull_request"] != nil ? .pullRequest : .issue,
            number: number,
            title: title,
            author: user?["login"] as? String ?? "",
            labels: labels,
            createdAt: (json["created_at"] as? String).flatMap(iso.date(from:)) ?? .distantPast,
            updatedAt: (json["updated_at"] as? String).flatMap(iso.date(from:)) ?? .distantPast,
            url: json["html_url"] as? String ?? "",
            commentCount: json["comments"] as? Int ?? 0,
            draft: json["draft"] as? Bool ?? false,
            body: json["body"] as? String ?? ""
        )
    }
}

/// What a pull request's page needs beyond the listing: size, checks,
/// reviews, and the diff itself (`gh pr diff`, parsed per file).
struct PullRequestDetail: Equatable {
    struct Review: Equatable {
        let user: String
        /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED
        let state: String
    }
    struct Checks: Equatable {
        let total: Int
        let passed: Int
        let failed: Int
        var pending: Int { total - passed - failed }
    }
    struct FileChange: Equatable, Identifiable {
        let path: String
        let diff: FileDiff
        var id: String { path }
    }

    let headRef: String
    let baseRef: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    /// GitHub's `mergeable_state`: clean / blocked / dirty / unstable / unknown…
    let mergeableState: String
    let reviews: [Review]
    let checks: Checks?
    let files: [FileChange]
}

/// A plain-text conversation entry under an item (issue comments; PRs
/// share the same endpoint).
struct InboxComment: Equatable, Identifiable {
    let id: Int
    let author: String
    let createdAt: Date
    let body: String
}

/// The GitHub Inbox (2026-11-04): every open issue and pull request of
/// the workspace's repo, polled through the user's own `gh` login — no
/// token of Houston's, no webhook, no server. One request per minute
/// per watched project (the `issues` listing carries PRs too), the
/// result cached on disk so a relaunch shows the last list at once.
/// Nothing here acts on GitHub; the store only reads.
@MainActor
final class GitHubInboxStore: ObservableObject {
    static let shared = GitHubInboxStore()

    enum Status: Equatable {
        case unknown
        /// `origin` isn't on github.com (or there is no origin).
        case notGitHub
        /// The `gh` CLI isn't installed or isn't signed in.
        case needsGH(String)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var items: [String: [InboxItem]] = [:]
    @Published private(set) var repos: [String: GitHubRepo] = [:]
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var refreshedAt: [String: Date] = [:]
    /// Keyed `slug#number`.
    @Published private(set) var details: [String: PullRequestDetail] = [:]
    @Published private(set) var comments: [String: [InboxComment]] = [:]
    @Published private(set) var detailErrors: [String: String] = [:]

    private var watched: String?
    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var detailInFlight: Set<String> = []

    static let pollInterval: TimeInterval = 60

    func items(for project: String) -> [InboxItem] { items[project] ?? [] }
    func status(for project: String) -> Status { status[project] ?? .unknown }
    func item(project: String, number: Int) -> InboxItem? {
        items[project]?.first { $0.number == number }
    }
    func detailKey(project: String, number: Int) -> String? {
        repos[project].map { $0.slug + "#" + String(number) }
    }

    /// Follow the workspace: detect the repo, show the cached list,
    /// fetch, and keep fetching once a minute while it's open.
    func watch(_ project: String?) {
        guard project != watched else { return }
        watched = project
        guard let project else { return }
        if repos[project] == nil, status[project] == nil {
            status[project] = .unknown
            if let cached = Self.readCache(project), items[project] == nil {
                items[project] = cached
            }
        }
        refresh(project)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let watched = self.watched else { return }
                    self.refresh(watched)
                }
            }
        }
    }

    func refresh(_ project: String) {
        guard !inFlight.contains(project) else { return }
        inFlight.insert(project)
        if status[project] != .ready { status[project] = .loading }
        let known = repos[project]
        Task.detached(priority: .utility) {
            let repo = known ?? GitHubRepo.detect(in: project)
            guard let repo else {
                await MainActor.run {
                    self.inFlight.remove(project)
                    self.status[project] = .notGitHub
                }
                return
            }
            let result = GitHubAPI.list(repo)
            await MainActor.run {
                self.inFlight.remove(project)
                self.repos[project] = repo
                switch result {
                case let .success(list):
                    if self.items[project] != list {
                        self.items[project] = list
                        Self.writeCache(project, list)
                    }
                    self.status[project] = .ready
                    self.refreshedAt[project] = Date()
                case let .failure(error):
                    self.status[project] = error.isGHMissing
                        ? .needsGH(error.message) : .failed(error.message)
                }
            }
        }
    }

    /// Fetch a PR's detail (stats, reviews, checks, diff) and an item's
    /// comments. Idempotent; a second call while one runs is dropped.
    func loadDetail(project: String, number: Int, force: Bool = false) {
        guard let repo = repos[project] else { return }
        let key = repo.slug + "#" + String(number)
        guard !detailInFlight.contains(key) else { return }
        guard force || details[key] == nil || comments[key] == nil else { return }
        let isPR = item(project: project, number: number)?.isPullRequest ?? false
        detailInFlight.insert(key)
        detailErrors[key] = nil
        Task.detached(priority: .userInitiated) {
            let comments = GitHubAPI.comments(repo, number: number)
            let detail = isPR ? GitHubAPI.pullRequest(repo, number: number) : nil
            await MainActor.run {
                self.detailInFlight.remove(key)
                if case let .success(list) = comments { self.comments[key] = list }
                switch detail {
                case let .success(d)?: self.details[key] = d
                case let .failure(e)?: self.detailErrors[key] = e.message
                case nil: break
                }
                if case let .failure(e) = comments, self.detailErrors[key] == nil {
                    self.detailErrors[key] = e.message
                }
            }
        }
    }

    // MARK: cache

    private static var cacheDir: String {
        ("~/Library/Application Support/Houston/inbox" as String).expandingTildePath
    }

    private static func cachePath(_ project: String) -> String {
        let munged = String(project.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return cacheDir + "/" + munged + ".json"
    }

    private static func readCache(_ project: String) -> [InboxItem]? {
        guard let data = FileManager.default.contents(atPath: cachePath(project)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([InboxItem].self, from: data)
    }

    private static func writeCache(_ project: String, _ items: [InboxItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath(project)), options: .atomic)
    }
}

/// The `gh` calls behind the store. Every call blocks on the CLI —
/// off-main only. `gh api` uses the user's keyring login and the same
/// scrubbed environment + shell PATH as the chat spawns, so "signed in"
/// here means what the user's terminal means.
enum GitHubAPI {
    struct Failure: Error, Equatable {
        let message: String
        let isGHMissing: Bool
    }

    static func list(_ repo: GitHubRepo) -> Result<[InboxItem], Failure> {
        api("repos/\(repo.slug)/issues?state=open&per_page=100&sort=updated&direction=desc")
            .flatMap { data in
                guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return .failure(Failure(message: "Unexpected reply from GitHub.", isGHMissing: false))
                }
                var items = array.compactMap(InboxItem.from)
                // The PR listing carries what the issue listing doesn't:
                // head SHA + base branch (verified shape: `head.sha`,
                // `base.ref`). A failure here leaves the items without
                // them rather than failing the whole list.
                if items.contains(where: \.isPullRequest),
                   case let .success(pullData) = api("repos/\(repo.slug)/pulls?state=open&per_page=100"),
                   let pulls = try? JSONSerialization.jsonObject(with: pullData) as? [[String: Any]] {
                    var heads: [Int: (sha: String, base: String)] = [:]
                    for pr in pulls {
                        guard let n = pr["number"] as? Int,
                              let sha = (pr["head"] as? [String: Any])?["sha"] as? String else { continue }
                        heads[n] = (sha, (pr["base"] as? [String: Any])?["ref"] as? String ?? "")
                    }
                    for i in items.indices where items[i].isPullRequest {
                        if let h = heads[items[i].number] {
                            items[i].headSHA = h.sha
                            items[i].baseRef = h.base.isEmpty ? nil : h.base
                        }
                    }
                }
                return .success(items)
            }
    }

    static func comments(_ repo: GitHubRepo, number: Int) -> Result<[InboxComment], Failure> {
        api("repos/\(repo.slug)/issues/\(number)/comments?per_page=100").map { data in
            let iso = ISO8601DateFormatter()
            let array = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            return array.compactMap { c in
                guard let id = c["id"] as? Int else { return nil }
                return InboxComment(
                    id: id,
                    author: (c["user"] as? [String: Any])?["login"] as? String ?? "",
                    createdAt: (c["created_at"] as? String).flatMap(iso.date(from:)) ?? .distantPast,
                    body: c["body"] as? String ?? ""
                )
            }
        }
    }

    static func pullRequest(_ repo: GitHubRepo, number: Int) -> Result<PullRequestDetail, Failure> {
        api("repos/\(repo.slug)/pulls/\(number)").flatMap { data in
            guard let pr = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(Failure(message: "Unexpected reply from GitHub.", isGHMissing: false))
            }
            let head = pr["head"] as? [String: Any]
            let base = pr["base"] as? [String: Any]
            let reviews: [PullRequestDetail.Review] = {
                guard case let .success(d) = api("repos/\(repo.slug)/pulls/\(number)/reviews?per_page=100"),
                      let array = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
                else { return [] }
                // Latest state per reviewer wins.
                var latest: [String: String] = [:]
                var order: [String] = []
                for r in array {
                    guard let user = (r["user"] as? [String: Any])?["login"] as? String,
                          let state = r["state"] as? String, state != "COMMENTED" else { continue }
                    if latest[user] == nil { order.append(user) }
                    latest[user] = state
                }
                return order.map { PullRequestDetail.Review(user: $0, state: latest[$0] ?? "") }
            }()
            let checks: PullRequestDetail.Checks? = {
                guard let sha = head?["sha"] as? String,
                      case let .success(d) = api("repos/\(repo.slug)/commits/\(sha)/check-runs?per_page=100"),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let runs = obj["check_runs"] as? [[String: Any]]
                else { return nil }
                let total = obj["total_count"] as? Int ?? runs.count
                guard total > 0 else { return nil }
                var passed = 0, failed = 0
                for run in runs {
                    switch run["conclusion"] as? String {
                    case "success", "neutral", "skipped": passed += 1
                    case "failure", "timed_out", "cancelled", "action_required": failed += 1
                    default: break
                    }
                }
                return PullRequestDetail.Checks(total: total, passed: passed, failed: failed)
            }()
            let files: [PullRequestDetail.FileChange] = {
                guard let text = ghText(["pr", "diff", String(number), "--repo", repo.slug]) else { return [] }
                return FileDiff.parseUnified(text).map { PullRequestDetail.FileChange(path: $0.path, diff: $0.diff) }
            }()
            return .success(PullRequestDetail(
                headRef: head?["ref"] as? String ?? "",
                baseRef: base?["ref"] as? String ?? "",
                additions: pr["additions"] as? Int ?? 0,
                deletions: pr["deletions"] as? Int ?? 0,
                changedFiles: pr["changed_files"] as? Int ?? 0,
                mergeableState: pr["mergeable_state"] as? String ?? "unknown",
                reviews: reviews,
                checks: checks,
                files: files
            ))
        }
    }

    // MARK: process

    private static func api(_ endpoint: String) -> Result<Data, Failure> {
        guard let gh = AgentTransport.resolveBinary("gh") else {
            return .failure(Failure(message: "The GitHub CLI (gh) isn't installed.", isGHMissing: true))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", endpoint]
        var env = AgentTransport.spawnEnvironment()
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failure(Failure(message: error.localizedDescription, isGHMissing: true))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // gh exits 4 when there's no login.
            let notLoggedIn = process.terminationStatus == 4
                || errText.localizedCaseInsensitiveContains("not logged")
                || errText.localizedCaseInsensitiveContains("gh auth login")
            let message = errText.isEmpty ? "gh exited with status \(process.terminationStatus)." : errText
            return .failure(Failure(message: message, isGHMissing: notLoggedIn))
        }
        return .success(data)
    }

    private static func ghText(_ args: [String]) -> String? {
        guard let gh = AgentTransport.resolveBinary("gh") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = args
        var env = AgentTransport.spawnEnvironment()
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_PAGER"] = "cat"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension FileDiff {
    /// A multi-file unified diff (`git diff` / `gh pr diff`) split into
    /// per-file `FileDiff`s. Binary files and files without hunks are
    /// skipped; `\ No newline at end of file` markers are dropped.
    static func parseUnified(_ text: String) -> [(path: String, diff: FileDiff)] {
        var out: [(path: String, diff: FileDiff)] = []
        var path: String?
        var hunks: [Hunk] = []
        var current: Hunk?
        var counter = 0

        func closeHunk() {
            if let h = current, !h.lines.isEmpty { hunks.append(h) }
            current = nil
        }
        func closeFile() {
            closeHunk()
            if let path, !hunks.isEmpty { out.append((path, FileDiff(hunks: hunks))) }
            path = nil
            hunks = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                // "diff --git a/x b/x" → the b/ side.
                if let range = line.range(of: " b/", options: .backwards) {
                    path = String(line[range.upperBound...])
                }
                continue
            }
            if line.hasPrefix("+++ ") {
                if line.hasPrefix("+++ b/") { path = String(line.dropFirst(6)) }
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("index ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename ")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("Binary files") || line.hasPrefix("\\ No newline") {
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                // @@ -old[,n] +new[,n] @@
                var oldStart = 1, newStart = 1
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldStart = Int(parts[1].dropFirst().split(separator: ",").first ?? "1") ?? 1
                    newStart = Int(parts[2].dropFirst().split(separator: ",").first ?? "1") ?? 1
                }
                current = Hunk(oldStart: oldStart, newStart: newStart, lines: [])
                continue
            }
            guard current != nil else { continue }
            counter += 1
            let text = String(line.dropFirst())
            switch line.first {
            case "+": current?.lines.append(Line(kind: .added, text: text, id: counter))
            case "-": current?.lines.append(Line(kind: .removed, text: text, id: counter))
            case " ", nil: current?.lines.append(Line(kind: .context, text: text, id: counter))
            default: continue
            }
        }
        closeFile()
        return out
    }
}

/// `HOUSTON_INBOX_SELFTEST=1 .build/debug/Houston` — headless checks of
/// the remote parser and the unified-diff splitter, the two pieces of
/// the Inbox that don't need a GitHub login to exercise.
enum InboxSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got == want {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)\n--- want\n\(want)\n--- got\n\(got)")
            }
        }
        let cougler = GitHubRepo(owner: "Cougler", name: "houston")
        expect("ssh remote", GitHubRepo.parse(remote: "git@github.com:Cougler/houston.git"), cougler)
        expect("https remote", GitHubRepo.parse(remote: "https://github.com/Cougler/houston"), cougler)
        expect("https .git remote", GitHubRepo.parse(remote: "https://github.com/Cougler/houston.git\n"), cougler)
        expect("ssh:// remote", GitHubRepo.parse(remote: "ssh://git@github.com/Cougler/houston.git"), cougler)
        expect("non-github remote", GitHubRepo.parse(remote: "git@gitlab.com:a/b.git"), nil)
        expect("bare host", GitHubRepo.parse(remote: "https://github.com/"), nil)

        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -1,3 +1,4 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -10,2 +11,2 @@ func f() {
         x
        -y
        +z
        diff --git a/bin/blob b/bin/blob
        Binary files a/bin/blob and b/bin/blob differ
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        \\ No newline at end of file
        """
        let files = FileDiff.parseUnified(diff)
        expect("file count (binary skipped)", files.map(\.path), ["src/a.swift", "new.txt"])
        expect("hunk count", files[0].diff.hunks.count, 2)
        expect("hunk starts", files[0].diff.hunks.map { [$0.oldStart, $0.newStart] }, [[1, 1], [10, 11]])
        expect("counts", [files[0].diff.added, files[0].diff.removed], [3, 2])
        expect("line kinds", files[0].diff.hunks[0].lines.map { "\($0.kind)" },
               ["context", "removed", "added", "added", "context"])
        expect("line text keeps indent", files[0].diff.hunks[0].lines[0].text, "let a = 1")
        expect("new file", [files[1].diff.added, files[1].diff.removed], [2, 0])
        expect("empty diff", FileDiff.parseUnified("").count, 0)

        let json: [String: Any] = [
            "number": 7, "title": "T", "user": ["login": "me"],
            "labels": [["name": "bug"]], "created_at": "2026-11-01T00:00:00Z",
            "updated_at": "2026-11-02T00:00:00Z", "html_url": "u", "comments": 2,
            "pull_request": ["url": "x"], "draft": true, "body": "b",
        ]
        let item = InboxItem.from(json)
        expect("item kind", item?.kind, .pullRequest)
        expect("item labels", item?.labels, ["bug"])
        expect("item draft", item?.draft, true)
        expect("issue kind", InboxItem.from(["number": 1, "title": "i"])?.kind, .issue)

        // The policy rules (pure).
        do {
            func pr(_ head: String = "abc") -> InboxItem {
                var i = InboxItem.from(["number": 5, "title": "t", "pull_request": ["url": "x"]])!
                i.headSHA = head; i.baseRef = "main"
                return i
            }
            func run(_ model: String, _ decision: ReviewVerdict.Decision, risk: Int = 2, confidence: Int = 90,
                     lines: Int = 40, paths: [String] = ["src/a.swift"], head: String = "abc",
                     skipped: String? = nil, error: String? = nil) -> ReviewRun {
                var r = ReviewRun(id: UUID(), number: 5, headSHA: head, model: model, startedAt: Date())
                r.verdict = skipped == nil && error == nil
                    ? ReviewVerdict(decision: decision, risk: risk, confidence: confidence, summary: "s",
                                    findings: [], humanReasons: decision == .needsHuman ? ["money"] : [])
                    : nil
                r.linesChanged = lines; r.changedPaths = paths; r.skipped = skipped; r.error = error
                return r
            }
            var policy = ReviewPolicy.default
            policy.modelLabel = "A"; policy.secondModelLabel = "B"
            func t(_ runs: [ReviewRun], live: Bool = false, detail: PullRequestDetail? = nil, policy p: ReviewPolicy = policy) -> Triage {
                TriageEngine.triage(item: pr(), detail: detail, runs: runs, live: live, policy: p)
            }
            expect("no run, automation off", t([]).state, .none)
            var auto = policy; auto.autoReview = true
            expect("no run, automation on", t([], policy: auto).state, .waiting)
            expect("live", t([], live: true).state, .reviewing)
            expect("approve clears", t([run("A", .approve)]).state, .clear)
            expect("needs_human", t([run("A", .needsHuman)]).reasons, ["money"])
            expect("risk line", t([run("A", .approve, risk: 4)]).state, .needsYou)
            expect("low confidence", t([run("A", .approve, confidence: 50)]).reasons.count, 1)
            expect("sensitive path", t([run("A", .approve, paths: ["db/Migrations/1.sql"])]).reasons.first?.hasPrefix("Touches"), true)
            expect("too big", t([run("A", .approve, lines: 900)]).reasons.first?.contains("900 lines"), true)
            expect("skipped", t([run("A", .approve, skipped: "big")]).reasons, ["big"])
            expect("failed", t([run("A", .approve, error: "boom\nmore")]).reasons, ["The review failed: boom"])
            expect("old head ignored", t([run("A", .needsHuman, head: "old")]).state, .none)
            var two = policy; two.secondOpinion = true
            expect("second pending", t([run("A", .approve)], policy: two).state, .waiting)
            expect("second agrees", t([run("A", .approve), run("B", .comment)], policy: two).state, .clear)
            expect("second disagrees", t([run("A", .approve), run("B", .requestChanges)], policy: two).reasons.first?.hasPrefix("The models disagree"), true)
            let failing = PullRequestDetail(headRef: "f", baseRef: "main", additions: 1, deletions: 1, changedFiles: 1,
                                            mergeableState: "dirty", reviews: [], checks: .init(total: 2, passed: 1, failed: 1), files: [])
            expect("checks + conflicts", t([run("A", .approve)], detail: failing).reasons, ["1 check failing.", "Has merge conflicts."])
            expect("issue is none", TriageEngine.triage(item: InboxItem.from(["number": 1, "title": "i"])!, detail: nil, runs: [], live: false, policy: auto).state, .none)
        }

        // Optional live round trip through the user's gh login:
        // HOUSTON_INBOX_LIVE=owner/repo[#pr-number].
        if let live = ProcessInfo.processInfo.environment["HOUSTON_INBOX_LIVE"] {
            let parts = live.split(separator: "#").map(String.init)
            if let repo = GitHubRepo.parse(remote: "https://github.com/" + parts[0]) {
                switch GitHubAPI.list(repo) {
                case let .success(items):
                    print("ok   live list: \(items.count) open (\(items.filter(\.isPullRequest).count) PRs)")
                case let .failure(e):
                    failures += 1
                    print("FAIL live list: \(e.message)")
                }
                if parts.count > 1, let number = Int(parts[1]) {
                    switch GitHubAPI.pullRequest(repo, number: number) {
                    case let .success(d):
                        print("ok   live PR #\(number): \(d.headRef) → \(d.baseRef), +\(d.additions) −\(d.deletions), "
                              + "\(d.files.count) files parsed of \(d.changedFiles), checks \(String(describing: d.checks)), "
                              + "reviews \(d.reviews.count), \(d.mergeableState)")
                        if d.files.count != d.changedFiles, d.changedFiles <= 300 {
                            failures += 1
                            print("FAIL live PR file count")
                        }
                    case let .failure(e):
                        failures += 1
                        print("FAIL live PR: \(e.message)")
                    }
                    switch GitHubAPI.comments(repo, number: number) {
                    case let .success(c): print("ok   live comments: \(c.count)")
                    case let .failure(e): failures += 1; print("FAIL live comments: \(e.message)")
                    }
                }
            }
        }
        // Optional live review: HOUSTON_REVIEW_LIVE=/path/to/clone#pr[@model]
        // runs the whole phase-2 pipeline (fetch, worktree, claude -p,
        // verdict, cleanup) and prints what came back.
        if let live = ProcessInfo.processInfo.environment["HOUSTON_REVIEW_LIVE"] {
            let semaphore = DispatchSemaphore(value: 0)
            let parts = live.split(separator: "#", maxSplits: 1).map(String.init)
            let tail = parts.count > 1 ? parts[1].split(separator: "@").map(String.init) : []
            // A non-GitHub origin (a local bare repo with a pull ref) still
            // exercises the pipeline; the slug only names the PR in the prompt.
            if parts.count == 2, let number = Int(tail[0]) {
                let repo = GitHubRepo.detect(in: parts[0]) ?? GitHubRepo(owner: "local", name: "test")
                let model = PullReviewStore.Model(label: tail.count > 1 ? tail[1] : "default", arg: tail.count > 1 ? tail[1] : nil)
                Task.detached {
                    let outcome = await PullReviewRunner.run(
                        project: parts[0], repo: repo, number: number,
                        title: "(live test)", body: "", baseRef: "main", model: model, key: "live",
                        onProgress: { update in
                            var l = LiveReview(startedAt: Date())
                            update(&l)
                            print("     … \(l.activity)")
                        }
                    )
                    let run = outcome.run
                    if let v = run.verdict {
                        print("ok   live review: \(v.decision.rawValue), risk \(v.risk), confidence \(v.confidence), \(v.findings.count) findings, "
                              + "\(run.durationMs ?? 0)ms, $\(run.costUSD ?? 0), head \(run.headSHA.prefix(7))")
                        print(v.markdown(model: run.model))
                    } else {
                        print("FAIL live review: \(run.error ?? "no verdict")")
                    }
                    semaphore.signal()
                }
                if semaphore.wait(timeout: .now() + 900) == .timedOut {
                    failures += 1
                    print("FAIL live review: timed out")
                }
                let leftover = GitActions.run(["worktree", "list"], in: parts[0]).output
                expect("worktree removed", leftover.contains("-pr-\(number)"), false)
            } else {
                failures += 1
                print("FAIL live review: bad HOUSTON_REVIEW_LIVE")
            }
        }
        print(failures == 0 ? "all inbox checks passed" : "\(failures) inbox check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
