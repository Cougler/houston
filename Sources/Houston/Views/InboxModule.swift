import AppKit
import SwiftUI

/// The Inbox workspace module (2026-11-04): the repo's open pull
/// requests and issues, read through the user's `gh` login. The rows
/// render the same in both of the module's homes (side-panel card, bar
/// dropdown); a click opens the item as the workspace surface
/// (`InboxItemView`), beside chat, terminal and documents.
struct InboxModuleRows: View {
    let project: String
    @ObservedObject var store: GitHubInboxStore
    @ObservedObject private var triage = InboxTriageStore.shared
    /// The item open as the surface, if any.
    let selectedNumber: Int?
    let onOpen: (InboxItem) -> Void

    var body: some View {
        let items = store.items(for: project)
        let pulls = items.filter(\.isPullRequest)
        let issues = items.filter { !$0.isPullRequest }
        switch store.status(for: project) {
        case .notGitHub:
            InboxNote("This project's origin isn't on GitHub.")
        case let .needsGH(message):
            InboxNote(message)
            InboxNote("Sign in with `gh auth login` in a terminal; the list fills in on its own.")
        case let .failed(message) where items.isEmpty:
            InboxNote(message)
        case .loading where items.isEmpty:
            InboxNote("Loading…")
        default:
            if items.isEmpty {
                InboxNote("Nothing open. Inbox zero.")
            }
            if !pulls.isEmpty {
                InboxGroupLabel(title: "PULL REQUESTS · \(pulls.count)")
                ForEach(pulls) { row($0) }
            }
            if !issues.isEmpty {
                InboxGroupLabel(title: "ISSUES · \(issues.count)")
                ForEach(issues) { row($0) }
            }
        }
    }

    private func row(_ item: InboxItem) -> some View {
        InboxRow(
            item: item, triage: triage.triage(project: project, number: item.number).state,
            selected: selectedNumber == item.number
        ) { onOpen(item) }
    }
}

private struct InboxRow: View {
    let item: InboxItem
    var triage: Triage.State = .none
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            LucideIcon(item.isPullRequest ? "git-pull-request" : "circle-dot", size: 13)
                .foregroundStyle(item.draft ? Theme.textSecondary
                    : item.isPullRequest ? Theme.dotActive : Theme.textPositive)
            Text(item.title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            switch triage {
            case .needsYou:
                LucideIcon("triangle-alert", size: 12).foregroundStyle(Theme.dotDegraded)
            case .clear:
                LucideIcon("check", size: 12).foregroundStyle(Theme.dotActive)
            case .reviewing:
                Circle().fill(Theme.dotActive).frame(width: 6, height: 6)
            case .waiting, .none:
                EmptyView()
            }
            Text("#\(item.number)")
                .font(Theme.Fonts.secondary)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(selected ? Theme.rowSelected : hovered ? Theme.rowHovered : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
        .help(item.title)
    }
}

private struct InboxGroupLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
            .padding(.leading, 8)
            .padding(.top, 6)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InboxNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An issue or pull request as the workspace surface: title line, the
/// facts (author, age, labels; for a PR size, checks, reviews, merge
/// state), the body, the conversation, and for a PR every changed
/// file's diff. Read-only — the only outward action is the link to
/// GitHub.
struct InboxItemView: View {
    let project: String
    let number: Int
    @ObservedObject var store: GitHubInboxStore
    let onClose: () -> Void

