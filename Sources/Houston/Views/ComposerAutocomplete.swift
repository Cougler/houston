import SwiftUI

/// Composer completions (2026-10-21): `/` at the start of the draft lists
/// the slash commands the harness runs (skills + custom commands for
/// Claude), `@` anywhere lists the project's files — both expanded by
/// the CLI itself (`@path` attaches the file's content in print mode,
/// verified live 2026-10-21; a `/name` runs the skill). The list is a
/// row above the input; ↑/↓ move, Tab or Return accept, Esc closes. The
/// item sources are per harness so another CLI's command surface plugs
/// in beside Claude's.
struct ComposerCompletion: Identifiable, Equatable {
    enum Kind { case command, file }
    let kind: Kind
    /// What accepting inserts, without the trigger character.
    let insert: String
    let title: String
    let detail: String
    var id: String { (kind == .command ? "/" : "@") + insert }
}

/// The token under completion: its trigger, the query typed so far, and
/// the range of the draft to replace on accept.
struct CompletionContext: Equatable {
    let kind: ComposerCompletion.Kind
    let query: String
    let range: Range<String.Index>

    /// The trailing token of the draft, when it's a completion trigger.
    /// Slash only as the FIRST token (a path mid-sentence isn't a
    /// command); `@` anywhere, as long as it starts a token.
    static func detect(in draft: String) -> CompletionContext? {
        guard !draft.isEmpty, !draft.hasSuffix(" "), !draft.hasSuffix("\n") else { return nil }
        let tokenStart = draft.lastIndex(where: { $0 == " " || $0 == "\n" })
            .map { draft.index(after: $0) } ?? draft.startIndex
        let token = draft[tokenStart...]
        guard let trigger = token.first else { return nil }
        let query = String(token.dropFirst())
        if trigger == "/", tokenStart == draft.startIndex {
            return CompletionContext(kind: .command, query: query, range: tokenStart..<draft.endIndex)
        }
        if trigger == "@" {
            return CompletionContext(kind: .file, query: query, range: tokenStart..<draft.endIndex)
        }
        return nil
    }
}

enum ComposerCompletions {
    /// Items for a context, ranked. Files come from the project index
    /// (async-refreshed; an empty index yields nothing until it loads).
    @MainActor
    static func items(
        for context: CompletionContext, harness: ChatHarness, project: String?
    ) -> [ComposerCompletion] {
        switch context.kind {
        case .command:
            let commands = CommandCatalog.commands(for: harness, project: project)
            return rank(commands, query: context.query) { $0.insert }
        case .file:
            guard let project else { return [] }
            let files = ProjectFileIndex.shared.files(for: project)
            let scored = files.compactMap { path -> (ComposerCompletion, Int)? in
                guard let score = fuzzyScore(path, query: context.query) else { return nil }
                let item = ComposerCompletion(
                    kind: .file, insert: path,
                    title: (path as NSString).lastPathComponent,
                    detail: (path as NSString).deletingLastPathComponent
                )
                return (item, score)
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
        }
    }

    private static func rank(
        _ items: [ComposerCompletion], query: String, key: (ComposerCompletion) -> String
    ) -> [ComposerCompletion] {
        guard !query.isEmpty else { return Array(items.prefix(8)) }
        return items.compactMap { item -> (ComposerCompletion, Int)? in
            fuzzyScore(key(item), query: query).map { (item, $0) }
        }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
    }

    /// Subsequence match with a bias toward the basename and toward
    /// contiguous runs; nil when the query's letters don't all appear
    /// in order.
    static func fuzzyScore(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let lower = candidate.lowercased()
        let q = query.lowercased()
        let base = (lower as NSString).lastPathComponent
        if base.hasPrefix(q) { return 1000 - candidate.count }
        if base.contains(q) { return 800 - candidate.count }
        if lower.contains(q) { return 600 - candidate.count }
        var score = 0
        var last: String.Index? = nil
        var cursor = lower.startIndex
        for ch in q {
            guard let hit = lower[cursor...].firstIndex(of: ch) else { return nil }
            if let last, lower.index(after: last) == hit { score += 15 } else { score += 1 }
            last = hit
            cursor = lower.index(after: hit)
        }
        return score - candidate.count / 4
    }
}

/// Slash commands per harness. Claude: skills (`SkillsCatalog`) plus the
/// `.claude/commands/*.md` custom commands, user then project. Other
/// harnesses: none yet — add a case when its command surface is wired.
enum CommandCatalog {
    @MainActor private static var cache: [String: (at: Date, items: [ComposerCompletion])] = [:]

