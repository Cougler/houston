import Foundation

/// A Claude Code skill: a `<name>/SKILL.md` directory under a skills root.
struct Skill: Identifiable, Equatable {
    let name: String
    let description: String
    var id: String { name }
}

/// Lists the skills available to a session — user-level `~/.claude/skills`
/// plus the project's `.claude/skills`, project winning on a name clash, the
/// same precedence Claude Code applies.
enum SkillsCatalog {

    static func load(projectPath: String?) -> [Skill] {
        var byName: [String: Skill] = [:]
        var roots = [NSHomeDirectory() + "/.claude/skills"]
        if let projectPath {
            roots.append(projectPath + "/.claude/skills")
        }
        let fm = FileManager.default
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let md = "\(root)/\(entry)/SKILL.md"
                guard fm.fileExists(atPath: md) else { continue }
                byName[entry] = parse(markdownAt: md, directoryName: entry)
            }
        }
        return byName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Reads `name:` and `description:` from the SKILL.md frontmatter. The
    /// directory name is the invocation name, so it's the fallback (and what
    /// `/name` must match); the frontmatter description is display-only.
    private static func parse(markdownAt path: String, directoryName: String) -> Skill {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Skill(name: directoryName, description: "")
        }
        var description = ""
        let lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                if let value = scalar("description", in: trimmed) { description = value }
            }
        }
        return Skill(name: directoryName, description: description)
    }

    /// `key: value` → value with surrounding quotes stripped; nil when the
    /// line is a different key or the value is a YAML block marker.
    private static func scalar(_ key: String, in line: String) -> String? {
        guard line.hasPrefix(key + ":") else { return nil }
        var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if value == ">" || value == "|" || value == ">-" || value == "|-" { return nil }
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) && value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
