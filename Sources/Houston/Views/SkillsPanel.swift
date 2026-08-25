import SwiftUI

/// Floating card over the terminal listing the skills a session can use.
///
/// Houston's bundled mission skills lead under their own label; everything
/// else follows alphabetically. Each row's play button runs the skill
/// immediately (`/name` + Return); clicking anywhere else pushes a detail
/// page inside the card with a fuller explanation and action controls.
struct SkillsPanel: View {
    let skills: [Skill]
    /// Executes the skill now — `/name` with a Return.
    let onRun: (Skill) -> Void
    /// Types `/name ` and leaves the prompt to the user (for arguments).
    let onInsert: (Skill) -> Void

    /// The pushed detail page, when a skill is open.
    @State private var selected: Skill?

    private var houstonSkills: [Skill] {
        // Lifecycle order, not alphabetical.
        HoustonSkills.names.compactMap { name in
            skills.first { $0.name == name }
        }
    }

    private var otherSkills: [Skill] {
        skills.filter { !HoustonSkills.isHouston($0.name) }
    }

    var body: some View {
        Group {
            if let selected {
                SkillDetail(
                    skill: selected,
                    onBack: {
                        withAnimation(.easeOut(duration: 0.18)) { self.selected = nil }
                    },
                    onRun: { onRun(selected) },
                    onInsert: { onInsert(selected) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                // Plain fade: a move-edge here also fires when the whole
                // panel is inserted, making the sheet slide in from the left.
                list
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        // Flat on the sheet's background; clipped so the pushed detail
        // page's slide transition can't escape the strip.
        .clipped()
    }

    private var list: some View {
        // The sheet's controls bar already says SKILLS — no second title.
        Group {
            if skills.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !houstonSkills.isEmpty {
                            sectionLabel("COMES WITH HOUSTON")
                            ForEach(houstonSkills) { skill in
                                row(skill)
                            }
                        }
                        if !otherSkills.isEmpty {
                            sectionLabel("YOUR SKILLS")
                            ForEach(otherSkills) { skill in
                                row(skill)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func row(_ skill: Skill) -> some View {
        SkillRow(
            skill: skill,
            onRun: { onRun(skill) },
            onOpen: {
                withAnimation(.easeOut(duration: 0.18)) { selected = skill }
            }
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.heading)
            .padding(.leading, 2)
            .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No skills found")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Skills live in ~/.claude/skills — one folder per skill with a SKILL.md inside.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open Skills Folder") {
                Actions.openFolder(path: "~/.claude/skills".expandingTildePath)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One list row: play on the left runs the skill, the rest pushes detail.
private struct SkillRow: View {
    let skill: Skill
    let onRun: () -> Void
    let onOpen: () -> Void
    @State private var hovered = false
    @State private var playHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onRun) {
                SVGIcon(name: "rocket", size: 12)
                    .foregroundStyle(playHovered ? Theme.text : Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        // Resting on the row-hover tint, dropping to the
                        // control tint under the pointer — rowSelected was
                        // indistinguishable on an already-tinted row.
                        RoundedRectangle(cornerRadius: 5)
                            .fill(playHovered ? Theme.controlHovered : Theme.rowHovered)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { playHovered = $0 }
            .help("Run /\(skill.name) now")

            Button(action: onOpen) {
                HStack(spacing: 6) {
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
                    Spacer(minLength: 0)
                    if hovered {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.heading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovered ? Theme.controlHovered : Theme.buttonFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .onHover { hovered = $0 }
    }
}

/// The pushed page: what the skill does, plus the ways to fire it.
private struct SkillDetail: View {
    let skill: Skill
    let onBack: () -> Void
    let onRun: () -> Void
    let onInsert: () -> Void
    @State private var backHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Skills")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(backHovered ? Theme.text : Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { backHovered = $0 }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("/" + skill.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if HoustonSkills.isHouston(skill.name) {
                        Text("COMES WITH HOUSTON")
                            .font(.system(size: 8, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.heading)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.buttonFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Theme.buttonStroke, lineWidth: 1)
                            )
                    }
                }

                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let details = HoustonSkills.details(for: skill.name) {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    DetailActionButton(title: "Run Skill", icon: "rocket", action: onRun)
                        .help("Types /\(skill.name) into the session and runs it")
                    DetailActionButton(title: "Type Command", icon: "text.cursor", action: onInsert)
                        .help("Types /\(skill.name) and leaves the prompt open for arguments")
                }
                .padding(.top, 4)

                Button("Reveal in Finder") {
                    Actions.openFolder(path: skill.path)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }
}

/// A detail-page action: same chrome family as the header buttons, panel
/// sized.
private struct DetailActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if icon == "rocket" {
                    SVGIcon(name: "rocket", size: 11)
                        .foregroundStyle(Theme.text.opacity(0.75))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.text.opacity(0.75))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Theme.controlHovered : Theme.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.buttonStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
