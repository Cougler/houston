import SwiftUI

/// Git in words (2026-10-23). The same four actions in two homes: the
/// chat's "Commit everything now?" card after a turn that edited files
/// (`ChangesCard`), and the Branches module's rows (`GitPlainRows`).
/// Each row says what the action does and what it does NOT do ("nothing
/// leaves your Mac") so a user who doesn't speak git can act without
/// learning it. Runs through `GitActions`; results land inline.

/// The commit step: a suggested subject line to edit, Commit, and
/// Commit & Push when there's somewhere to push to.
struct CommitFlowView: View {
    let path: String
    /// What the change was asked for (the chat prompt) — seeds the
    /// suggested message.
    var hint: String? = nil
    var compact = false
    /// Called with whether a push followed.
    let onCommitted: (_ pushed: Bool) -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @State private var suggesting = true
    @State private var busy = false
    @State private var error: String?
    @State private var hasRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit message")
                .font(Theme.Fonts.label)
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
            TextField(suggesting ? "Suggesting…" : "What changed, in one line", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .lineLimit(1...3)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl)
                        .fill(Theme.attachedWellFill)
                )
                .disabled(busy)
            if let error {
                Text(error)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textDanger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ApprovalButton(label: busy ? "Committing…" : "Commit", primary: true, enabled: canCommit) {
                    commit(push: false)
                }
                if hasRemote {
                    ApprovalButton(label: "Commit & Push", enabled: canCommit) {
                        commit(push: true)
                    }
                    .help("Commit, then send the commits to the remote (GitHub).")
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.secondaryMedium)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(busy)
            }
            if !compact {
                Text("A commit saves a snapshot of the changed files in the project's history on this Mac. Push sends it to the remote.")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: path) {
            let (suggestion, remote) = await Task.detached(priority: .userInitiated) {
                (await GitActions.suggestCommitMessage(in: path, hint: hint),
                 GitActions.hasRemote(in: path))
            }.value
            if message.isEmpty { message = suggestion }
            hasRemote = remote
            suggesting = false
        }
    }

    private var canCommit: Bool {
        !busy && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit(push: Bool) {
        let subject = message.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let committed = GitActions.commitAll(in: path, message: subject)
                guard committed.ok, push else { return committed }
                return GitActions.push(in: path)
            }.value
            busy = false
            if result.ok {
                onCommitted(push)
            } else {
                error = result.output.isEmpty ? "git failed without a message." : result.output
            }
        }
    }
}

/// The chat's card after a turn that edited files: "Claude changed 3
/// files. Commit everything now?" → the commit step → "Push to GitHub?"
/// → done. Dismisses itself on Not now, on done, or on the next send.
struct ChangesCard: View {
    let path: String
    let harness: String
    let fileCount: Int
    var hint: String? = nil
    let onDismiss: () -> Void

    private enum Phase: Equatable { case ask, commit, pushOffer, pushing, done(String) }
    @State private var phase: Phase = .ask
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .ask:
                HStack(spacing: 8) {
                    LucideIcon("git-branch", size: 13)
                    Text("\(harness) changed \(fileCount) file\(fileCount == 1 ? "" : "s"). Commit everything now?")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.text)
                Text("Saves the changed files as one snapshot in the project's history. Nothing leaves your Mac until you push.")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ApprovalButton(label: "Commit…", primary: true) {
                        withAnimation(.easeOut(duration: 0.15)) { phase = .commit }
                    }
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(Theme.Fonts.secondaryMedium)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                }
            case .commit:
                CommitFlowView(
                    path: path, hint: hint, compact: true,
                    onCommitted: { pushed in
                        withAnimation(.easeOut(duration: 0.15)) {
                            phase = pushed ? .done("Committed and pushed.") : .pushOffer
                        }
                    },
                    onCancel: { withAnimation(.easeOut(duration: 0.15)) { phase = .ask } }
                )
            case .pushOffer:
                HStack(spacing: 8) {
                    LucideIcon("circle-check", size: 13).foregroundStyle(Theme.textPositive)
                    Text("Committed. Push to the remote now?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Text("Push sends your commits to GitHub (or wherever the project's remote is) so other machines and people can get them.")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textDanger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ApprovalButton(label: "Push", primary: true) { push() }
                    Button("Later", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(Theme.Fonts.secondaryMedium)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                }
            case .pushing:
                HStack(spacing: 8) {
                    ToolPulse()
                    Text("Pushing…").font(Theme.Fonts.body).foregroundStyle(Theme.textSecondary)
                }
            case let .done(text):
                HStack(spacing: 8) {
                    LucideIcon("circle-check", size: 13).foregroundStyle(Theme.textPositive)
                    Text(text).font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.text)
                }
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    onDismiss()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Theme.sidebarFill.opacity(0.6))
        )
    }

    private func push() {
        phase = .pushing
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { GitActions.push(in: path) }.value
            withAnimation(.easeOut(duration: 0.15)) {
                if result.ok {
                    phase = .done("Pushed.")
                } else {
                    error = result.output
                    phase = .pushOffer
                }
            }
        }
    }
}

