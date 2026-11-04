import Foundation

/// One tool invocation by the agent, in a shape every harness fills the
/// same way (2026-10-21). The chat renders THIS, never a harness's raw
/// event: a Claude `tool_use` + `tool_result`, a codex `item/completed`,
/// an ACP `tool_call` all become a `ToolCall`, so the diff card, the
/// shell-output block and the task list work for any model that
/// provides the fields — and a harness that only knows a name and a
/// line still gets a chip (`simple`).
///
/// Claude's fields are VERIFIED against the live CLI and its transcript
/// (probe 2026-10-21): the stream delivers results as `user` events with
/// `tool_use_result` (structured: Edit's `structuredPatch`, Bash's
/// `stdout`/`stderr`, Read's `file.content`), the transcript line keeps
/// the same object under `toolUseResult`.
struct ToolCall: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case read, edit, write, shell, search, fetch, agent, todo, question, plan, skill, think, other
    }
    enum Status: Equatable { case running, done, failed }

    let id: String
    /// The harness's own tool name ("Edit", "mcp__github__create_issue").
    let name: String
    var kind: Kind
    /// One line, in words: "Edit ChatView.swift", "Run npm test".
    var title: String
    /// A second line when the title isn't the whole story: the command,
    /// the pattern, the URL.
    var detail: String = ""
    var filePath: String?
    var command: String?
    /// An edit's change, or a written file as all-added lines.
    var diff: FileDiff?
    /// Prose the call carries: a thinking summary, an agent's prompt, a
    /// plan's markdown.
    var content: String?
    /// What came back, capped (`outputTruncated`): stdout, search hits,
    /// a read excerpt, an agent's report.
    var output: String?
    var outputTruncated = false
    var isError = false
    var todos: [TodoItem] = []
    var questions: [Question] = []
    var status: Status = .running
    /// The raw input, for the card's "raw" view and for approval
    /// echoes.
    var inputJSON: String?

    struct TodoItem: Equatable, Identifiable {
        enum State: String { case pending, inProgress = "in_progress", completed }
        let content: String
        let state: State
        var id: String { content }
    }

    /// An AskUserQuestion question: the prompt, its chip header, the
    /// options offered, whether several may be picked.
    struct Question: Equatable, Identifiable {
        struct Option: Equatable, Identifiable {
            let label: String
            let description: String
            var id: String { label }
        }
        let text: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
        var id: String { text }
    }

    /// A chip-only call for harnesses that give a name and a line.
    static func simple(id: String = UUID().uuidString, name: String, detail: String, kind: Kind = .other) -> ToolCall {
        ToolCall(id: id, name: name, kind: kind, title: detail.isEmpty ? name : name + " · " + detail, status: .done)
    }

    /// A finished thinking block as a step.
    static func thinking(id: String = UUID().uuidString, text: String) -> ToolCall {
        ToolCall(
            id: id, name: "Thinking", kind: .think,
            title: ChatArchive.thinkingBrief(text), content: text, status: .done
        )
    }

    /// The chip line the old `.tool(name:detail:)` block drew, kept for
    /// transplants and markdown export.
    var chipText: String {
        switch kind {
        case .think: "Thinking · " + title
        default: detail.isEmpty ? title : title + " · " + detail
        }
    }

    /// "+12 −3" for an edit; nil otherwise.
    var changeCounts: (added: Int, removed: Int)? {
        guard let diff else { return nil }
        return (diff.added, diff.removed)
    }
}