    private var item: InboxItem? { store.item(project: project, number: number) }
    private var key: String? { store.detailKey(project: project, number: number) }
    private var detail: PullRequestDetail? { key.flatMap { store.details[$0] } }
    private var comments: [InboxComment]? { key.flatMap { store.comments[$0] } }
    private var error: String? { key.flatMap { store.detailErrors[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.borderSidebar).frame(height: 1)
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        facts(item)
                        if let detail { pullFacts(detail) }
                        if item.isPullRequest {
                            InboxTriageLine(project: project, item: item)
                        }
                        if let detail, let repo = store.repos[project], item.isPullRequest {
                            PullReviewSection(project: project, repo: repo, item: item, detail: detail)
                        }
                        if let error {
                            Text(error)
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textDanger)
                        }
                        if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownBlockView(text: item.body, color: Theme.chatProse)
                        } else {
                            Text("No description.")
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        conversation
                        if let detail, !detail.files.isEmpty {
                            changes(detail)
                        } else if item.isPullRequest, detail == nil, error == nil {
                            Text("Loading the diff…")
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            } else {
                Text("This item is no longer open.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .task(id: number) { store.loadDetail(project: project, number: number) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.title ?? "#\(number)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let item {
                PanelControlButton(icon: "refresh-cw", help: "Refresh") {
                    store.refresh(project)
                    store.loadDetail(project: project, number: number, force: true)
                }
                PanelControlButton(icon: "external-link", help: "Open on GitHub") {
                    if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
                }
            }
            PanelControlButton(icon: "x", help: "Back to chat", action: onClose)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        guard let item else { return "" }
        let kind = item.isPullRequest ? (item.draft ? "Draft pull request" : "Pull request") : "Issue"
        var s = "\(kind) #\(item.number)"
        if let repo = store.repos[project] { s += " · " + repo.slug }
        return s
    }

    private func facts(_ item: InboxItem) -> some View {
        HStack(spacing: 10) {
            Text(item.author)
                .font(Theme.Fonts.secondaryMedium)
                .foregroundStyle(Theme.text)
            Text("opened " + Self.age(item.createdAt))
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
            if item.updatedAt.timeIntervalSince(item.createdAt) > 3600 {
                Text("updated " + Self.age(item.updatedAt))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            if item.commentCount > 0 {
                HStack(spacing: 3) {
                    LucideIcon("message-circle", size: 12)
                    Text(String(item.commentCount)).monospacedDigit()
                }
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
            }
            ForEach(item.labels, id: \.self) { label in
                Text(label)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.controlChip))
            }
            Spacer(minLength: 0)
        }
    }

    private func pullFacts(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(detail.headRef).font(Theme.Fonts.mono)
                LucideIcon("chevron-right", size: 11)
                Text(detail.baseRef).font(Theme.Fonts.mono)
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                DiffCounts(added: detail.additions, removed: detail.deletions)
                Text("\(detail.changedFiles) file\(detail.changedFiles == 1 ? "" : "s")")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let checks = detail.checks {
                fact(
                    icon: checks.failed > 0 ? "circle-alert" : checks.pending > 0 ? "clock" : "circle-check",
                    text: checks.failed > 0
                        ? "\(checks.failed) of \(checks.total) checks failed"
                        : checks.pending > 0
                            ? "\(checks.pending) of \(checks.total) checks running"
                            : "\(checks.total) checks passed",
                    color: checks.failed > 0 ? Theme.textDanger
                        : checks.pending > 0 ? Theme.textWarning : Theme.textPositive
                )
            }
            if !detail.reviews.isEmpty {
                let approved = detail.reviews.filter { $0.state == "APPROVED" }.count
                let changes = detail.reviews.filter { $0.state == "CHANGES_REQUESTED" }.count
                if changes > 0 {
                    fact(icon: "circle-alert", text: "changes requested", color: Theme.textWarning)
                } else if approved > 0 {
                    fact(icon: "check", text: "\(approved) approved", color: Theme.textPositive)
                }
            }
            fact(
                icon: "git-merge",
                text: Self.mergeWords(detail.mergeableState),
                color: detail.mergeableState == "clean" ? Theme.textPositive
                    : detail.mergeableState == "dirty" ? Theme.textDanger : Theme.textSecondary
            )
            Spacer(minLength: 0)
        }
    }

