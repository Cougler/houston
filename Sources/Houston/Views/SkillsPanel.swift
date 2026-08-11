import SwiftUI

/// Floating card over the terminal listing the skills a session can use.
/// Picking one types `/name ` into the pane's prompt — arguments (or a bare
/// Return) stay in the user's hands, so skills that expect input aren't fired
/// blind.
struct SkillsPanel: View {
    let skills: [Skill]
    let onPick: (Skill) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Skills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if skills.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(skills) { skill in
                            SkillRow(skill: skill) { onPick(skill) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.panelFill)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No skills found")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Skills live in ~/.claude/skills — one folder per skill with a SKILL.md inside.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Button("Open Skills Folder") {
                Actions.openFolder(path: "~/.claude/skills".expandingTildePath)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

private struct SkillRow: View {
    let skill: Skill
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text("/" + skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovered ? Theme.rowHovered : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