/// A unified diff for one file, in hunks of typed lines.
struct FileDiff: Equatable {
    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        let text: String
        let id: Int
    }
    struct Hunk: Equatable, Identifiable {
        let oldStart: Int
        let newStart: Int
        var lines: [Line]
        var id: Int { oldStart * 100_000 + newStart }
    }
    var hunks: [Hunk]

    var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    /// A whole file as one added hunk (a created file).
    static func created(_ content: String) -> FileDiff {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body = lines
        if body.last == "" { body.removeLast() }
        return FileDiff(hunks: [Hunk(
            oldStart: 0, newStart: 1,
            lines: body.enumerated().map { Line(kind: .added, text: $1, id: $0) }
        )])
    }

    /// Claude's `structuredPatch` (jsdiff hunks: `lines` prefixed with
    /// ' ', '+' or '-').
    static func fromStructuredPatch(_ raw: Any?) -> FileDiff? {
        guard let hunks = raw as? [[String: Any]], !hunks.isEmpty else { return nil }
        var out: [Hunk] = []
        var counter = 0
        for hunk in hunks {
            guard let lines = hunk["lines"] as? [String] else { continue }
            let typed = lines.map { line -> Line in
                counter += 1
                let text = String(line.dropFirst())
                switch line.first {
                case "+": return Line(kind: .added, text: text, id: counter)
                case "-": return Line(kind: .removed, text: text, id: counter)
                default: return Line(kind: .context, text: text, id: counter)
                }
            }
            out.append(Hunk(
                oldStart: hunk["oldStart"] as? Int ?? 1,
                newStart: hunk["newStart"] as? Int ?? 1,
                lines: typed
            ))
        }
        return out.isEmpty ? nil : FileDiff(hunks: out)
    }

    /// A line diff of two strings (an Edit's old/new text before its
    /// result lands, or any harness that gives before/after). LCS over
    /// lines; past `maxLines` on either side it degrades to "all removed,
    /// all added" rather than an O(n·m) table.
    static func between(_ old: String, _ new: String, maxLines: Int = 600) -> FileDiff {
        func split(_ s: String) -> [String] {
            var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let a = split(old), b = split(new)
        var lines: [Line] = []
        var counter = 0
        func add(_ kind: Line.Kind, _ text: String) {
            counter += 1
            lines.append(Line(kind: kind, text: text, id: counter))
        }
        if a.count > maxLines || b.count > maxLines {
            a.forEach { add(.removed, $0) }
            b.forEach { add(.added, $0) }
            return FileDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)])
        }
        // LCS table.
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                add(.context, a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                add(.removed, a[i]); i += 1
            } else {
                add(.added, b[j]); j += 1
            }
        }
        while i < n { add(.removed, a[i]); i += 1 }
        while j < m { add(.added, b[j]); j += 1 }
        return FileDiff(hunks: [Hunk(oldStart: 1, newStart: 1, lines: lines)])
    }
}

// MARK: - Claude adapter

extension ToolCall {
    /// Output kept per call: enough to read, never a 2MB build log in a
    /// SwiftUI Text.
    static let outputCap = 12_000

    static func capped(_ text: String) -> (String, Bool) {
        guard text.count > outputCap else { return (text, false) }
        return (String(text.prefix(outputCap)), true)
    }

    private static func base(_ path: String?) -> String {
        (path.map { ($0 as NSString).lastPathComponent } ?? "")
    }

