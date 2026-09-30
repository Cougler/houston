import AppKit
import SwiftUI

/// The Branches workspace module's rows (2026-09-29, replaces the right
/// sheet's Git panel): the current branch — click for the git menu — a
/// status line, then the repo's worktrees. Rendered the same in both of
/// the item's homes, the top bar dropdown and the side panel card.
struct BranchesModuleRows: View {
    let branch: String?
    let dirty: Bool
    /// "3 changes · 2 to push"; empty hides the line.
    let status: String
    /// Every other checkout of this repo: the main one (when this is a
    /// worktree) and the linked ones.
    let worktrees: [WorktreeRowModel]
    let onBranchMenu: () -> Void
    let onInitialize: () -> Void
    let onOpen: (WorktreeRowModel) -> Void
    let onMerge: (WorktreeRowModel) -> Void
    let onRemove: (WorktreeRowModel) -> Void

    var body: some View {
        if let branch {
            BranchMenuRow(title: branch, dirty: dirty, action: onBranchMenu)
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
            }
            if !worktrees.isEmpty {
                Text("WORKTREES")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.heading)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                ForEach(worktrees) { tree in
                    WorktreeRow(
                        tree: tree,
                        onOpen: { onOpen(tree) },
                        onMerge: { onMerge(tree) },
                        onRemove: { onRemove(tree) }
                    )
                }
            }
        } else {
            BranchMenuRow(
                title: "Initialize repository", dirty: nil, action: onInitialize
            )
            .help("Run git init in this project")
        }
    }
}

struct WorktreeRowModel: Identifiable, Hashable {
    let path: String
    let label: String
    /// The repo's main checkout — opens, but never merges or removes.
    let isMain: Bool
    let dirty: Bool
    var id: String { path }
}

/// The current branch: dot, name, and an up-down chevron saying "this
/// opens a menu" — the row a workspace module leads with.
private struct BranchMenuRow: View {
    let title: String
    /// nil: no dot (the not-a-repo row).
    let dirty: Bool?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if let dirty {
                Circle()
                    .fill(dirty ? Theme.dotDegraded : Theme.dotActive)
                    .frame(width: 6, height: 6)
                    .help(dirty ? "Uncommitted changes" : "Clean")
            }
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(dirty == nil ? Theme.textSecondary : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if dirty != nil {
                LucideIcon("chevrons-up-down", size: 12)
                    .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(hovered ? Theme.rowHovered : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}

/// One worktree: branch glyph + name; hover reveals merge-back and
/// remove for linked worktrees.
private struct WorktreeRow: View {
    let tree: WorktreeRowModel
    let onOpen: () -> Void
    let onMerge: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            LucideIcon(tree.isMain ? "folder" : "git-branch", size: 13)
                .foregroundStyle(Theme.textSecondary)
            Text(tree.label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if tree.dirty {
                Circle().fill(Theme.dotDegraded).frame(width: 6, height: 6)
                    .help("Uncommitted changes")
            }
            Spacer(minLength: 0)
            if hovered, !tree.isMain {
                HStack(spacing: 1) {
                    RowActionIcon(
                        symbol: "git-merge", help: "Merge back and remove", size: 12,
                        action: onMerge
                    )
                    RowActionIcon(
                        symbol: "trash-2", help: "Remove worktree", size: 12,
                        action: onRemove
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(hovered ? Theme.rowHovered : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .help(tree.path)
    }
}

// MARK: - Git command catalog

/// One git command in the branch menu: a plain-language name over the
/// literal command. `%@` marks where prompted input lands.
struct GitCommandSpec {
    let title: String
    let command: String
    /// Prompt (title, message, placeholder) shown before running.
    var input: (title: String, message: String, placeholder: String)? = nil
    /// Destructive: typed into the terminal but NOT executed — the user's
    /// Return keypress is the confirmation.
    var typeOnly = false

    /// The command with `text` spliced in, escaped for shell double quotes.
    func filled(_ text: String) -> String {
        let escaped = text.strippingTerminalControls
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return command.replacingOccurrences(of: "%@", with: escaped)
    }
}

private let commitPrompt: (String, String, String) = (
    "Commit Message", "One line describing what this commit changes.", "what changed"
)

let gitCommandSections: [(title: String, commands: [GitCommandSpec])] = [
    ("Sync", [
        GitCommandSpec(title: "Pull", command: "git pull"),
        GitCommandSpec(title: "Push", command: "git push"),
        GitCommandSpec(title: "Fetch", command: "git fetch --all --prune"),
    ]),
    ("Commit", [
        GitCommandSpec(title: "Stage Everything", command: "git add -A"),
        GitCommandSpec(
            title: "Commit Staged Changes…",
            command: "git commit -m \"%@\"", input: commitPrompt
        ),
        GitCommandSpec(
            title: "Stage + Commit Everything…",
            command: "git add -A && git commit -m \"%@\"", input: commitPrompt
        ),
        GitCommandSpec(title: "Amend Last Commit", command: "git commit --amend --no-edit"),
    ]),
    ("Stash", [
        GitCommandSpec(title: "Stash Changes", command: "git stash push -u"),
        GitCommandSpec(title: "Restore Latest Stash", command: "git stash pop"),
        GitCommandSpec(title: "List Stashes", command: "git stash list"),
    ]),
    ("Undo", [
        GitCommandSpec(title: "Unstage Everything", command: "git reset"),
        GitCommandSpec(
            title: "Undo Last Commit, Keep Changes", command: "git reset --soft HEAD~1"
        ),
        GitCommandSpec(
            title: "Discard All Changes (typed, Return confirms)",
            command: "git restore .", typeOnly: true
        ),
        GitCommandSpec(
            title: "Delete Untracked Files (typed, Return confirms)",
            command: "git clean -fd", typeOnly: true
        ),
    ]),
    ("Inspect", [
        GitCommandSpec(title: "Status", command: "git status"),
        GitCommandSpec(title: "Recent Commits", command: "git log --oneline -15"),
        GitCommandSpec(title: "Unstaged Diff", command: "git diff"),
    ]),
]

extension GitInfo {
    /// The module's one-line status: changes, then the remote's side.
    var moduleStatus: String {
        guard isRepo else { return "" }
        var parts: [String] = []
        if !changes.isEmpty {
            parts.append("\(changes.count) change\(changes.count == 1 ? "" : "s")")
        }
        if ahead > 0 { parts.append("\(ahead) to push") }
        if behind > 0 { parts.append("\(behind) to pull") }
        if parts.isEmpty {
            parts.append(hasUpstream ? "Up to date" : "No remote yet")
        }
        return parts.joined(separator: " · ")
    }
}