/// The Branches module's plain-language rows: what needs doing (changes
/// to commit, commits to push or pull, a branch to merge) and one button
/// each, with a line on what the action does.
struct GitPlainRows: View {
    let path: String
    let info: GitInfo
    let onChanged: () -> Void

    @State private var committing = false
    @State private var busy: String?
    @State private var notice: (text: String, isError: Bool)?
    @State private var defaultBranch: String?

    private var onDefault: Bool {
        defaultBranch == nil || info.branchLabel == defaultBranch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if committing {
                CommitFlowView(
                    path: path,
                    onCommitted: { pushed in
                        committing = false
                        show(pushed ? "Committed and pushed." : "Committed.", error: false)
                        onChanged()
                    },
                    onCancel: { committing = false }
                )
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(Theme.attachedWellFill.opacity(0.6))
                )
            } else {
                if !info.changes.isEmpty {
                    row(
                        title: "\(info.changes.count) changed file\(info.changes.count == 1 ? "" : "s")",
                        detail: "Save them to the project's history. Nothing leaves your Mac.",
                        button: "Commit…", key: "commit"
                    ) { committing = true }
                }
                if info.ahead > 0 {
                    row(
                        title: "\(info.ahead) commit\(info.ahead == 1 ? "" : "s") to push",
                        detail: "Send them to the remote (GitHub) so other machines and people can get them.",
                        button: "Push", key: "push"
                    ) { run("push", { GitActions.push(in: path) }, success: "Pushed.") }
                } else if info.isRepo, !info.hasUpstream, info.changes.isEmpty, !info.commits.isEmpty {
                    row(
                        title: "Not on the remote yet",
                        detail: "Push this branch to the remote so it exists there too.",
                        button: "Push", key: "push"
                    ) { run("push", { GitActions.push(in: path) }, success: "Pushed.") }
                }
                if info.behind > 0 {
                    row(
                        title: "\(info.behind) commit\(info.behind == 1 ? "" : "s") to pull",
                        detail: "Get what was pushed to the remote since your last pull.",
                        button: "Pull", key: "pull"
                    ) { run("pull", { GitActions.pull(in: path) }, success: "Pulled.") }
                }
                if let target = defaultBranch, !onDefault {
                    row(
                        title: "On \(info.branchLabel)",
                        detail: "Bring this branch's commits into \(target). You stay on \(info.branchLabel); nothing is pushed.",
                        button: "Merge into \(target)", key: "merge"
                    ) { merge(into: target) }
                }
                if info.changes.isEmpty, info.ahead == 0, info.behind == 0, onDefault, notice == nil {
                    Text(info.hasUpstream ? "Everything is committed and pushed." : "Everything is committed.")
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                }
            }
            if let notice {
                HStack(alignment: .top, spacing: 6) {
                    LucideIcon(notice.isError ? "circle-x" : "circle-check", size: 12)
                    Text(notice.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Fonts.secondary)
                .foregroundStyle(notice.isError ? Theme.textDanger : Theme.textPositive)
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 4)
        .task(id: path) {
            defaultBranch = await Task.detached(priority: .utility) {
                GitActions.defaultBranch(in: path)
            }.value
        }
    }

    private func row(
        title: String, detail: String, button: String, key: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            ApprovalButton(label: busy == key ? "…" : button, primary: key == "commit", enabled: busy == nil, action: action)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func show(_ text: String, error: Bool) {
        notice = (text, error)
        guard !error else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notice?.text == text { notice = nil }
        }
    }

    private func run(_ key: String, _ work: @escaping @Sendable () -> GitActions.Outcome, success: String) {
        busy = key
        notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated, operation: work).value
            busy = nil
            show(result.ok ? success : (result.output.isEmpty ? "git failed." : result.output), error: !result.ok)
            onChanged()
        }
    }

    private func merge(into target: String) {
        busy = "merge"
        notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                GitActions.mergeIntoDefault(in: path)
            }.value
            busy = nil
            switch result {
            case let .merged(into):
                show("Merged into \(into). Push \(into) from its checkout when you want it on the remote.", error: false)
            case let .conflicts(with):
                show("\(info.branchLabel) conflicts with \(with). Nothing was changed; resolve it in a terminal or ask an agent.", error: true)
            case let .failed(message):
                show(message, error: true)
            }
            onChanged()
        }
    }
}