    private static func firstLine(_ s: String, max: Int = 80) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        let flat = line.trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// A Claude `tool_use` block → the call, result still pending. The
    /// Edit/Write diff is computed from the INPUT right away so the card
    /// (and the approval prompt) shows the change before the tool runs;
    /// the result's `structuredPatch` replaces it with exact line numbers
    /// and context when it lands.
    static func fromClaude(id: String, name: String, input: [String: Any]) -> ToolCall {
        func str(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let file = str("file_path") ?? str("notebook_path")
        var call = ToolCall(id: id, name: name, kind: .other, title: name, inputJSON: json)
        call.filePath = file
        switch name {
        case "Read":
            call.kind = .read
            call.title = "Read " + base(file)
        case "Edit", "MultiEdit":
            call.kind = .edit
            call.title = "Edit " + base(file)
            if let edits = input["edits"] as? [[String: Any]] {
                // MultiEdit: one hunk per edit.
                var hunks: [FileDiff.Hunk] = []
                for edit in edits {
                    let d = FileDiff.between(
                        edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? ""
                    )
                    hunks += d.hunks
                }
                call.diff = FileDiff(hunks: hunks)
            } else {
                call.diff = FileDiff.between(str("old_string") ?? "", str("new_string") ?? "")
            }
        case "Write":
            call.kind = .write
            call.title = "Write " + base(file)
            call.content = str("content")
            call.diff = FileDiff.created(str("content") ?? "")
        case "NotebookEdit":
            call.kind = .edit
            call.title = "Edit " + base(file)
            call.diff = FileDiff.created(str("new_source") ?? "")
        case "Bash", "PowerShell":
            call.kind = .shell
            call.command = str("command")
            call.title = str("description").map { firstLine($0) } ?? "Run " + firstLine(str("command") ?? "command")
            call.detail = str("command") ?? ""
        case "Grep":
            call.kind = .search
            call.title = "Search for \u{201C}\(firstLine(str("pattern") ?? "", max: 50))\u{201D}"
            call.detail = str("path").map { "in " + $0 } ?? ""
        case "Glob":
            call.kind = .search
            call.title = "Find " + firstLine(str("pattern") ?? "files", max: 60)
            call.detail = str("path").map { "in " + $0 } ?? ""
        case "WebFetch":
            call.kind = .fetch
            call.title = "Fetch " + (str("url").flatMap { URL(string: $0)?.host } ?? "a page")
            call.detail = str("url") ?? ""
        case "WebSearch":
            call.kind = .search
            call.title = "Search the web for \u{201C}\(firstLine(str("query") ?? "", max: 50))\u{201D}"
        case "Task", "Agent":
            call.kind = .agent
            call.title = "Agent: " + firstLine(str("description") ?? "subtask", max: 60)
            call.content = str("prompt")
        case "TodoWrite":
            call.kind = .todo
            call.todos = (input["todos"] as? [[String: Any]] ?? []).compactMap { todo in
                guard let content = todo["content"] as? String else { return nil }
                return TodoItem(
                    content: content,
                    state: TodoItem.State(rawValue: todo["status"] as? String ?? "pending") ?? .pending
                )
            }
            let done = call.todos.filter { $0.state == .completed }.count
            call.title = call.todos.isEmpty ? "Updated the plan"
                : "Plan · \(done) of \(call.todos.count) done"
        case "TaskCreate":
            call.kind = .todo
            call.title = "Task: " + firstLine(str("subject") ?? "", max: 60)
        case "TaskUpdate":
            call.kind = .todo
            call.title = "Task " + (str("status") ?? "updated")
        case "AskUserQuestion":
            call.kind = .question
            call.questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                return Question(
                    text: text,
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).compactMap { o in
                        (o["label"] as? String).map {
                            Question.Option(label: $0, description: o["description"] as? String ?? "")
                        }
                    },
                    multiSelect: q["multiSelect"] as? Bool ?? false
                )
            }
            call.title = call.questions.count == 1 ? "Asked a question" : "Asked \(call.questions.count) questions"
        case "ExitPlanMode":
            call.kind = .plan
            call.title = "Proposed a plan"
            call.content = str("plan")
        case "EnterPlanMode":
            call.kind = .plan
            call.title = "Entered plan mode"
        case "Skill":
            call.kind = .skill
            call.title = "Skill /" + (str("skill") ?? "")
            call.detail = str("args") ?? ""
        default:
            if name.hasPrefix("mcp__") {
                // mcp__<server>__<tool> → "server: tool"
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    call.title = parts[1] + ": " + parts[2...].joined(separator: "_")
                }
            }
            call.detail = ChatArchive.condense(
                ["description", "file_path", "command", "pattern", "query", "prompt", "url", "path"]
                    .compactMap(str).first ?? ""
            )
        }
        return call
    }

    /// A Claude `tool_result` block (+ the structured `toolUseResult`
    /// riding the line) applied to its call.
    mutating func applyClaudeResult(block: [String: Any], structured: Any?) {
        isError = block["is_error"] as? Bool ?? false
        status = isError ? .failed : .done
        var text = ""
        if let s = block["content"] as? String {
            text = s
        } else if let parts = block["content"] as? [[String: Any]] {
            text = parts.compactMap { part -> String? in
                switch part["type"] as? String {
                case "text": return part["text"] as? String
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        }
        let result = structured as? [String: Any]
        switch kind {
        case .edit, .write:
            if let patch = FileDiff.fromStructuredPatch(result?["structuredPatch"]) {
                diff = patch
            }
            // The success line is noise next to the diff; keep errors.
            if !isError { text = "" }
        case .read:
            if let file = result?["file"] as? [String: Any],
               let content = file["content"] as? String {
                text = content
            } else {
                // The raw result has "N\tline" prefixes; strip them.
                text = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line -> String in
                        if let tab = line.firstIndex(of: "\t"),
                           line[..<tab].allSatisfy(\.isNumber) {
                            return String(line[line.index(after: tab)...])
                        }
                        return String(line)
                    }.joined(separator: "\n")
            }
        case .shell:
            if let stdout = result?["stdout"] as? String {
                let stderr = result?["stderr"] as? String ?? ""
                text = stdout + (stderr.isEmpty ? "" : (stdout.isEmpty ? "" : "\n") + stderr)
            }
        default:
            break
        }
        let (kept, cut) = Self.capped(text.trimmingCharacters(in: .whitespacesAndNewlines))
        output = kept.isEmpty ? nil : kept
        outputTruncated = cut
    }
}