    private func fact(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            LucideIcon(icon, size: 12)
            Text(text)
        }
        .font(Theme.Fonts.secondary)
        .foregroundStyle(color)
    }

    @ViewBuilder
    private var conversation: some View {
        if let comments, !comments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("CONVERSATION · \(comments.count)")
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(comment.author)
                                .font(Theme.Fonts.secondaryMedium)
                                .foregroundStyle(Theme.text)
                            Text(Self.age(comment.createdAt))
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        MarkdownBlockView(text: comment.body, color: Theme.chatProse)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .fill(Theme.sidebarFill)
                    )
                }
            }
        }
    }

    private func changes(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("CHANGES · \(detail.files.count) file\(detail.files.count == 1 ? "" : "s")")
            ForEach(detail.files) { file in
                DiffView(diff: file.diff, path: file.path)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .fill(Theme.sidebarFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusFloat)
                            .stroke(Theme.buttonStroke, lineWidth: 1)
                    )
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
    }

    static func mergeWords(_ state: String) -> String {
        switch state {
        case "clean": "ready to merge"
        case "dirty": "has conflicts"
        case "blocked": "waiting on checks or review"
        case "unstable": "checks failing"
        case "behind": "behind the base branch"
        case "draft": "draft"
        default: "merge state unknown"
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func age(_ date: Date) -> String {
        guard date != .distantPast else { return "" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

/// The PR page's REVIEW section (phase 2, 2026-11-04): pick a Claude
/// model, run one read-only review in a throwaway worktree, read the
/// verdict. Nothing leaves the Mac except the model call itself.
struct PullReviewSection: View {
    let project: String
    let repo: GitHubRepo
    let item: InboxItem
    let detail: PullRequestDetail
    @ObservedObject private var store = PullReviewStore.shared
    @State private var model: ChatModelChoice? = nil

    private var key: String { repo.slug + "#" + String(item.number) }
    private var choice: ChatModelChoice? { model ?? ChatModelChoice.claude.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                InboxSectionLabel("REVIEW")
                Spacer(minLength: 8)
                modelMenu
                ApprovalButton(
                    label: store.latest(key) == nil ? "Review this PR" : "Review again",
                    primary: true,
                    enabled: !store.isRunning(key)
                ) { start() }
            }
            if let live = store.live[key] {
                ReviewRunningRow(live: live) { store.cancel(key) }
            } else if let run = store.latest(key) {
                ReviewVerdictCard(run: run)
                if let count = store.runs[key]?.count, count > 1 {
                    Text("\(count - 1) earlier review\(count == 2 ? "" : "s") of this PR on disk.")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("One model reads the pull request in a throwaway worktree and reports here. "
                     + "It can't edit, run, or post anything.")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(Theme.sidebarFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusFloat).stroke(Theme.buttonStroke, lineWidth: 1))
        .onAppear { store.load(key) }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(ChatModelChoice.claude, id: \.self) { m in
                Button(m.label) { model = m }
            }
        } label: {
            HStack(spacing: 5) {
                Text(choice?.label ?? "Model")
                    .font(.system(size: 11, weight: .medium))
                LucideIcon("chevron-down", size: 10)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.controlChip))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(store.isRunning(key))
    }

    private func start() {
        guard let choice else { return }
        store.start(
            project: project, repo: repo, item: item, baseRef: detail.baseRef,
            model: .init(label: choice.label, arg: choice.arg)
        )
    }
}

private struct InboxSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
    }
}

private struct ReviewRunningRow: View {
    let live: LiveReview
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LiquidThinkingView()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: live.startedAt, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text(live.activity + "…")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if let tokens = live.thinkingTokens, tokens > 0 {
                            Text("thinking · \(formatTokens(tokens))")
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(Self.elapsed(since: live.startedAt, now: context.date))
                            .font(Theme.Fonts.secondary)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                ApprovalButton(label: "Stop", action: onStop)
            }
            if !live.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(live.steps.suffix(5).enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 38)
            }
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

/// A finished run: the verdict, or why there isn't one.
struct ReviewVerdictCard: View {
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let verdict = run.verdict {
                HStack(spacing: 8) {
                    Text(verdict.decision.words)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(Self.color(verdict.decision)))
                    Text("risk \(verdict.risk)/5")
                        .foregroundStyle(verdict.risk >= 4 ? Theme.textDanger : verdict.risk == 3 ? Theme.textWarning : Theme.textSecondary)
                    Text("confidence \(verdict.confidence)%")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    CopyIconButton(text: verdict.markdown(model: run.model), help: "Copy the review as markdown")
                }
                .font(Theme.Fonts.secondary)
                Text(verdict.summary)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.chatProse)
                    .fixedSize(horizontal: false, vertical: true)
                if !verdict.humanReasons.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(verdict.humanReasons, id: \.self) { reason in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                LucideIcon("triangle-alert", size: 12)
                                    .foregroundStyle(Theme.textWarning)
                                Text(reason)
                                    .font(Theme.Fonts.body)
                                    .foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !verdict.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(verdict.findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(finding.severity.rawValue)
                                        .font(Theme.Fonts.meta)
                                        .foregroundStyle(Self.color(finding.severity))
                                        .padding(.horizontal, 5)
                                        .frame(height: 16)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.controlChip))
                                    if let file = finding.file {
                                        Text(file + (finding.line.map { ":\($0)" } ?? ""))
                                            .font(Theme.Fonts.monoSmall)
                                            .foregroundStyle(Theme.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }
                                Text(finding.title)
                                    .font(Theme.Fonts.bodyMedium)
                                    .foregroundStyle(Theme.text)
                                Text(finding.detail)
                                    .font(Theme.Fonts.body)
                                    .foregroundStyle(Theme.chatProse)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                Text(run.error ?? "The review ended without a verdict.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(run.model)
            if let ms = run.durationMs { Text("·"); Text(ms < 60_000 ? "\(ms / 1000)s" : "\(ms / 60_000)m \((ms / 1000) % 60)s") }
            if let cost = run.costUSD { Text("·"); Text(String(format: "$%.2f", cost)) }
            if !run.steps.isEmpty { Text("·"); Text("\(run.steps.count) step\(run.steps.count == 1 ? "" : "s")") }
            if !run.headSHA.isEmpty { Text("·"); Text("reviewed " + String(run.headSHA.prefix(7))).font(Theme.Fonts.monoSmall) }
            Text("·"); Text(InboxItemView.age(run.startedAt))
        }
        .font(Theme.Fonts.meta)
        .foregroundStyle(Theme.textSecondary)
    }

    static func color(_ decision: ReviewVerdict.Decision) -> Color {
        switch decision {
        case .approve: Theme.dotActive
        case .requestChanges: Theme.closeRed
        case .comment: Theme.dotIdle
        case .needsHuman: Theme.dotDegraded
        }
    }

    static func color(_ severity: ReviewVerdict.Finding.Severity) -> Color {
        switch severity {
        case .blocker, .major: Theme.textDanger
        case .minor: Theme.textWarning
        case .nit: Theme.textSecondary
        }
    }
}

