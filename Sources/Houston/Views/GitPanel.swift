import SwiftUI

/// Floating card over the terminal showing a project's git state in plain
/// language: the branch, what's changed since the last commit, and the recent
/// commit history with unpushed work marked. Clicking a commit pushes to a
/// detail page (message, author, per-file line counts). Read-only — Houston
/// visualizes; committing stays in the shell (or the agent's hands).
struct GitPanel: View {
    let info: GitInfo?
    let projectPath: String
    /// Runs `git init` in the project's shell (non-repo state only).
    let onInitialize: () -> Void
    /// Types `git switch <branch>` into the project's shell.
    var onSwitchBranch: (String) -> Void = { _ in }
    /// Prompts for a name and creates + switches to it.
    var onNewBranch: () -> Void = {}

    private enum Page: Equatable {
        case list
        case commit(GitCommit)
        case file(GitChange)
    }

    @State private var page: Page = .list
    @State private var detail: GitCommitDetail?
    @State private var diff: [GitDiffLine]?

    var body: some View {
        ZStack {
            switch page {
            case .list:
                listPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case let .commit(commit):
                CommitDetailPage(commit: commit, detail: detail, onBack: goBack)
                    .transition(.move(edge: .trailing))
            case let .file(change):
                FileDiffPage(
                    change: change,
                    diff: diff,
                    onBack: goBack,
                    onOpenInEditor: {
                        Actions.openInEditor(
                            path: (projectPath as NSString)
                                .appendingPathComponent(change.path)
                        )
                    }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.gitPanelFill)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
    }

    private func goBack() {
        withAnimation(.easeOut(duration: 0.18)) {
            page = .list
            detail = nil
            diff = nil
        }
    }

    private func open(_ commit: GitCommit) {
        withAnimation(.easeOut(duration: 0.18)) { page = .commit(commit) }
        let path = projectPath
        Task.detached(priority: .userInitiated) {
            let loaded = GitDetect.commitDetail(sha: commit.sha, in: path)
            await MainActor.run {
                guard page == .commit(commit) else { return }
                detail = loaded
            }
        }
    }

    private func open(_ change: GitChange) {
        withAnimation(.easeOut(duration: 0.18)) { page = .file(change) }
        let path = projectPath
        Task.detached(priority: .userInitiated) {
            let loaded = GitDetect.fileDiff(change: change, in: path)
            await MainActor.run {
                guard page == .file(change) else { return }
                diff = loaded
            }
        }
    }

    // MARK: - List page

    @ViewBuilder
    private var listPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info {
                if info.isRepo {
                    repoContent(info)
                } else {
                    notARepo
                }
            } else {
                Text("Reading git status…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func repoContent(_ info: GitInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Branch switcher: local branches plus New Branch…
                Menu {
                    ForEach(info.branches, id: \.self) { branch in
                        Button {
                            if branch != info.branchLabel { onSwitchBranch(branch) }
                        } label: {
                            if branch == info.branchLabel {
                                Label(branch, systemImage: "checkmark")
                            } else {
                                Text(branch)
                            }
                        }
                    }
                    if !info.branches.isEmpty { Divider() }
                    Button("New Branch…") { onNewBranch() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                        Text(info.branchLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Switch or create a branch")
                Spacer(minLength: 0)
                if let remote = info.remoteURL {
                    HoverArrowButton(help: "Open on the remote") {
                        Actions.openExternal(remote)
                    }
                }
            }
            if !info.headerSubtext.isEmpty {
                Text(info.headerSubtext)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !info.changes.isEmpty {
                    GitSectionLabel(
                        title: "UNCOMMITTED",
                        subtext: "\(info.changes.count) uncommitted change\(info.changes.count == 1 ? "" : "s")"
                    )
                    ForEach(info.changes) { change in
                        ChangeRow(change: change) { open(change) }
                    }
                    Spacer().frame(height: 12)
                }
                let unpushed = info.commits.filter(\.isUnpushed)
                let synced = info.commits.filter { !$0.isUnpushed }
                if !unpushed.isEmpty {
                    GitSectionLabel(
                        title: "COMMITTED",
                        subtext: "\(unpushed.count) commit\(unpushed.count == 1 ? "" : "s") to push"
                    )
                    ForEach(unpushed) { commit in
                        CommitRow(commit: commit) { open(commit) }
                    }
                    Spacer().frame(height: 12)
                }
                if !synced.isEmpty {
                    GitSectionLabel(
                        title: "SYNCED",
                        subtext: (info.remoteURL?.contains("github.com") ?? false)
                            ? "saved to GitHub" : "saved to the remote"
                    )
                    ForEach(synced) { commit in
                        CommitRow(commit: commit) { open(commit) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private var notARepo: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                Text("Not under version control")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            Text("Git keeps a history of every change in this project, so you can always see what happened and roll anything back.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Initialize Repository") { onInitialize() }
                .font(.system(size: 11))
                .padding(.top, 2)
        }
        .padding(16)
    }
}

// MARK: - Detail page

private struct CommitDetailPage: View {
    let commit: GitCommit
    let detail: GitCommitDetail?
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.heading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(commit.sha)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                if commit.isUnpushed {
                    Text("not pushed")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xD97706))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail?.subject ?? commit.subject)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let body = detail?.body, !body.isEmpty {
                            Text(body)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(byline)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 6)

                    if let detail {
                        VStack(alignment: .leading, spacing: 0) {
                            GitSectionLabel(
                                title: "FILES",
                                subtext: "+\(detail.totalAdded) −\(detail.totalDeleted) "
                                    + "across \(detail.files.count)"
                            )
                            ForEach(detail.files) { file in
                                CommitFileRow(file: file)
                            }
                        }
                    } else {
                        Text("Loading…")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var byline: String {
        guard let detail else { return commit.timeAgo }
        return "\(detail.author) · \(detail.date) (\(commit.timeAgo))"
    }
}

// MARK: - Shared bits

private struct GitSectionLabel: View {
    let title: String
    let subtext: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.heading)
            if !subtext.isEmpty {
                Text(subtext)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 5)
    }
}

private func kindWord(_ kind: GitChange.Kind) -> String {
    switch kind {
    case .modified: "Modified"
    case .added: "Added"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    case .untracked: "New"
    }
}

private struct ChangeRow: View {
    let change: GitChange
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(Theme.dotShell)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.fileName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtext)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(kindWord(change.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.heading.opacity(hovered ? 1 : 0.4))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var subtext: String {
        change.directory.isEmpty
            ? "local changes"
            : "local changes · \(change.directory)"
    }
}

// MARK: - File diff page

private struct FileDiffPage: View {
    let change: GitChange
    let diff: [GitDiffLine]?
    let onBack: () -> Void
    let onOpenInEditor: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.heading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(kindWord(change.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                // A deleted file has nothing to open.
                if change.kind != .deleted {
                    HoverArrowButton(help: "Open in editor") { onOpenInEditor() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(change.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let diff {
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            } else {
                Text("Loading diff…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func color(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: Color(hex: 0x16A34A)
        case .removed: Theme.closeRed
        case .context: Theme.textSecondary
        case .hunk: Theme.dotServer
        case .note: Theme.heading
        }
    }
}

private struct CommitFileRow: View {
    let file: GitCommitFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(file.fileName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if !file.directory.isEmpty {
                Text(file.directory)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let added = file.added, let deleted = file.deleted {
                Text("+\(added)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x16A34A))
                Text("−\(deleted)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.closeRed)
            }
            Text(kindWord(file.kind))
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(commit.isUnpushed ? Color(hex: 0xD97706) : Theme.dotActive)
                    .frame(width: 6, height: 6)
                    .help(commit.isUnpushed ? "Not pushed yet" : "On the remote")
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(commit.timeAgo)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.heading.opacity(hovered ? 1 : 0.4))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct HoverArrowButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? Theme.text : Theme.heading)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