    @MainActor
    static func commands(for harness: ChatHarness, project: String?) -> [ComposerCompletion] {
        guard harness == .claude else { return [] }
        let key = project ?? ""
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 20 { return hit.items }
        var byName: [String: ComposerCompletion] = [:]
        for skill in SkillsCatalog.load(projectPath: project) {
            byName[skill.name] = ComposerCompletion(
                kind: .command, insert: skill.name, title: "/" + skill.name,
                detail: skill.description
            )
        }
        var roots = [NSHomeDirectory() + "/.claude/commands"]
        if let project { roots.append(project + "/.claude/commands") }
        let fm = FileManager.default
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".md") {
                let command = String(name.dropLast(3))
                let description = (try? String(contentsOfFile: root + "/" + name, encoding: .utf8))
                    .map(firstDescription) ?? ""
                byName[command] = ComposerCompletion(
                    kind: .command, insert: command, title: "/" + command, detail: description
                )
            }
        }
        let items = byName.values.sorted {
            $0.insert.localizedCaseInsensitiveCompare($1.insert) == .orderedAscending
        }
        cache[key] = (Date(), items)
        return items
    }

    /// A command file's `description:` frontmatter, else its first prose
    /// line, clipped.
    private static func firstDescription(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "---" { break }
                if t.hasPrefix("description:") {
                    return ChatArchive.condense(String(t.dropFirst("description:".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                }
            }
        }
        let body = lines.drop { $0.trimmingCharacters(in: .whitespaces) == "---" }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        return body.map(ChatArchive.condense) ?? ""
    }
}

/// The project's file list for `@` completion: `git ls-files` (tracked +
/// untracked, gitignore respected) off the main thread, refreshed every
/// 30s while asked for; a non-git folder falls back to a bounded walk
/// that skips the usual build and dependency dirs.
@MainActor
final class ProjectFileIndex: ObservableObject {
    static let shared = ProjectFileIndex()

    @Published private var lists: [String: [String]] = [:]
    private var refreshedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func files(for project: String) -> [String] {
        let stale = refreshedAt[project].map { Date().timeIntervalSince($0) > 30 } ?? true
        if stale, !inFlight.contains(project) {
            inFlight.insert(project)
            Task.detached(priority: .utility) {
                let files = Self.list(project)
                await MainActor.run { Self.shared.store(files, for: project) }
            }
        }
        return lists[project] ?? []
    }

    private func store(_ files: [String], for project: String) {
        lists[project] = files
        refreshedAt[project] = Date()
        inFlight.remove(project)
    }

    nonisolated private static func list(_ project: String) -> [String] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", project, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let pipe = Pipe()
        git.standardOutput = pipe
        git.standardError = FileHandle.nullDevice
        if (try? git.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            git.waitUntilExit()
            if git.terminationStatus == 0 {
                let paths = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
                if !paths.isEmpty { return Array(paths.prefix(20_000)) }
            }
        }
        // Not a repo: a shallow walk.
        let skip: Set<String> = ["node_modules", ".build", ".git", "dist", "build", "DerivedData", ".next", "target", "Pods"]
        var out: [String] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: project) else { return [] }
        while let entry = walker.nextObject() as? String {
            let components = entry.split(separator: "/")
            if components.contains(where: { skip.contains(String($0)) }) || entry.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: project + "/" + entry, isDirectory: &isDir), !isDir.boolValue {
                out.append(entry)
            }
            if out.count >= 5000 { break }
        }
        return out
    }
}

/// The completion list rendered above the composer's input.
struct CompletionListView: View {
    let items: [ComposerCompletion]
    let selected: Int
    let onPick: (ComposerCompletion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onPick(item) } label: {
                    HStack(spacing: 8) {
                        LucideIcon(item.kind == .command ? "zap" : "file", size: 12)
                            .foregroundStyle(Theme.textSecondary)
                        Text(item.title)
                            .font(item.kind == .command ? Theme.Fonts.mono : Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        if index == selected {
                            LucideIcon("corner-down-left", size: 11)
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusControl)
                            .fill(index == selected ? Theme.rowHovered : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ChromeGlass(shape: RoundedRectangle(cornerRadius: Theme.radiusSurface)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .frame(maxWidth: 520, alignment: .leading)
    }
}
