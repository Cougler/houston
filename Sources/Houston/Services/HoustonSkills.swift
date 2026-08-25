import Foundation

/// The mission-lifecycle skills Houston ships with (bundled under
/// `Resources/skills`): the ones its Start Mission / Mission controls type
/// into a session. Installed into `~/.claude/skills` when missing, so they
/// come with Houston on any machine — never overwriting a user's copy.
///
/// Claude-only for now: the skills are Claude Code slash commands. Extending
/// them to other harnesses means teaching each harness's own command scheme —
/// tracked as an idea, not attempted here.
enum HoustonSkills {

    /// Lifecycle order, which is also their display order in the panel;
    /// non-lifecycle skills (track) follow.
    static let names = ["start-mission", "handoff", "log-mission", "end-mission", "track"]

    static func isHouston(_ name: String) -> Bool { names.contains(name) }

    /// Longer copy for the skill's detail page — what it actually does, in
    /// terms of Houston's workflow.
    static func details(for name: String) -> String? {
        switch name {
        case "start-mission":
            return "Boots a session with full context: reads the project's "
                + "mission log (missionlog.md) for where the last session left "
                + "off, then starts the project's dev server. Houston's Start "
                + "Mission button runs this in a fresh claude session."
        case "handoff":
            return "Briefs the current session from the mission log — where "
                + "things stand, what's next, and what the last session "
                + "couldn't verify — so work continues without re-discovery."
        case "log-mission":
            return "Checkpoints the session: writes the mission-log entry and "
                + "refreshes .mc.json, touching nothing else — no git, no dev "
                + "server. Step one of Houston's Handoff button, which follows "
                + "it with /clear and /handoff to reset the session's context "
                + "without losing state."
        case "end-mission":
            return "Wraps the session: writes a status note and handoff entry "
                + "to the top of missionlog.md, refreshes the project's "
                + ".mc.json notes, and stops the dev server. Run /push first "
                + "to commit and publish the session's changes."
        case "track":
            return "Records a dated obligation — a secret rotation, cert "
                + "renewal, domain expiry — to Houston's tracked list. Say "
                + "\"track …\" in any session; the sidebar footer's bell "
                + "lists what's coming due and badges anything inside its "
                + "lead window."
        default:
            return nil
        }
    }

    /// Copies any bundled skill absent from `~/.claude/skills` into place.
    /// A skill folder the user already has is left untouched — theirs may be
    /// newer or customised.
    static func installMissing() {
        let fm = FileManager.default
        guard let bundled = Bundle.module.resourceURL?
            .appendingPathComponent("skills") else { return }
        let root = NSHomeDirectory() + "/.claude/skills"
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for name in names {
            let destination = "\(root)/\(name)"
            guard !fm.fileExists(atPath: destination) else { continue }
            let source = bundled.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.copyItem(at: source, to: URL(fileURLWithPath: destination))
        }
    }
}