/// The INBOX module's last row: the policy in one line, click → the
/// AUTOMATION sheet.
struct InboxAutomationRow: View {
    let project: String
    let action: () -> Void
    @ObservedObject private var policies = ReviewPolicyStore.shared
    @ObservedObject private var triage = InboxTriageStore.shared
    @State private var hovered = false

    private var line: String {
        let policy = policies.policy(for: project)
        guard policy.autoReview else { return "Automation off" }
        let needs = triage.needsYou(project: project)
        var s = "Reviewing new PRs"
        if policy.secondOpinion { s += ", two models" }
        if needs > 0 { s += " · \(needs) need\(needs == 1 ? "s" : "") you" }
        return s
    }

    var body: some View {
        HStack(spacing: 7) {
            LucideIcon("settings-2", size: 13)
                .foregroundStyle(Theme.textSecondary)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            LucideIcon("chevron-right", size: 12)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(hovered ? Theme.rowHovered : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

/// Where a PR stands against the policy, above its review: the rules
/// that fired, or the line that cleared it — and "Work on it", which
/// checks the PR out into a kept worktree and selects it.
struct InboxTriageLine: View {
    let project: String
    let item: InboxItem
    @ObservedObject private var triage = InboxTriageStore.shared

    var body: some View {
        let t = triage.triage(project: project, number: item.number)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                switch t.state {
                case .needsYou:
                    HStack(spacing: 6) {
                        LucideIcon("triangle-alert", size: 13).foregroundStyle(Theme.dotDegraded)
                        Text("Needs you").font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.text)
                    }
                    ForEach(t.reasons, id: \.self) { reason in
                        Text("· " + reason)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .clear:
                    HStack(spacing: 6) {
                        LucideIcon("circle-check", size: 13).foregroundStyle(Theme.textPositive)
                        Text("Clear").font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.text)
                        Text(t.reasons.first ?? "").font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                    }
                case .reviewing:
                    HStack(spacing: 6) {
                        Circle().fill(Theme.dotActive).frame(width: 6, height: 6)
                        Text("Being reviewed").font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                    }
                case .waiting:
                    Text("Waiting for its automatic review.").font(Theme.Fonts.secondary).foregroundStyle(Theme.textSecondary)
                case .none:
                    EmptyView()
                }
            }
            Spacer(minLength: 8)
            ApprovalButton(label: "Work on it") {
                NotificationCenter.default.post(
                    name: .houstonWorkOnPull, object: nil,
                    userInfo: ["path": project, "number": item.number]
                )
            }
            .help("Check this pull request out into its own worktree beside the project and open it")
        }
    }
}

/// The AUTOMATION sheet: one project's `ReviewPolicy`, every rule in
/// words. Edits save on change.
struct InboxPolicyPanel: View {
    let project: String
    @ObservedObject private var policies = ReviewPolicyStore.shared
    @ObservedObject private var triage = InboxTriageStore.shared
    @State private var policy: ReviewPolicy = .default
    @State private var pathsDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text((project as NSString).lastPathComponent)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.text)
                Text("What Houston does with this repo's pull requests on its own, and when it stops and asks you. "
                     + "It never posts to GitHub.")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                group("REVIEW") {
                    toggle("Review new pull requests automatically", $policy.autoReview,
                           "Each open PR's head is reviewed once, as it appears or moves. One at a time.")
                    modelRow("Reviewer", label: $policy.modelLabel, arg: $policy.model)
                    toggle("Ask a second model too", $policy.secondOpinion,
                           "An independent second review. When the two disagree, the PR needs you.")
                    if policy.secondOpinion {
                        modelRow("Second reviewer", label: $policy.secondModelLabel, arg: $policy.secondModel)
                    }
                    toggle("Skip drafts", $policy.skipDrafts, nil)
                }

