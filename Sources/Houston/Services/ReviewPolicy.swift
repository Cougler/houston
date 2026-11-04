import Combine
import Foundation

/// Phase 3 (2026-11-04): what a repo's owner lets Houston do with its
/// pull requests on its own, and the line past which a person must
/// look. One file per project under `Application Support/Houston/inbox/
/// policy/`. Everything defaults to the quiet side: automation OFF,
/// and when it's on, every threshold is set so the ordinary small PR
/// clears and anything with blast radius doesn't.
struct ReviewPolicy: Codable, Equatable {
    /// Review every open PR's head on its own, as it appears or moves.
    var autoReview = false
    /// The reviewer: a Claude model flag (nil = the CLI's default).
    var model: String?
    var modelLabel = "Default"
    /// A second model reviews independently; disagreement escalates.
    var secondOpinion = false
    var secondModel: String?
    var secondModelLabel = "Default"
    var skipDrafts = true
    /// A PR changing more lines than this is never auto-reviewed; it
    /// goes straight to "needs you".
    var maxDiffLines = 400
    /// A verdict at or above this risk needs you.
    var escalateRisk = 4
    /// A verdict under this confidence needs you.
    var minConfidence = 70
    /// Any changed path containing one of these (case-insensitive)
    /// needs you regardless of the verdict.
    var sensitivePaths = [
        "migration", "auth", "payment", "billing", "secret", ".github/workflows",
        "Package.swift", "package.json", "Dockerfile",
    ]
    /// Failing or pending checks keep a PR from clearing.
    var requireChecksGreen = true
    /// Banner + bell when a PR needs you.
    var notify = true

    static let `default` = ReviewPolicy()

    var reviewer: PullReviewStore.Model { .init(label: modelLabel, arg: model) }
    var secondReviewer: PullReviewStore.Model { .init(label: secondModelLabel, arg: secondModel) }
}

@MainActor
final class ReviewPolicyStore: ObservableObject {
    static let shared = ReviewPolicyStore()

    @Published private(set) var policies: [String: ReviewPolicy] = [:]
    private var loaded: Set<String> = []

    func policy(for project: String) -> ReviewPolicy {
        load(project)
        return policies[project] ?? .default
    }

    func set(_ policy: ReviewPolicy, for project: String) {
        policies[project] = policy
        Self.write(project, policy)
    }

    private func load(_ project: String) {
        guard !loaded.contains(project) else { return }
        loaded.insert(project)
        if let saved = Self.read(project) { policies[project] = saved }
    }

    private static var dir: String {
        ("~/Library/Application Support/Houston/inbox/policy" as String).expandingTildePath
    }

    private static func path(_ project: String) -> String {
        dir + "/" + String(project.map { $0.isLetter || $0.isNumber ? $0 : "-" }) + ".json"
    }

    private static func read(_ project: String) -> ReviewPolicy? {
        guard let data = FileManager.default.contents(atPath: path(project)) else { return nil }
        return try? JSONDecoder().decode(ReviewPolicy.self, from: data)
    }

    private static func write(_ project: String, _ policy: ReviewPolicy) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(policy) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(project)), options: .atomic)
    }
}

/// Where one PR stands against the policy.
struct Triage: Equatable {
    enum State: Equatable {
        /// Automation is off and nobody has reviewed it.
        case none
        /// Waiting for its turn (auto-review on, no run for this head yet).
        case waiting
        case reviewing
        /// Every rule passed.
        case clear
        case needsYou
    }
    let state: State
    /// Plain sentences, one per rule that fired (needsYou) — or, for
    /// `clear`, one line on what cleared it.
    let reasons: [String]
    let headSHA: String?

    static let none = Triage(state: .none, reasons: [], headSHA: nil)

    /// The key an escalation is remembered by: this head, these reasons.
    var escalationKey: String { (headSHA ?? "?") + "|" + reasons.joined(separator: "|") }
}

/// The rules. Pure: given what's known about a PR, say where it
/// stands. Thresholds are measured on what the REVIEW saw (numstat
/// from the worktree), not on GitHub's counters, so a verdict and the
/// rules that judge it always describe the same commit.
enum TriageEngine {
    static func triage(
        item: InboxItem, detail: PullRequestDetail?, runs: [ReviewRun],
        live: Bool, policy: ReviewPolicy
    ) -> Triage {
        guard item.isPullRequest else { return .none }
        let head = item.headSHA
        // Runs of THIS head; without a known head, the latest run stands in.
        let relevant: [ReviewRun] = {
            guard let head else { return Array(runs.prefix(1)) }
            return runs.filter { $0.headSHA == head }
        }()
        let first = relevant.first { $0.model == policy.reviewer.label || !policy.secondOpinion }
            ?? relevant.first
        let second = policy.secondOpinion
            ? relevant.first { $0.model == policy.secondReviewer.label && $0.id != first?.id }
            : nil

        if live {
            return Triage(state: .reviewing, reasons: [], headSHA: head)
        }
        guard let first else {
            return Triage(state: policy.autoReview ? .waiting : .none, reasons: [], headSHA: head)
        }

        var reasons: [String] = []
        if let skipped = first.skipped {
            reasons.append(skipped)
        }
        if let error = first.error, first.verdict == nil, first.skipped == nil {
            reasons.append("The review failed: " + error.split(separator: "\n").first.map(String.init).orEmpty)
        }
        if let lines = first.linesChanged, first.skipped == nil, lines > policy.maxDiffLines {
            reasons.append("\(lines) lines changed, over your \(policy.maxDiffLines)-line limit.")
        }
        if let paths = first.changedPaths {
            let hits = paths.filter { path in
                policy.sensitivePaths.contains { !$0.isEmpty && path.localizedCaseInsensitiveContains($0) }
            }
            if !hits.isEmpty {
                let shown = hits.prefix(3).joined(separator: ", ") + (hits.count > 3 ? " and \(hits.count - 3) more" : "")
                reasons.append("Touches a sensitive path: \(shown).")
            }
        }
        if let v = first.verdict {
            switch v.decision {
            case .needsHuman:
                reasons.append(contentsOf: v.humanReasons.isEmpty ? ["The reviewer asked for a person."] : v.humanReasons)
            case .requestChanges:
                let blockers = v.findings.filter { $0.severity == .blocker || $0.severity == .major }.count
                reasons.append("Changes requested: \(blockers) serious finding\(blockers == 1 ? "" : "s").")
            case .approve, .comment:
                break
            }
            if v.risk >= policy.escalateRisk {
                reasons.append("Risk \(v.risk)/5, at or above your \(policy.escalateRisk) line.")
            }
            if v.confidence < policy.minConfidence {
                reasons.append("The reviewer is only \(v.confidence)% sure (you asked for \(policy.minConfidence)%).")
            }
        }
        if policy.secondOpinion {
            if let second, let a = first.verdict, let b = second.verdict {
                if !agree(a.decision, b.decision) {
                    reasons.append("The models disagree: \(first.model) says \(a.decision.words.lowercased()), \(second.model) says \(b.decision.words.lowercased()).")
                }
            } else if second == nil, first.skipped == nil {
                // Waiting on the second reviewer.
                return Triage(state: .waiting, reasons: [], headSHA: head)
            }
        }
        if policy.requireChecksGreen, let checks = detail?.checks {
            if checks.failed > 0 { reasons.append("\(checks.failed) check\(checks.failed == 1 ? "" : "s") failing.") }
            else if checks.pending > 0 { reasons.append("\(checks.pending) check\(checks.pending == 1 ? "" : "s") still running.") }
        }
        if let state = detail?.mergeableState, state == "dirty" {
            reasons.append("Has merge conflicts.")
        }

        if reasons.isEmpty {
            var line = "\(first.model) says \(first.verdict?.decision.words.lowercased() ?? "nothing")"
            if let second, let b = second.verdict { line += "; \(second.model) says \(b.decision.words.lowercased())" }
            if let v = first.verdict { line += " · risk \(v.risk)/5 · \(v.confidence)% sure" }
            return Triage(state: .clear, reasons: [line + "."], headSHA: head)
        }
        return Triage(state: .needsYou, reasons: reasons, headSHA: head)
    }