                group("NEEDS YOU WHEN") {
                    number("More than", $policy.maxDiffLines, "lines change", step: 50,
                           "Bigger PRs aren't reviewed automatically; they come straight to you.")
                    number("Risk is", $policy.escalateRisk, "of 5 or higher", step: 1, range: 1...5, nil)
                    number("The reviewer is under", $policy.minConfidence, "% sure", step: 5, range: 0...100, nil)
                    toggle("Checks aren't green", $policy.requireChecksGreen, nil)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A changed path contains any of")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                        TextEditor(text: $pathsDraft)
                            .font(Theme.Fonts.mono)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 70)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.controlChip))
                            .onChange(of: pathsDraft) { _, text in
                                policy.sensitivePaths = text
                                    .split(whereSeparator: { $0 == "\n" || $0 == "," })
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                        Text("One per line. Matched anywhere in the path, case doesn't matter.")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                group("WHEN A PR NEEDS YOU") {
                    toggle("Show a notification", $policy.notify,
                           "A banner (packaged builds) and the menubar dot. The Inbox marks it either way.")
                }

                let needs = triage.needsYou(project: project)
                if needs > 0 {
                    Text("\(needs) pull request\(needs == 1 ? "" : "s") need\(needs == 1 ? "s" : "") you right now.")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textWarning)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            policy = policies.policy(for: project)
            pathsDraft = policy.sensitivePaths.joined(separator: "\n")
        }
        .onChange(of: policy) { _, new in
            if new != policies.policy(for: project) { policies.set(new, for: project) }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.heading)
            content()
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>, _ help: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: binding) {
                Text(title).font(Theme.Fonts.body).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if let help {
                Text(help)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func number(
        _ lead: String, _ binding: Binding<Int>, _ trail: String,
        step: Int, range: ClosedRange<Int> = 0...100_000, _ help: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(lead).font(Theme.Fonts.body).foregroundStyle(Theme.text)
                Stepper(value: binding, in: range, step: step) {
                    Text(String(binding.wrappedValue))
                        .font(Theme.Fonts.bodyMedium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .controlSize(.small)
                Text(trail).font(Theme.Fonts.body).foregroundStyle(Theme.text)
            }
            if let help {
                Text(help)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelRow(_ title: String, label: Binding<String>, arg: Binding<String?>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Fonts.body).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Menu {
                Button("Default (the CLI's)") { label.wrappedValue = "Default"; arg.wrappedValue = nil }
                Divider()
                ForEach(ChatModelChoice.claude, id: \.self) { m in
                    Button(m.label) { label.wrappedValue = m.label; arg.wrappedValue = m.arg }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(label.wrappedValue).font(.system(size: 11, weight: .medium))
                    LucideIcon("chevron-down", size: 10)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl).fill(Theme.controlChip))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}