    /// approve/comment agree with each other; request_changes/needs_human
    /// agree with each other; across the line they don't.
    static func agree(_ a: ReviewVerdict.Decision, _ b: ReviewVerdict.Decision) -> Bool {
        func fine(_ d: ReviewVerdict.Decision) -> Bool { d == .approve || d == .comment }
        return fine(a) == fine(b)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// The automation (2026-11-04): watches the Inbox, the review runs and
/// the policies; keeps a `Triage` per PR; starts the reviews the policy
/// asks for (one at a time, so a burst of PRs can't stampede the rate
/// limits); and escalates a PR that needs you ONCE per head+reasons —
/// bell feed + banner — remembered on disk so a relaunch doesn't
/// re-ring. Nothing here touches GitHub.
@MainActor
final class InboxTriageStore: ObservableObject {
    static let shared = InboxTriageStore()

    /// project → number → triage.
    @Published private(set) var triage: [String: [Int: Triage]] = [:]
    @Published private(set) var needsYouCount = 0

    private let inbox = GitHubInboxStore.shared
    private let reviews = PullReviewStore.shared
    private let policies = ReviewPolicyStore.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var escalated: Set<String> = InboxTriageStore.readEscalated()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Publishers.Merge3(
            inbox.objectWillChange.map { _ in () },
            reviews.objectWillChange.map { _ in () },
            policies.objectWillChange.map { _ in () }
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.recompute() }
        .store(in: &subscriptions)
        recompute()
    }

    func triage(project: String, number: Int) -> Triage {
        triage[project]?[number] ?? .none
    }

    func needsYou(project: String) -> Int {
        (triage[project] ?? [:]).values.filter { $0.state == .needsYou }.count
    }

    func recompute() {
        var next: [String: [Int: Triage]] = [:]
        var count = 0
        for (project, items) in inbox.items {
            guard let repo = inbox.repos[project] else { continue }
            let policy = policies.policy(for: project)
            var perProject: [Int: Triage] = [:]
            for item in items where item.isPullRequest {
                let key = repo.slug + "#" + String(item.number)
                reviews.load(key)
                let t = TriageEngine.triage(
                    item: item, detail: inbox.details[key], runs: reviews.runs[key] ?? [],
                    live: reviews.isRunning(key), policy: policy
                )
                perProject[item.number] = t
                if t.state == .needsYou {
                    count += 1
                    escalateIfNew(project: project, repo: repo, item: item, triage: t, policy: policy)
                }
            }
            next[project] = perProject
            scheduleReviews(project: project, repo: repo, items: items, policy: policy)
        }
        if next != triage { triage = next }
        if count != needsYouCount {
            needsYouCount = count
            NotifyStore.shared.refreshBadge()
        }
    }

    /// One review in flight at a time across every project. Picks the
    /// most recently updated PR that the policy wants looked at.
    private func scheduleReviews(project: String, repo: GitHubRepo, items: [InboxItem], policy: ReviewPolicy) {
        guard policy.autoReview, reviews.live.isEmpty else { return }
        for item in items where item.isPullRequest {
            if policy.skipDrafts, item.draft { continue }
            guard let head = item.headSHA, let base = item.baseRef else { continue }
            let key = repo.slug + "#" + String(item.number)
            let runs = (reviews.runs[key] ?? []).filter { $0.headSHA == head }
            let wanted: PullReviewStore.Model? = {
                if !runs.contains(where: { $0.model == policy.reviewer.label }) { return policy.reviewer }
                if policy.secondOpinion,
                   !runs.contains(where: { $0.skipped != nil }),  // a skip needs no second opinion
                   !runs.contains(where: { $0.model == policy.secondReviewer.label }) { return policy.secondReviewer }
                return nil
            }()
            guard let wanted else { continue }
            // A head that already failed twice is left alone — the
            // failure is in the triage, retrying burns money.
            if runs.filter({ $0.error != nil && $0.model == wanted.label }).count >= 2 { continue }
            reviews.start(
                project: project, repo: repo, item: item, baseRef: base, model: wanted,
                maxLines: policy.maxDiffLines
            )
            return
        }
    }

    private func escalateIfNew(project: String, repo: GitHubRepo, item: InboxItem, triage: Triage, policy: ReviewPolicy) {
        let key = repo.slug + "#" + String(item.number) + "|" + triage.escalationKey
        guard !escalated.contains(key) else { return }
        escalated.insert(key)
        Self.writeEscalated(escalated)
        guard policy.notify else { return }
        let detail = triage.reasons.joined(separator: " ")
        EventFeed.shared.post(
            .inboxNeedsYou, title: "#\(item.number) " + item.title, detail: detail,
            projectPath: project, inboxNumber: item.number
        )
        NotifyStore.shared.deliverInboxBanner(
            project: project, number: item.number,
            title: "PR #\(item.number) needs you · " + (project as NSString).lastPathComponent,
            body: item.title + "\n" + detail
        )
    }

    // MARK: disk

    private static var escalatedPath: String {
        ("~/Library/Application Support/Houston/inbox/escalated.json" as String).expandingTildePath
    }

    private static func readEscalated() -> Set<String> {
        guard let data = FileManager.default.contents(atPath: escalatedPath),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func writeEscalated(_ set: Set<String>) {
        // Bounded: the newest 500 keys are plenty to stop re-ringing.
        let list = Array(set.sorted().suffix(500))
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: URL(fileURLWithPath: escalatedPath), options: .atomic)
    }
}
